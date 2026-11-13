import SwiftUI

/// 官方账号入口只使用构建时配置的服务地址，不接收用户输入的云端地址。
struct CloudAccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode = "login"
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var emailCode = ""
    @State private var mergeLocal = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var newEmail = ""
    @State private var changeEmailCode = ""
    @State private var busy = false
    @State private var changingIdentity = false
    @State private var operationID = UUID()
    @State private var message = ""
    @State private var error: String?
    @State private var confirmLogoutAll = false

    private var emailInput: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var newEmailInput: String { newEmail.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppForm {
            FormIntro(title: "你的云端记录空间", subtitle: "基础记录可离线保存，登录后按你的选择同步。", symbol: "person.crop.circle", color: Palette.teal)
            if !model.cloudServerConfigured {
                Section("官方云服务尚未启用") {
                    Text("当前版本尚未配置官方云服务。你可以继续离线记录，也可以使用已有的私有服务器。")
                    if !model.isCloudMode {
                        NavigationLink("已有私有服务器与账号") { ConnectionSettingsView() }
                    }
                }
            } else if !model.isCloudMode || !model.cloudServerSelected {
                Section("连接官方云服务") {
                    Text("官方账号与私有服务器账号分别保存。切换后，原空间的记录仍保留在本机。")
                    Button("使用官方云账号") {
                        run(changesIdentity: true) { try await model.enterCloudAccount() }
                    }.buttonStyle(FilledActionStyle()).disabled(busy)
                }
            } else if model.session != nil {
                accountSections
            } else {
                authenticationSections
            }
            if busy { Section { ProgressView("正在处理…") } }
            if !message.isEmpty { Section { Text(message).font(.subheadline) } }
        }
        .navigationTitle("云端账号")
        .task {
            if model.isCloudMode { await model.refreshCloudAccount() }
        }
        .onChange(of: model.localDataContext) { _, _ in
            // 登录、退出和切换官方服务本身会更换上下文，保留该次操作的错误回显。
            guard !(busy && changingIdentity) else { return }
            // 切换身份后，不让旧页面的输入和异步提示继续留在新账号下。
            operationID = UUID()
            busy = false
            mode = "login"
            email = ""
            password = ""
            displayName = ""
            emailCode = ""
            mergeLocal = false
            currentPassword = ""
            newPassword = ""
            newEmail = ""
            changeEmailCode = ""
            message = ""
            error = nil
            confirmLogoutAll = false
        }
        .alert("账号操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("退出所有设备上的云端登录？本机记录会保留。", isPresented: $confirmLogoutAll, titleVisibility: .visible) {
            Button("退出全部设备", role: .destructive) { run(changesIdentity: true) { try await model.logoutAll() } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private var authenticationSections: some View {
        Section(mode == "reset" ? "找回账号密码" : "注册或登录") {
            if mode != "reset" {
                Picker("账号操作", selection: $mode) {
                    Text("登录").tag("login")
                    Text("注册").tag("register")
                }.pickerStyle(.segmented)
            }
            FormField(title: "邮箱") {
                TextField("用于登录和找回密码", text: $email)
                    .keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("cloud.email")
            }
            if mode == "register" {
                FormField(title: "称呼") {
                    TextField("你希望显示的名字", text: $displayName).textContentType(.nickname)
                }
            }
            FormField(title: mode == "reset" ? "新密码" : "密码") {
                SecureField(mode == "login" ? "请输入密码" : "至少 10 位", text: $password)
                    .textContentType(mode == "login" ? .password : .newPassword)
                    .accessibilityIdentifier("cloud.password")
            }
            if mode != "login" {
                FormField(title: "邮箱验证码") {
                    TextField("请输入验证码", text: $emailCode).textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("发送邮箱验证码") {
                    let purpose = mode == "register" ? "register" : "reset_password"
                    let destination = emailInput
                    run(success: { message = "验证码请求已受理。若该邮箱符合当前操作条件，请稍后查看收件箱。" }) {
                        try await model.sendCloudEmailCode(email: destination, purpose: purpose)
                    }
                }.disabled(emailInput.isEmpty)
            }
            if mode != "reset" {
                Toggle("将当前未绑定的离线记录关联到此账号", isOn: $mergeLocal)
                Text("仅在确定这些离线记录属于此账号时开启。其他账号的本机记录不会自动合并。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(mode == "register" ? "注册并登录" : mode == "reset" ? "重设密码" : "登录") {
                authenticate()
            }.buttonStyle(FilledActionStyle())
                .disabled(emailInput.isEmpty || password.isEmpty || (mode != "login" && emailCode.isEmpty))
            if mode == "reset" {
                Button("返回登录") { mode = "login"; password = ""; emailCode = ""; message = "" }
            } else {
                Button("忘记密码") { mode = "reset"; password = ""; emailCode = ""; message = "" }
            }
        }.disabled(busy)
    }

    @ViewBuilder private var accountSections: some View {
        Section("当前账号") {
            LabeledContent("称呼", value: model.cloudAccount.text("display_name", fallback: model.session?.displayName ?? ""))
            LabeledContent("邮箱", value: model.cloudAccount.text("email", fallback: "尚未绑定邮箱"))
            if !model.cloudReady { Text("账号状态尚未刷新，暂不开放需要在线确认的能力。").font(.caption).foregroundStyle(.secondary) }
            Button("刷新账号状态") { run { await model.refreshCloudAccount() } }.disabled(busy)
        }
        Section("账号权益") {
            LabeledContent("当前权益", value: model.entitlements.isEmpty ? "待核实" : model.entitlements.text("tier") == "svip" ? "SVIP" : "基础账号")
            if let until = TimeFormat.parse(model.entitlements.text("valid_until")) {
                LabeledContent("有效期至", value: until.formatted(date: .abbreviated, time: .shortened))
            }
            Text("体重、饮食、健康记录、趋势及个人同步均可继续使用。")
                .font(.caption).foregroundStyle(.secondary)
            if model.canUseAI {
                NavigationLink("云端 AI 与照片处理授权") { AIConnectionEditorView() }
                let quota = model.entitlements["quota"]?.object ?? [:]
                if let remaining = quota.number("remaining") {
                    LabeledContent("今日剩余识别次数", value: String(Int(remaining)))
                }
            } else {
                Text(model.aiAccessMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("个人同步") {
            Toggle("允许个人记录同步到云端", isOn: $model.syncEnabled)
            Text("照片是否同步由每餐的照片开关决定；给伙伴共享仍需另行授权。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.syncStatus).font(.caption).foregroundStyle(.secondary)
            Button("立即同步") { run { await model.sync() } }.disabled(busy || !model.syncEnabled)
        }
        if model.cloudConsent.flag("allowed") {
            Section("照片处理授权") {
                Text("你已允许当前披露的 AI 处理方接收所选照片。撤回后不再提交新的外部识别。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("撤回照片处理授权", role: .destructive) {
                    run(success: { message = "照片处理授权已撤回。" }) {
                        try await model.setCloudAIConsent(false)
                    }
                }.disabled(busy)
            }
        }
        Section("账号安全") {
            FormField(title: "当前密码") { SecureField("修改密码或邮箱时填写", text: $currentPassword).textContentType(.password) }
            FormField(title: "新密码") { SecureField("至少 10 位", text: $newPassword).textContentType(.newPassword) }
            Button("修改密码") {
                let current = currentPassword, replacement = newPassword
                run(changesIdentity: true, success: { currentPassword = ""; newPassword = ""; message = "密码已修改，请使用新密码重新登录。" }) {
                    try await model.changeCloudPassword(currentPassword: current, newPassword: replacement)
                }
            }.disabled(currentPassword.isEmpty || newPassword.isEmpty)
            FormField(title: "新邮箱") {
                TextField("请输入新的邮箱", text: $newEmail).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("向新邮箱发送验证码") {
                let destination = newEmailInput, current = currentPassword
                run(success: { message = "验证码请求已受理，请稍后查看新邮箱。" }) {
                    try await model.sendCloudEmailChangeCode(email: destination, currentPassword: current)
                }
            }.disabled(newEmailInput.isEmpty || currentPassword.isEmpty)
            FormField(title: "新邮箱验证码") {
                TextField("请输入验证码", text: $changeEmailCode).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("确认修改邮箱") {
                let destination = newEmailInput, code = changeEmailCode, current = currentPassword
                run(success: { currentPassword = ""; newEmail = ""; changeEmailCode = ""; message = "邮箱已修改。" }) {
                    try await model.changeCloudEmail(email: destination, code: code, currentPassword: current)
                }
            }.disabled(newEmailInput.isEmpty || currentPassword.isEmpty || changeEmailCode.isEmpty)
        }.disabled(busy)
        Section {
            Button("退出当前登录", role: .destructive) { run(changesIdentity: true) { await model.logout() } }.disabled(busy)
            Button("退出全部设备", role: .destructive) { confirmLogoutAll = true }.disabled(busy)
        }
    }

    private func authenticate() {
        let destination = emailInput, enteredPassword = password, code = emailCode
        let registering = mode == "register", resetting = mode == "reset"
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines), merge = mergeLocal
        run(changesIdentity: true, success: {
            password = ""
            emailCode = ""
            if resetting { mode = "login"; message = "密码已重设，请使用新密码登录。" }
        }) {
            if resetting {
                try await model.resetCloudPassword(email: destination, code: code, newPassword: enteredPassword)
            } else {
                try await model.authenticateCloud(email: destination, password: enteredPassword, displayName: name,
                                                  emailCode: code, register: registering, mergeLocal: merge)
            }
        }
    }

    /// 网络操作不触发业务记录重载，旧身份的响应也不再改写当前页面状态。
    private func run(changesIdentity: Bool = false, success: @escaping @MainActor () -> Void = {}, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let context = model.localDataContext
        let identifier = UUID()
        operationID = identifier
        busy = true
        changingIdentity = changesIdentity
        error = nil
        message = ""
        Task { @MainActor in
            defer {
                if operationID == identifier { busy = false; changingIdentity = false }
            }
            do {
                guard context == model.localDataContext else { return }
                try await operation()
                guard operationID == identifier, changesIdentity || context == model.localDataContext else { return }
                if changesIdentity {
                    password = ""
                    emailCode = ""
                    currentPassword = ""
                    newPassword = ""
                    changeEmailCode = ""
                    mergeLocal = false
                }
                success()
            } catch is CancellationError { }
            catch {
                guard operationID == identifier, changesIdentity || context == model.localDataContext else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
