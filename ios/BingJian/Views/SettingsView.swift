import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section {
                HStack(spacing: 15) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 42)).foregroundStyle(Palette.sage)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.profile.displayName.isEmpty ? "我的记录" : model.profile.displayName).font(.headline)
                        Text(model.session?.displayName ?? "本机离线身份").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                NavigationLink("身体档案与目标") { ProfileEditorView() }
                NavigationLink("身体组成与围度") { MeasurementEditorView() }
            }
            Section("数据与服务") {
                NavigationLink("健康权限与历史回填") { HealthSettingsView() }
                NavigationLink("私有服务器与账号") { ConnectionSettingsView() }
                NavigationLink("设备与登录管理") { DeviceManagementView() }
                NavigationLink("同步状态与冲突") { SyncStatusView() }
                NavigationLink("导出、恢复与删除") { DataManagementView() }
            }
            Section("偏好") {
                NavigationLink("AI 与个性化估算") { AISettingsView() }
                NavigationLink("提醒与通知") { ReminderSettingsView() }
                NavigationLink("常用食物") { FavoritesManagementView() }
            }
            Section("隐私与说明") {
                Text("所有主动记录先保存到手机。个人同步、伙伴共享和外部 AI 处理分别控制。")
                Text("导出文件由你保管密码。仅本机数据可通过加密导出包恢复，卸载前请确认备份。")
                PrivacyNote()
                Text("并肩 0.1 · 首版").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("我的")
    }
}

struct ConnectionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var discovery = ServerDiscovery()
    @State private var username = UserDefaults.standard.string(forKey: "last_username") ?? ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var code = ""
    @State private var registration = false
    @State private var mergeLocal = true
    @State private var recovering = false
    @State private var recoveryCode = ""
    @State private var savedRecovery = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("私有服务器") {
                NavigationLink("核验服务身份与证书指纹") { ServerPairingView() }
                TextField("https://服务器地址", text: $model.serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存后台地址") {
                    model.perform { try await model.saveServerAddress(model.serverURL); model.notice = "地址已保存，后续启动自动使用" }
                }
                Button("测试 HTTPS 连接") { model.perform { try await model.checkConnection() } }
                Button(discovery.searching ? "重新发现内网服务" : "发现内网服务") { discovery.start() }
                ForEach(discovery.servers) { server in Button(server.name) { model.serverURL = server.url } }
                Text("内网证书需要在 iPhone 中建立信任。地址变化后会重新验证服务器身份。").font(.caption).foregroundStyle(.secondary)
            }
            Section("个人同步") {
                Toggle("允许个人记录同步到该服务器", isOn: $model.syncEnabled)
                Text("开启后会上传本机待同步记录。共享给伙伴还需另行授权。").font(.caption).foregroundStyle(.secondary)
            }
            if let session = model.session {
                Section("当前账号") {
                    LabeledContent("称呼", value: session.displayName)
                    Text("用户标识 \(session.userId)").font(.caption).textSelection(.enabled)
                    Button("立即同步") { Task { await model.sync() } }
                    Button("退出登录", role: .destructive) { Task { await model.logout() } }
                }
            } else {
                Section("登录或开户") {
                    Toggle("创建新账号", isOn: $registration)
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码，开户至少 10 位", text: $password)
                    if registration {
                        TextField("称呼", text: $displayName)
                        SecureField("部署者提供的开户凭据", text: $code)
                    }
                    Toggle("将当前未绑定的离线记录关联到此账号", isOn: $mergeLocal)
                    Button(registration ? "开户并登录" : "登录") { Task { await authenticate() } }.disabled(busy)
                    if busy { ProgressView() }
                    Button("使用恢复凭据重设密码") { recovering = true }
                }
            }
            if !savedRecovery.isEmpty {
                Section("请保存恢复凭据") {
                    Text(savedRecovery).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("此凭据可重置账号密码，请离线妥善保管。").font(.caption).foregroundStyle(.secondary)
                    Button("复制恢复凭据") { UIPasteboard.general.string = savedRecovery }
                }
            }
        }
        .navigationTitle("服务器与账号")
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $recovering) {
            NavigationStack {
                Form {
                    TextField("用户名", text: $username).textInputAutocapitalization(.never)
                    SecureField("恢复凭据", text: $recoveryCode)
                    SecureField("新密码，至少 10 位", text: $password)
                    Button("重设密码") {
                        Task {
                            do {
                                try await model.api.configure(model.serverURL)
                                let response = try await model.api.send("auth/recover", method: "POST", body: [
                                    "username": .string(username), "recovery_code": .string(recoveryCode), "new_password": .string(password)
                                ], authenticated: false)
                                savedRecovery = response.object?.text("recovery_code") ?? ""
                                recovering = false
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }.navigationTitle("恢复账号").toolbar { Button("关闭") { recovering = false } }
            }
        }
        .alert("连接未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func authenticate() async {
        busy = true
        defer { busy = false }
        do {
            try await model.authenticate(username: username, password: password, displayName: displayName,
                                         code: code, register: registration, mergeLocal: mergeLocal)
            savedRecovery = model.session?.recoveryCode ?? ""
            password = ""
            code = ""
        } catch { self.error = error.localizedDescription }
    }
}

struct DeviceManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var devices: [JSONObject] = []
    var body: some View {
        List {
            Section {
                Text("同一账号可在多台 iPhone 使用。换机登录后拉取记录，编辑冲突由你选择合并。")
                    .font(.subheadline)
            }
            ForEach(devices.indices, id: \.self) { index in
                let device = devices[index]
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.text("name")).font(.headline)
                    Text(device.text("id")).font(.caption2).foregroundStyle(.secondary)
                    Text(device["revoked_at"]?.string == nil ? "有效设备" : "已撤销").font(.caption)
                    if device["revoked_at"]?.string == nil {
                        Button("撤销此设备", role: .destructive) {
                            model.perform {
                                _ = try await model.api.send("auth/revoke-device", method: "POST", body: ["device_id": .string(device.text("id"))])
                                if device.text("id") == model.deviceId { await model.logout() }
                                await load()
                            }
                        }
                    }
                }
            }
        }.navigationTitle("设备管理").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { devices = try await model.api.send("devices").array?.compactMap(\.object) ?? [] }
        catch { model.errorMessage = error.localizedDescription }
    }
}

struct SyncStatusView: View {
    @EnvironmentObject private var model: AppModel
    @State private var logs: [(String, String)] = []
    @State private var commands: [JSONObject] = []
    @State private var failures: [JSONObject] = []
    var body: some View {
        List {
            Section("同步") {
                Text(model.syncStatus)
                LabeledContent("待同步记录", value: String(model.pendingCount))
                Button("立即同步") { Task { await model.sync(); await load() } }.disabled(model.syncing)
                Button("重试失败记录") {
                    model.perform { try await model.requireStore().retryFailed(); await model.sync(); await load() }
                }
            }
            Section("需要处理的冲突") {
                if model.conflicts.isEmpty { Text("当前没有冲突").foregroundStyle(.secondary) }
                ForEach(model.conflicts) { conflict in
                    NavigationLink {
                        ConflictDetailView(conflict: conflict)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(conflict.local.businessDate) · \(conflict.local.kind)")
                            Text(conflict.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Section("失败记录") {
                    ForEach(failures.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failures[index].text("message"))
                            Text(failures[index].text("entity_id")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("离线操作队列") {
                ForEach(commands.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        Text(commands[index].text("path")).font(.caption)
                        Text((commands[index].number("priority") ?? 0) > 0 ? "授权或退出操作优先发送" : "等待发送").font(.caption2).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("取消本机排队操作", role: .destructive) {
                            model.perform {
                                try await model.requireStore().removeCommand(commands[index].text("id"))
                                await load()
                            }
                        }
                    }
                }
            }
            Section("最近日志") {
                ForEach(logs.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(logs[index].1).font(.subheadline)
                        Text(TimeFormat.parse(logs[index].0)?.formatted(date: .abbreviated, time: .shortened) ?? logs[index].0)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("同步状态").task { await load() }
    }
    private func load() async {
        logs = (try? await model.requireStore().logs()) ?? []
        commands = (try? await model.requireStore().pendingCommands()) ?? []
        failures = (try? await model.requireStore().failedRecords()) ?? []
        await model.reload()
    }
}

struct ConflictDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conflict: SyncConflict
    @State private var mergedText = ""
    @State private var showMerge = false
    var body: some View {
        List {
            Section("本机版本") {
                Text((try? Codec.json(conflict.local.payload)) ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("服务器版本") {
                Text(conflict.remote.flatMap { try? Codec.json($0.payload) } ?? "服务器已移除此记录")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section {
                Button(conflict.remote?.deletedAt != nil || conflict.remote == nil ? "将本机内容另存为新记录" : "保留本机内容") {
                    model.perform { try await model.resolveConflict(conflict, keepLocal: true); dismiss() }
                }
                Button("采用服务器版本") {
                    model.perform { try await model.resolveConflict(conflict, keepLocal: false); dismiss() }
                }
                Button("手动合并字段") {
                    mergedText = (try? Codec.json(conflict.local.payload)) ?? "{}"
                    showMerge = true
                }.disabled(conflict.remote == nil || conflict.remote?.deletedAt != nil)
            }
        }.navigationTitle("合并记录")
        .sheet(isPresented: $showMerge) {
            NavigationStack {
                VStack {
                    Text("编辑合并后的 JSON 字段，保存后由相同数据规则校验。").font(.caption).padding()
                    TextEditor(text: $mergedText).font(.system(.caption, design: .monospaced))
                }
                .navigationTitle("字段合并")
                .toolbar {
                    Button("提交合并") {
                        model.perform {
                            let payload = try JSONDecoder().decode(JSONObject.self, from: Data(mergedText.utf8))
                            var merged = conflict
                            merged.local.payload = payload
                            try RecordValidator.validate(merged.local)
                            try await model.resolveConflict(merged, keepLocal: true)
                            showMerge = false
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
