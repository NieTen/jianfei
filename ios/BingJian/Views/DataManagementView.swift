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

    var body: some View {
        Form {
            Section("加密导出与恢复") {
                SecureField("导出 / 导入密码，至少 10 位", text: $password)
                Toggle("包含食物照片", isOn: $includePhotos)
                Button("导出本机完整记录") { Task { await exportLocal() } }.disabled(busy || password.count < 10)
                Button("选择加密恢复包") { filePicker = true }.disabled(busy || password.isEmpty)
                if let archive {
                    Text("已校验 \(archive.records.count) 条记录和 \(archive.photos.count) 张照片")
                    Toggle("冲突时采用恢复包内容", isOn: $preferIncoming)
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
                SecureField("删除服务器数据时填写账号密码", text: $accountPassword)
                Button("清除本机副本", role: .destructive) { deleteAction = "local"; confirmDelete = true }
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
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    busy = true
                    defer { busy = false }
                    archive = try await LocalArchive.open(url, password: password)
                    message = "文件校验通过，请确认冲突处理方式后导入"
                } catch { message = error.localizedDescription }
            }
        }
        .sheet(item: $shared) { value in ShareSheet(items: [value.url]) }
        .confirmationDialog("请先确认导出与待同步数据。此操作会清理所选范围的数据。", isPresented: $confirmDelete) {
            Button("确认执行删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        }
        .task {
            loadReceipt()
        }
    }

    private func exportLocal() async {
        busy = true
        defer { busy = false }
        do {
            let url = try await LocalArchive.export(store: model.requireStore(), password: password,
                                                   includePhotos: includePhotos, userId: model.session?.userId ?? "local")
            shared = ShareFile(url: url)
            message = "已生成加密恢复包"
        } catch { message = error.localizedDescription }
    }

    private func importLocal(_ value: ArchiveContents) async {
        busy = true
        defer { busy = false }
        do {
            let count = try await model.requireStore().importArchive(value, preferIncoming: preferIncoming,
                                                                    restoreDeleted: restoreDeleted, deviceId: model.deviceId)
            await model.reload()
            try? FileManager.default.removeItem(at: value.temporaryDirectory)
            archive = nil
            message = "已导入 \(count) 条记录，登录后可同步"
        } catch { message = error.localizedDescription }
    }

    private func exportServer(format: String) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.api.send("data/export", method: "POST", body: [
                "request_key": .string(UUID().uuidString.lowercased()), "password": .string(password),
                "include_photos": .bool(includePhotos), "format": .string(format)
            ])
            serverTaskId = result.object?.text("id") ?? ""
            message = "导出任务已创建，可稍后查询进度"
        } catch { message = error.localizedDescription }
    }

    private func checkExport() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.api.send("data/tasks/\(serverTaskId)").object ?? [:]
            guard result.text("status") == "completed" else {
                message = result.text("error", fallback: "当前状态 \(result.text("status"))")
                return
            }
            let data = try await model.api.request("data/exports/\(serverTaskId)/download")
            let name = result["result"]?.object?.text("filename") ?? "记录.bjar"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            shared = ShareFile(url: url)
            message = "下载完成，服务器文件将在 24 小时后过期"
        } catch { message = error.localizedDescription }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            if deleteAction == "local" {
                let store = try model.requireStore()
                try await store.clearLocalData()
                try await store.setMetadata("generation", value: nil)
                try await store.setMetadata("epoch", value: nil)
                model.healthEnabled = false
                model.syncEnabled = false
                await model.reload()
                message = "本机副本已清理，健康历史自动回填已暂停"
                return
            }
            guard !accountPassword.isEmpty else { message = "请填写账号密码"; return }
            try await model.requestDeletion(account: deleteAction == "account", password: accountPassword)
            loadReceipt()
            accountPassword = ""
            message = model.deletionPending ? "删除请求等待连接，服务器尚未确认" : "服务器已接受删除，使用回执可继续查询结果"
        } catch { message = error.localizedDescription }
    }

    private func checkDeletion() async {
        do {
            guard deletionServer == model.serverURL else {
                message = "请先连接提交删除请求时的服务器 \(deletionServer)"
                return
            }
            let data = try await model.api.request("data/deletions/\(deletionTaskId)", authenticated: false,
                                                   extraHeaders: ["X-Deletion-Receipt": deletionReceipt])
            let result = try JSONDecoder().decode(JSONObject.self, from: data)
            message = result.text("status") == "completed" ? "服务器在线数据已清理，备份按保留期过期" : "删除状态 \(result.text("status"))。\(result.text("error"))"
        } catch { message = error.localizedDescription }
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
