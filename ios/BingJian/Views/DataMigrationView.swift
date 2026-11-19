import SwiftUI
import UniformTypeIdentifiers

struct DataMigrationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sources: [LocalMigrationSource] = []
    @State private var password = ""
    @State private var picker = false
    @State private var context: UUID?
    @State private var plan: LocalMigrationPlan?
    @State private var sourcePackage: URL?
    @State private var share: ShareFile?
    @State private var preferIncoming = false
    @State private var confirmedOwnership = false
    @State private var busy = false
    @State private var operationTask: Task<Void, Never>?
    @State private var message = ""

    var body: some View {
        AppForm {
            FormIntro(title: "把自己的旧记录迁入当前空间", subtitle: "先核对来源和目标，保留源副本，再确认导入。", symbol: "arrow.triangle.2.circlepath", color: Palette.teal)
            Section("1 · 确认目标") {
                LabeledContent("当前目标", value: model.cloudAccount.text("email", fallback: model.session?.displayName ?? "当前离线空间"))
                Text("需要迁入云账号时，请先返回账号页登录目标账号。迁移不自动开启同步，也不会转移旧账号权限、密钥或伙伴授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("2 · 选择来源并保留加密副本") {
                FormField(title: "个人包密码") { SecureField("导出或解密密码，至少 10 位", text: $password) }
                Button("选择旧 NAS 的个人加密导出包") { picker = true }.disabled(password.count < 10 || busy)
                Text("先在旧 NAS 登录原账号，导出包含照片的个人包，再在这里选择。整台服务器备份包不能作为个人包导入。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sources) { source in
                    Button {
                        prepare(source)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("本机未绑定的离线记录 · \(source.recordCount) 条")
                            Text("\(source.firstDay) 至 \(source.lastDay)").font(.caption)
                        }
                    }.disabled(password.count < 10 || busy)
                }
                Text("已绑定其他账号的本机空间不会直接列出；请使用该账号导出的密码归档。源空间保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                if let sourcePackage {
                    Button("保存或分享迁移源加密副本") { share = ShareFile(url: sourcePackage) }
                }
            }
            if let plan {
                Section("3 · 核对迁移预览") {
                    LabeledContent("新增记录", value: String(plan.newCount))
                    LabeledContent("内容相同", value: String(plan.identicalCount))
                    LabeledContent("需要选择的冲突", value: String(plan.conflictCount))
                    LabeledContent("来源或目标删除标记", value: String(plan.deletedCount))
                    LabeledContent("照片", value: String(plan.contents.photos.count))
                    Text("日期范围：\(plan.firstDay) 至 \(plan.lastDay)").font(.caption)
                    ForEach(plan.samples) { record in
                        Text("抽样：\(record.businessDate) · \(record.kind)").font(.caption)
                    }
                    Toggle("冲突时采用源包的业务内容", isOn: $preferIncoming)
                    Text("采用源包时，也会按源包的删除标记处理已迁移的同一记录；默认保留目标内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("确认来源属于我，目标账号正确，已保留源副本", isOn: $confirmedOwnership)
                    Text("目标已删除记录不会自动恢复。中断后可重新选择同一来源继续；稳定映射避免重复生成记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("确认迁入当前空间", action: migrate).buttonStyle(FilledActionStyle())
                        .disabled(!confirmedOwnership || busy)
                }
            }
            if busy { ProgressView("正在校验和迁移…") }
            if !message.isEmpty { Section { Text(message) } }
        }
        .navigationTitle("旧记录迁移")
        .disabled(busy)
        .task(id: model.localDataContext) {
            clearPreview()
            context = model.localDataContext
            password = ""
            do {
                let captured = model.localDataContext
                let namespace = try await model.requireStore().directory.lastPathComponent
                let values = try await LocalMigration.sources(excluding: namespace)
                try model.checkLocalContext(captured)
                sources = values
            } catch { message = error.localizedDescription }
        }
        .onChange(of: model.localDataContext) { _, _ in operationTask?.cancel(); clearPreview(); busy = false; picker = false; share = nil; sources = [] }
        .onDisappear { operationTask?.cancel(); if !busy { clearPreview() } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [UTType(filenameExtension: "bjar") ?? .data]) { result in
            guard let captured = context, captured == model.localDataContext else { return }
            let secret = password
            run { store in
                let source = try result.get()
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let contents = try await LocalArchive.open(source, password: secret)
                do {
                    try model.checkLocalContext(captured)
                    let namespace = await store.directory.lastPathComponent
                    let package = try await preservePackage(source, namespace: namespace)
                    try await prepare(contents, package: package, store: store, context: captured)
                } catch { try? FileManager.default.removeItem(at: contents.temporaryDirectory); throw error }
            }
        }
        .sheet(item: $share) { value in ShareSheet(items: [value.url]) }
    }

    private func clearPreview() {
        if let plan { try? FileManager.default.removeItem(at: plan.contents.temporaryDirectory) }
        plan = nil
        sourcePackage = nil
        confirmedOwnership = false
        message = ""
    }

    private func preservePackage(_ url: URL, namespace: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BingJianMigrationArchives").appendingPathComponent(namespace)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        let target = root.appendingPathComponent(try LocalArchive.digest(url) + ".bjar")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
        return target
        }.value
    }

    private func prepare(_ source: LocalMigrationSource) {
        guard let captured = context else { return }
        let secret = password
        run { store in
            let contents = try await LocalMigration.snapshot(source)
            defer { try? FileManager.default.removeItem(at: contents.temporaryDirectory) }
            let exported = try await LocalArchive.export(contents, password: secret, includePhotos: true, userId: source.id)
            defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
            let checked = try await LocalArchive.open(exported, password: secret)
            do {
                try model.checkLocalContext(captured)
                let namespace = await store.directory.lastPathComponent
                let package = try await preservePackage(exported, namespace: namespace)
                try await prepare(checked, package: package, store: store, context: captured)
            } catch { try? FileManager.default.removeItem(at: checked.temporaryDirectory); throw error }
        }
    }

    private func prepare(_ contents: ArchiveContents, package: URL, store: LocalDatabase, context: UUID) async throws {
        let namespace = await store.directory.lastPathComponent
        let binding = try await store.metadata("bound_user") ?? "local:" + namespace
        let target = try await store.allRecords()
        try model.checkLocalContext(context)
        let prepared = try await Task.detached(priority: .userInitiated) {
            let photoIds = Set(contents.photos.map(\.id))
            let referenced = Set(contents.records.filter { $0.deletedAt == nil && $0.kind == "meal" }.compactMap { $0.decode(MealEntry.self) }.flatMap(\.photoIds))
            guard referenced.isSubset(of: photoIds) else {
                throw APIError(code: "MIGRATION_PHOTO_MISSING", message: "此来源包缺少被餐次引用的照片，请从原服务重新导出完整个人包")
            }
            return try LocalMigration.plan(contents, target: target, targetBinding: binding)
        }.value
        try model.checkLocalContext(context)
        clearPreview()
        plan = prepared
        sourcePackage = package
        message = "源包已校验并独立留存。请检查抽样、冲突和目标账号。"
    }

    private func migrate() {
        guard let plan, confirmedOwnership, let captured = context else { return }
        let incoming = preferIncoming
        run { store in
            _ = try await LocalBackupService.shared.create(store: store, reason: "迁移前自动保护")
            try model.checkLocalContext(captured)
            let count = try await store.importArchive(plan.contents, preferIncoming: incoming, restoreDeleted: false,
                                                     deviceId: model.deviceId, preserveDeletionMarkers: true,
                                                     expectedRecords: plan.expectedTarget)
            try model.checkLocalContext(captured)
            let stored = try await store.allRecords()
            try model.checkLocalContext(captured)
            let verified = await Task.detached(priority: .utility) {
                let ids = Set(stored.map(\.id)), expected = Set(plan.contents.records.map(\.id))
                return (expected.isSubset(of: ids), expected.count)
            }.value
            try model.checkLocalContext(captured)
            guard verified.0 else { throw APIError(code: "MIGRATION_VERIFY", message: "迁移记录数核对未通过，请保留源包并重新检查") }
            try await store.setMetadata("last_migration", value: "\(TimeFormat.iso()) · \(count) 条 · \(plan.sourceBinding)")
            await model.reload()
            try model.checkLocalContext(captured)
            clearPreview()
            message = "迁移完成并核对 \(verified.1) 个记录标识，本次写入 \(count) 条。源副本保留；请抽查体重、餐次与照片后按个人同步开关同步。"
        }
    }

    private func run(_ action: @escaping @MainActor (LocalDatabase) async throws -> Void) {
        guard !busy, let captured = context, captured == model.localDataContext, let store = try? model.requireStore() else { return }
        busy = true
        operationTask = Task { @MainActor in
            defer {
                if captured == model.localDataContext {
                    busy = false
                    if Task.isCancelled { clearPreview() }
                }
            }
            do { try model.checkLocalContext(captured); try await action(store) }
            catch { if captured == model.localDataContext { message = error.localizedDescription } }
        }
    }
}
