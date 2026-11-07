import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeading(title: "我的健康日常", subtitle: "按自己的习惯，安排每一天。", artwork: .profile)
                Surface {
                    HStack(spacing: 16) {
                        Text(String((model.profile.displayName.isEmpty ? "我" : model.profile.displayName).prefix(1)))
                            .font(.system(.title, design: .rounded, weight: .medium))
                            .foregroundStyle(.white).frame(width: 66, height: 66)
                            .background(Palette.heroGradient, in: RoundedRectangle(cornerRadius: 23))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.profile.displayName.isEmpty ? "我的记录" : model.profile.displayName)
                                .font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                            StatusPill(title: model.session == nil ? "本机离线记录" : "已登录",
                                       symbol: model.session == nil ? "iphone" : "checkmark.icloud")
                        }
                        Spacer()
                    }
                    Divider()
                    NavigationLink { ProfileEditorView() } label: { SettingsRow(title: "身体档案与目标", symbol: "person.text.rectangle") }
                    NavigationLink { MeasurementEditorView() } label: { SettingsRow(title: "身体组成与围度", symbol: "figure.stand", color: Palette.purple) }
                }
                Text("连接与数据").font(.headline).foregroundStyle(Palette.ink).padding(.horizontal, 4)
                Surface {
                    NavigationLink { AISettingsView() } label: {
                        SettingsRow(title: "AI 与个性化估算", symbol: "sparkle",
                                    detail: model.aiConfiguration.configured ? model.aiConfiguration.model : "设置接口与模型", color: Palette.purple)
                    }
                    Divider()
                    NavigationLink { ConnectionSettingsView() } label: {
                        SettingsRow(title: "私有服务器与账号", symbol: "externaldrive", detail: "后台地址保存后自动使用")
                    }
                    NavigationLink { HealthSettingsView() } label: { SettingsRow(title: "健康权限与历史回填", symbol: "heart", color: Palette.peach) }
                    NavigationLink { SyncStatusView() } label: { SettingsRow(title: "同步状态与冲突", symbol: "arrow.triangle.2.circlepath") }
                    NavigationLink { DeviceManagementView() } label: { SettingsRow(title: "设备与登录管理", symbol: "iphone.gen3", color: Palette.purple) }
                    NavigationLink { DataManagementView() } label: { SettingsRow(title: "导出、恢复与删除", symbol: "tray.and.arrow.down") }
                }
                Text("使用偏好").font(.headline).foregroundStyle(Palette.ink).padding(.horizontal, 4)
                Surface {
                    Picker("本机体重单位", selection: Binding(get: { model.weightUnit }, set: { model.setWeightUnit($0) })) {
                        ForEach(WeightUnit.allCases) { Text($0.title).tag($0) }
                    }.tint(Palette.teal)
                    Text("体重、目标、历史和伙伴数据统一换算显示，后续录入自动沿用。")
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Divider()
                    NavigationLink { ReminderSettingsView() } label: { SettingsRow(title: "提醒与通知", symbol: "bell", color: Palette.peach) }
                    NavigationLink { FavoritesManagementView() } label: { SettingsRow(title: "常用食物", symbol: "bookmark", color: Palette.peach) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("记录与隐私，由你掌握", systemImage: "lock.shield").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("所有主动记录先保存到手机。个人同步、伙伴共享和外部 AI 处理分别控制。")
                    Text("导出文件由你保管密码。仅本机数据可通过加密导出包恢复，卸载前请确认备份。")
                    PrivacyNote()
                    Text("并肩 · 0.1.9").font(.caption2).accessibilityIdentifier("page.end.settings")
                }.font(.caption).foregroundStyle(Palette.secondary).padding(.horizontal, 4)
            }.padding(16).buttonStyle(.plain)
        }.background(Palette.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Text("我的").font(.title3.bold()).foregroundStyle(Palette.ink) } }
    }
}

struct ConnectionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var discovery = ServerDiscovery()
    @State private var username = UserDefaults.standard.string(forKey: "last_username") ?? ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var registration = false
    @State private var mergeLocal = true
    @State private var recovering = false
    @State private var recoveryCode = ""
    @State private var savedRecovery = ""
    @State private var error: String?
    @State private var errorTitle = "账号操作未完成"
    @State private var accountErrors: [AccountField: String] = [:]
    @State private var submitted = false
    @State private var busy = false

    private var accountInput: AccountInput {
        AccountInput(username: username, password: password, displayName: displayName)
    }

    var body: some View {
        AppForm {
            FormIntro(title: "连接你的记录空间", subtitle: "后台地址只需保存一次，之后可随时在这里更改。", symbol: "externaldrive", color: Palette.teal)
            Section("私有服务器") {
                NavigationLink("核验服务身份与证书指纹") { ServerPairingView() }
                FormField(title: "后台地址") {
                    TextField("http:// 或 https://服务器地址", text: $model.serverURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("保存后台地址") {
                    model.perform { try await model.saveServerAddress(model.serverURL); model.notice = "地址已保存，后续启动自动使用" }
                }
                Button("测试后台连接") { model.perform { try await model.checkConnection() } }
                Button(discovery.searching ? "重新发现内网服务" : "发现内网服务") { discovery.start() }
                ForEach(discovery.servers) { server in Button(server.name) { model.serverURL = server.url } }
                Text("支持 HTTP 和 HTTPS。HTTP 明文传输，建议仅在可信局域网使用；HTTPS 内网证书需要在 iPhone 中建立信任。").font(.caption).foregroundStyle(.secondary)
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
                    Toggle("创建新账号", isOn: $registration).disabled(busy)
                    AccountFieldsView(username: $username, password: $password, displayName: $displayName,
                                      registration: registration, errors: accountErrors).disabled(busy)
                    Toggle("将当前未绑定的离线记录关联到此账号", isOn: $mergeLocal)
                    Button(registration ? "开户并登录" : "登录") { Task { await authenticate() } }.buttonStyle(FilledActionStyle()).disabled(busy)
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
        .onChange(of: accountInput) { previous, value in
            if submitted { accountErrors = value.updatedErrors(from: previous, errors: accountErrors, registration: registration) }
        }
        .onChange(of: registration) { _, _ in submitted = false; accountErrors = [:] }
        .sheet(isPresented: $recovering) {
            NavigationStack {
                AppForm {
                    FormIntro(title: "找回你的记录", subtitle: "使用开户时保存的恢复凭据重设密码。", symbol: "key", color: Palette.purple)
                    FormField(title: "用户名") { TextField("用户名", text: $username).textInputAutocapitalization(.never) }
                    FormField(title: "恢复凭据") { SecureField("恢复凭据", text: $recoveryCode) }
                    FormField(title: "新密码") { SecureField("至少 10 位", text: $password) }
                    Button("重设密码") {
                        Task {
                            do {
                                try await model.api.configure(model.serverURL)
                                let response = try await model.api.send("auth/recover", method: "POST", body: [
                                    "username": .string(username), "recovery_code": .string(recoveryCode), "new_password": .string(password)
                                ], authenticated: false)
                                savedRecovery = response.object?.text("recovery_code") ?? ""
                                recovering = false
                            } catch { errorTitle = "重设密码未完成"; self.error = error.localizedDescription }
                        }
                    }
                }.navigationTitle("恢复账号").toolbar { Button("关闭") { recovering = false } }
            }
        }
        .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func authenticate() async {
        submitted = true
        accountErrors = accountInput.validationErrors(registration: registration)
        guard accountErrors.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.authenticate(username: username, password: password, displayName: displayName,
                                         register: registration, mergeLocal: mergeLocal)
            savedRecovery = model.session?.recoveryCode ?? ""
            submitted = false
            accountErrors = [:]
            password = ""
        } catch {
            if let apiError = error as? APIError {
                for (key, message) in apiError.fieldErrors {
                    if let field = AccountField(rawValue: key) { accountErrors[field] = message }
                }
            }
            if accountErrors.isEmpty {
                errorTitle = registration ? "开户未完成" : "登录未完成"
                self.error = error.localizedDescription
            }
        }
    }
}

struct DeviceManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var devices: [JSONObject] = []
    var body: some View {
        AppList {
            FormIntro(title: "管理已登录的设备", subtitle: "查看设备状态，移除不再使用的登录。", symbol: "iphone.gen3", color: Palette.purple)
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
        AppList {
            FormIntro(title: "让记录保持同步", subtitle: "查看同步进度，处理需要确认的记录。", symbol: "arrow.triangle.2.circlepath", color: Palette.teal)
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
        AppList {
            FormIntro(title: "确认要保留的内容", subtitle: "对照本机与后台版本，再决定如何合并。", symbol: "square.stack.3d.up", color: Palette.peach)
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
                AppForm {
                    FormIntro(title: "合并记录内容", subtitle: "编辑合并后的 JSON 字段，保存时会校验数据。", symbol: "square.stack.3d.up", color: Palette.peach)
                    Section("合并后的字段") {
                        TextEditor(text: $mergedText).font(.system(.caption, design: .monospaced)).frame(minHeight: 300)
                    }
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
