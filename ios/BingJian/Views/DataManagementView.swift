import SwiftUI
import UniformTypeIdentifiers

struct ShareFile: Identifiable {
    var id: String { url.path }
    var url: URL
}

struct DataManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var accountPassword = ""
    @State private var includePhotos = true
    @State private var preferIncoming = false
    @State private var restoreDeleted = false
    @State private var filePicker = false
    @State private var archive: ArchiveContents?
    @State private var shared: ShareFile?
    @State private var busy = false
    @State private var message = ""
    @State private var deleteAction = ""
    @State private var confirmDelete = false
    @State private var serverTaskId = ""
    @State private var deletionTaskId = ""
    @State private var deletionReceipt = ""
    @State private var deletionServer = ""
    @State private var editingContext: UUID?
    @State private var backupEntries: [LocalBackupEntry] = []
    @State private var backupError: String?
    @State private var automaticBackup = true
    @State private var previewTarget: [AppRecord] = []
    @State private var previewRecordCount = 0
    @State private var previewDeletedCount = 0
    @State private var confirmRemoveBackups = false

    var body: some View {
        AppForm {
            FormIntro(title: "记录由你保管", subtitle: "导出备份、恢复记录，或管理不再需要的数据。", symbol: "tray.and.arrow.down", color: Palette.teal)
            Section("本机独立版本备份") {
                Toggle("自动保留本机版本", isOn: Binding(get: { automaticBackup }, set: { value in
                    automaticBackup = value
                    guard let captured = editingContext, captured == model.localDataContext else { return }
                    Task {
                        do {
                            try await model.requireStore().setMetadata("automatic_backup", value: value ? "on" : "off")
                            try model.checkLocalContext(captured)
                            if value { model.scheduleLocalBackup() }
                        } catch { if captured == model.localDataContext { message = error.localizedDescription } }
                    }
                })).disabled(busy)
                Text("保存或启动后自动检查，每 6 小时最多生成一版，保留最近 7 版。独立目录中的包已加密并经过解密校验。手机丢失或密钥不可读时，需另行保管的密码导出包或云端副本。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("立即创建本机版本") { Task { await createBackup() } }.disabled(busy)
                if let backupError, !backupError.isEmpty { Text("最近备份未完成：" + backupError).foregroundStyle(.red) }
                ForEach(backupEntries) { entry in
                    Button { Task { await prepareBackup(entry) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(TimeFormat.parse(entry.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? entry.createdAt)
                            Text("\(entry.reason) · \(entry.recordCount) 条记录 · \(entry.photoCount) 张照片").font(.caption)
                            if (entry.missingPhotoCount ?? 0) > 0 {
                                Text("另有 \(entry.missingPhotoCount ?? 0) 张照片尚未下载，包保留记录和照片引用，不能独立恢复这些照片。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(busy)
                }
                Button("删除当前空间的版本与迁移备份", role: .destructive) { confirmRemoveBackups = true }.disabled(busy)
            }
            Section("旧记录迁移") {
                NavigationLink("从旧 NAS 或未绑定离线空间迁入") { DataMigrationView() }
                Text("向导会保留加密来源包、核对来源与目标、处理稳定标识和冲突；其他账号的本机空间不会自动合并。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("加密导出与恢复") {
                FormField(title: "备份密码") { SecureField("导出 / 导入密码，至少 10 位", text: $password) }
                Toggle("包含食物照片", isOn: $includePhotos)
                Button("导出本机完整记录") { Task { await exportLocal() } }.disabled(busy || password.count < 10)
                Button("选择加密恢复包") { filePicker = true }.disabled(busy || password.isEmpty)
                if let archive {
                    Text("已校验 \(previewRecordCount) 条有效记录、\(previewDeletedCount) 个删除标记和 \(archive.photos.count) 张照片")
                    Toggle("冲突时采用恢复包内容", isOn: $preferIncoming)
                    Text("采用恢复包时，也会应用其中的删除标记；默认保留当前内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("将已删除记录显式另存为新记录", isOn: $restoreDeleted)
                    Button("确认导入已校验内容") { Task { await importLocal(archive) } }.disabled(busy)
                }
                Text("恢复包使用分片认证加密。请单独保管密码，丢失密码无法解密。").font(.caption).foregroundStyle(.secondary)
            }
            Section("服务器导出") {
                Button("创建服务器完整导出任务") { Task { await exportServer(format: "archive") } }.disabled(model.session == nil || password.count < 10 || busy)
                Button("创建 CSV 查看文件") { Task { await exportServer(format: "csv") } }.disabled(model.session == nil || password.count < 10 || busy)
                if !serverTaskId.isEmpty { Button("查看导出进度并下载") { Task { await checkExport() } } }
                Text("服务器导出仅包含已同步数据。CSV 为明文，仅导出自己的记录。").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("正在处理数据") }
            if !message.isEmpty { Section { Text(message).font(.subheadline) } }
            Section("清理与删除") {
                LabeledContent("待同步记录", value: String(model.pendingCount))
                FormField(title: "账号密码") { SecureField("删除服务器数据时填写", text: $accountPassword) }
                Button("清除本机副本（保留版本备份）", role: .destructive) { deleteAction = "local"; confirmDelete = true }
                Button("删除服务器全部个人数据", role: .destructive) { deleteAction = "data"; confirmDelete = true }.disabled(model.session == nil)
                Button("注销服务器账号", role: .destructive) { deleteAction = "account"; confirmDelete = true }.disabled(model.session == nil)
                if !deletionTaskId.isEmpty { Button("查询删除结果") { Task { await checkDeletion() } } }
                if model.deletionPending {
                    Text("删除请求等待连接，服务器尚未确认")
                    Button("重试提交删除请求") {
                        model.perform { try await model.processPendingDeletion(); loadReceipt() }
                    }
                    Button("放弃尚未提交的删除请求", role: .destructive) { model.cancelPendingDeletion() }
                }
                Text("服务器接受删除后立即停止共享，在线数据默认 24 小时内清理，备份按 30 天保留期过期。健康 App 的源数据由你在健康 App 管理。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("清除本机副本或注销服务器账号不会代你销毁已导出到文件或保存的本机版本。若不再保留，请先删除当前空间的版本与迁移备份，并在文件 App 中删除另存的个人包。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("恢复同步基线") {
                Button("确认保留当前服务器，重建同步") {
                    model.perform {
                        let store = try model.requireStore()
                        try await store.setMetadata("sync_cursor", value: nil)
                        try await store.setMetadata("epoch", value: nil)
                        try await store.setMetadata("instance_id", value: nil)
                        await model.sync()
                    }
                }
                Text("服务器恢复备份或迁移后可重建。数据代际变化时先导出需要保留的本机记录，再清除本机副本并重新登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("数据管理")
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [UTType(filenameExtension: "bjar") ?? .data]) { result in
            guard let captured = editingContext, captured == model.localDataContext else { return }
            let secret = password
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    busy = true
                    defer { if captured == model.localDataContext { busy = false } }
                    let contents = try await LocalArchive.open(url, password: secret)
                    guard captured == model.localDataContext else { try? FileManager.default.removeItem(at: contents.temporaryDirectory); return }
                    let target = try await model.requireStore().allRecords()
                    try await setPreview(contents, target: target, context: captured)
                    message = "文件校验通过，请确认冲突处理方式后导入"
                } catch { if captured == model.localDataContext { message = error.localizedDescription } }
            }
        }
        .sheet(item: $shared) { value in ShareSheet(items: [value.url]) }
        .confirmationDialog("请先确认导出与待同步数据。此操作会清理所选范围的数据。", isPresented: $confirmDelete) {
            Button("确认执行删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除当前空间的版本备份和迁移来源包后将无法从它们恢复，现有记录不变。", isPresented: $confirmRemoveBackups) {
            Button("删除版本与迁移备份", role: .destructive) { Task { await removeBackups() } }
            Button("取消", role: .cancel) {}
        }
        .task(id: model.localDataContext) {
            editingContext = model.localDataContext
            loadReceipt()
            await loadBackups()
        }
        .onChange(of: model.localDataContext) { _, _ in
            discardArchive(); previewTarget = []; shared = nil; filePicker = false; busy = false
            password = ""; accountPassword = ""; serverTaskId = ""; backupEntries = []; backupError = nil
            confirmDelete = false; confirmRemoveBackups = false; message = ""
        }
    }

    private func discardArchive() {
        if let archive { try? FileManager.default.removeItem(at: archive.temporaryDirectory) }
        archive = nil
        previewRecordCount = 0; previewDeletedCount = 0
    }

    private func setPreview(_ contents: ArchiveContents, target: [AppRecord], context: UUID) async throws {
        let active = await Task.detached(priority: .utility) { contents.records.reduce(0) { $0 + ($1.deletedAt == nil ? 1 : 0) } }.value
        do { try model.checkLocalContext(context) }
        catch { try? FileManager.default.removeItem(at: contents.temporaryDirectory); throw error }
        discardArchive()
        archive = contents; previewTarget = target
        previewRecordCount = active; previewDeletedCount = contents.records.count - active
    }

    private func loadBackups() async {
        let context = model.localDataContext
        do {
            let store = try model.requireStore(), namespace = await store.directory.lastPathComponent
            let entries = try await LocalBackupService.shared.entries(namespace: namespace)
            let failure = await LocalBackupService.shared.lastError(namespace: namespace)
            let enabled = try await store.metadata("automatic_backup") != "off"
            try model.checkLocalContext(context)
            backupEntries = entries; backupError = failure; automaticBackup = enabled
        } catch { if context == model.localDataContext { backupError = error.localizedDescription } }
    }

    private func createBackup() async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            _ = try await LocalBackupService.shared.create(store: model.requireStore())
            try model.checkLocalContext(context)
            await loadBackups()
            message = "本机版本已生成并校验。"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func prepareBackup(_ entry: LocalBackupEntry) async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            let store = try model.requireStore()
            let contents = try await LocalBackupService.shared.open(entry, store: store)
            guard context == model.localDataContext else { try? FileManager.default.removeItem(at: contents.temporaryDirectory); return }
            let records = try await store.allRecords()
            try await setPreview(contents, target: records, context: context)
            message = "备份校验通过。向下查看恢复预览，默认保留当前记录及删除标记。"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func removeBackups() async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        do {
            let store = try model.requireStore(), namespace = await store.directory.lastPathComponent
            try await store.setMetadata("automatic_backup", value: "off")
            try model.checkLocalContext(context)
            try await LocalBackupService.shared.removeAll(namespace: namespace)
            try model.checkLocalContext(context)
            await loadBackups()
            message = "当前空间的版本与迁移备份已删除，自动备份已关闭。"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func exportLocal() async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            let url = try await LocalArchive.export(store: model.requireStore(), password: password,
                                                   includePhotos: includePhotos, userId: model.session?.userId ?? "local")
            try model.checkLocalContext(context)
            shared = ShareFile(url: url)
            message = "已生成加密恢复包"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func importLocal(_ value: ArchiveContents) async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        let incoming = preferIncoming, restore = restoreDeleted, expected = previewTarget, device = model.deviceId
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            let store = try model.requireStore()
            _ = try await LocalBackupService.shared.create(store: store, reason: "恢复前自动保护")
            try model.checkLocalContext(context)
            let count = try await store.importArchive(value, preferIncoming: incoming, restoreDeleted: restore, deviceId: device,
                                                     preserveDeletionMarkers: true, expectedRecords: expected)
            try model.checkLocalContext(context)
            await model.reload()
            try model.checkLocalContext(context)
            try? FileManager.default.removeItem(at: value.temporaryDirectory)
            archive = nil
            message = "已导入 \(count) 条记录，登录后可同步"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func exportServer(format: String) async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            let result = try await model.api.send("data/export", method: "POST", body: [
                "request_key": .string(UUID().uuidString.lowercased()), "password": .string(password),
                "include_photos": .bool(includePhotos), "format": .string(format)
            ])
            try model.checkLocalContext(context)
            serverTaskId = result.object?.text("id") ?? ""
            message = "导出任务已创建，可稍后查询进度"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func checkExport() async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        let taskId = serverTaskId
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            let result = try await model.api.send("data/tasks/\(taskId)").object ?? [:]
            try model.checkLocalContext(context)
            guard result.text("status") == "completed" else {
                message = result.text("error", fallback: "当前状态 \(result.text("status"))")
                return
            }
            let data = try await model.api.request("data/exports/\(taskId)/download")
            try model.checkLocalContext(context)
            let name = result["result"]?.object?.text("filename") ?? "记录.bjar"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            shared = ShareFile(url: url)
            message = "下载完成，服务器文件将在 24 小时后过期"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func delete() async {
        let context = model.localDataContext
        guard editingContext == context, !busy else { return }
        busy = true
        defer { if context == model.localDataContext { busy = false } }
        do {
            if deleteAction == "local" {
                let store = try model.requireStore()
                try await store.clearLocalData()
                try model.checkLocalContext(context)
                try await store.setMetadata("generation", value: nil)
                try await store.setMetadata("epoch", value: nil)
                try model.checkLocalContext(context)
                model.healthEnabled = false
                model.syncEnabled = false
                await model.reload()
                try model.checkLocalContext(context)
                message = "本机副本已清理，健康历史自动回填已暂停"
                return
            }
            guard !accountPassword.isEmpty else { message = "请填写账号密码"; return }
            try await model.requestDeletion(account: deleteAction == "account", password: accountPassword)
            // 删除账号可能由模型主动切到新空间，旧页面不继续展示旧回执。
            try model.checkLocalContext(context)
            loadReceipt()
            accountPassword = ""
            message = model.deletionPending ? "删除请求等待连接，服务器尚未确认" : "服务器已接受删除，使用回执可继续查询结果"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func checkDeletion() async {
        let context = model.localDataContext
        guard editingContext == context else { return }
        do {
            guard deletionServer == model.serverURL else {
                message = "请先连接提交删除请求时的服务器 \(deletionServer)"
                return
            }
            let data = try await model.api.request("data/deletions/\(deletionTaskId)", authenticated: false,
                                                   extraHeaders: ["X-Deletion-Receipt": deletionReceipt])
            try model.checkLocalContext(context)
            let result = try JSONDecoder().decode(JSONObject.self, from: data)
            message = result.text("status") == "completed" ? "服务器在线数据已清理，备份按保留期过期" : "删除状态 \(result.text("status"))。\(result.text("error"))"
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func loadReceipt() {
        if let data = KeychainStore.read("deletion_receipt"),
           let saved = try? JSONDecoder().decode(JSONObject.self, from: data) {
            deletionTaskId = saved.text("id")
            deletionReceipt = saved.text("receipt")
            deletionServer = saved.text("server_url")
        }
    }
}
