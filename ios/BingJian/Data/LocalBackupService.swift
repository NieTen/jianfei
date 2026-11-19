import Foundation

struct LocalBackupEntry: Codable, Identifiable, Sendable {
    var id: String
    var namespace: String
    var createdAt: String
    var reason: String
    var recordCount: Int
    var photoCount: Int
    var sha256: String
    var missingPhotoCount: Int?
}

/// 加密版本保存在活动库之外；这里只恢复业务内容，不重放旧会话或共享命令。
actor LocalBackupService {
    static let shared = LocalBackupService()
    private let base: URL
    private let testPassword: String?
    private let writeManifest: @Sendable (Data, URL) throws -> Void
    private var scheduled: [String: Task<Void, Never>] = [:]
    private var running = Set<String>()

    init(directory: URL? = nil, password: String? = nil,
         writeManifest: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: [.atomic, .completeFileProtection])
         }) {
        base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BingJianBackups", isDirectory: true)
        testPassword = password
        self.writeManifest = writeManifest
    }

    func schedule(store: LocalDatabase) async {
        let namespace = await store.directory.lastPathComponent
        guard (try? await store.metadata("automatic_backup")) != "off" else { return }
        if (try? entries(namespace: namespace).isEmpty) == true,
           (try? await store.recoverySummary().number("record_count")) == 0 { return }
        scheduled[namespace]?.cancel()
        scheduled[namespace] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                guard try await store.metadata("automatic_backup") != "off" else { return }
                _ = try await self.create(store: store, reason: "自动备份", force: false)
            } catch is CancellationError { }
            catch { await self?.saveError(error.localizedDescription, namespace: namespace) }
        }
    }

    func entries(namespace: String) throws -> [LocalBackupEntry] {
        let root = base.appendingPathComponent(namespace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "status.json" }
            .compactMap { try? Codec.decoder().decode(LocalBackupEntry.self, from: Data(contentsOf: $0)) }
            .filter { $0.namespace == namespace && UUID(uuidString: $0.id) != nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func lastError(namespace: String) -> String? {
        let url = base.appendingPathComponent(namespace).appendingPathComponent("status.json")
        return (try? JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url)))?.text("error")
    }

    private func saveError(_ message: String, namespace: String) {
        let root = base.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? protect(root)
        let value: JSONObject = ["error": .string(message), "checked_at": .string(TimeFormat.iso())]
        try? JSONEncoder().encode(value).write(to: root.appendingPathComponent("status.json"), options: [.atomic, .completeFileProtection])
    }

    private func password(namespace: String, create: Bool) throws -> String {
        if let testPassword { return testPassword }
        let key = "local_backup_key:" + namespace
        if let data = KeychainStore.read(key), let value = String(data: data, encoding: .utf8) { return value }
        guard create else { throw APIError(code: "BACKUP_KEY_MISSING", message: "本机备份密钥不可用，请使用另行保管的密码导出包恢复") }
        let value = UUID().uuidString + UUID().uuidString
        try KeychainStore.save(Data(value.utf8), key: key)
        return value
    }

    func create(store: LocalDatabase, reason: String = "手动备份", force: Bool = true) async throws -> LocalBackupEntry {
        let namespace = await store.directory.lastPathComponent
        guard running.insert(namespace).inserted else { throw APIError(code: "BACKUP_RUNNING", message: "当前空间已有备份正在生成") }
        defer { running.remove(namespace) }
        let previous = try entries(namespace: namespace)
        if !force, let latest = previous.first, latest.recordCount > 0,
           let time = TimeFormat.parse(latest.createdAt), Date().timeIntervalSince(time) < 6 * 3600 {
            return latest
        }
        // 有历史包却无法读取钥匙串时不能生成新密钥，把已有包变成无法解密的孤本。
        let root = base.appendingPathComponent(namespace, isDirectory: true)
        let hasPackages = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "bjar" }
        let secret = try password(namespace: namespace, create: !hasPackages)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
        do {
            let archive = try await LocalArchive.export(store: store, password: secret, includePhotos: true,
                                                        userId: namespace, includeDeleted: true, allowMissingPhotos: true)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            let checked = try await LocalArchive.open(archive, password: secret)
            defer { try? FileManager.default.removeItem(at: checked.temporaryDirectory) }
            let entry = LocalBackupEntry(id: UUID().uuidString.lowercased(), namespace: namespace, createdAt: TimeFormat.iso(), reason: reason,
                                         recordCount: checked.records.filter { $0.deletedAt == nil }.count,
                                         photoCount: checked.photos.count, sha256: try LocalArchive.digest(archive),
                                         missingPhotoCount: checked.manifest.strings("missing_photo_ids").count)
            let target = root.appendingPathComponent(entry.id + ".bjar")
            let manifest = root.appendingPathComponent(entry.id + ".json")
            let preparedManifest = archive.deletingLastPathComponent().appendingPathComponent(entry.id + ".json")
            // 锁屏可能拒绝完整保护文件的创建；清单准备成功前不得发布归档，避免后台重试累积孤包。
            try writeManifest(Codec.encoder().encode(entry), preparedManifest)
            try FileManager.default.moveItem(at: archive, to: target)
            do {
                try FileManager.default.moveItem(at: preparedManifest, to: manifest)
            } catch {
                // 只回滚本次随机标识对应的归档，已有备份及其清单不受影响。
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            for old in try entries(namespace: namespace).dropFirst(7) {
                try FileManager.default.removeItem(at: root.appendingPathComponent(old.id + ".bjar"))
                try FileManager.default.removeItem(at: root.appendingPathComponent(old.id + ".json"))
            }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("status.json"))
            return entry
        } catch {
            saveError(error.localizedDescription, namespace: namespace)
            throw error
        }
    }

    func open(_ entry: LocalBackupEntry, store: LocalDatabase) async throws -> ArchiveContents {
        let namespace = await store.directory.lastPathComponent
        guard entry.namespace == namespace, UUID(uuidString: entry.id) != nil else {
            throw APIError(code: "BACKUP_IDENTITY", message: "备份不属于当前本地空间")
        }
        let archive = base.appendingPathComponent(namespace).appendingPathComponent(entry.id + ".bjar")
        guard try LocalArchive.digest(archive) == entry.sha256 else { throw APIError(code: "BACKUP_CORRUPT", message: "备份文件校验失败") }
        return try await LocalArchive.open(archive, password: password(namespace: namespace, create: false))
    }

    func removeAll(namespace: String) throws {
        guard !running.contains(namespace) else { throw APIError(code: "BACKUP_RUNNING", message: "请等待当前备份完成") }
        scheduled[namespace]?.cancel()
        scheduled[namespace] = nil
        let root = base.appendingPathComponent(namespace)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        if testPassword == nil {
            KeychainStore.delete("local_backup_key:" + namespace)
            let migrations = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BingJianMigrationArchives").appendingPathComponent(namespace)
            if FileManager.default.fileExists(atPath: migrations.path) { try FileManager.default.removeItem(at: migrations) }
        }
    }

    private func protect(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
    }
}
