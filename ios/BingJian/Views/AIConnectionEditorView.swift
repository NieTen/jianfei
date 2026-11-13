import SwiftUI

struct AIConnectionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AIConfiguration()
    @State private var apiKey = ""
    @State private var allowProcessing = false
    @State private var models: [AIModelOption] = []
    @State private var cloudModelID = ""
    @State private var loading = false
    @State private var loaded = false
    @State private var loadedContext: UUID?
    @State private var message = ""
    @State private var error: String?
    @State private var operationID = UUID()
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        AppForm {
            if !model.canUseAI {
                Section("当前账号未开放 AI") {
                    Text(model.aiAccessMessage)
                    Text("手动记录、营养库和已保存的食物明细仍可使用。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("查看云端账号状态") { CloudAccountView() }
                }
            } else if model.isCloudMode {
                cloudSections
            } else {
                legacySections
            }
        }
        .disabled(loading)
        .navigationTitle(model.isCloudMode ? "云端 AI" : "AI 接口与模型")
        .task(id: model.localDataContext) { await loadConfiguration() }
        .onChange(of: model.localDataContext) { _, _ in
            operationTask?.cancel()
            operationID = UUID()
            loaded = false
            loading = false
            apiKey = ""
            allowProcessing = false
            models = []
            message = ""
            error = nil
        }
        .onChange(of: model.canUseAI) { _, permitted in
            if !permitted {
                operationTask?.cancel()
                operationID = UUID()
                loading = false
                apiKey = ""
                allowProcessing = false
            }
        }
        .onChange(of: model.cloudAI["provider_revision"]) { previous, _ in
            if loaded, model.isCloudMode, previous != nil, previous != .null {
                allowProcessing = false
                message = "照片处理方已变化，请重新核对授权。"
            }
        }
        .onChange(of: configuration.baseUrl) { old, new in
            guard loaded, !model.isCloudMode, (try? AIAddress.normalize(old)) != (try? AIAddress.normalize(new)) else { return }
            apiKey = ""
            models = []
            allowProcessing = false
            configuration.useServerDefaults = false
        }
        .onChange(of: configuration.model) { _, _ in
            if loaded, !model.isCloudMode { allowProcessing = false; configuration.useServerDefaults = false }
        }
        .alert("AI 设置尚未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var cloudSections: some View {
        FormIntro(title: "云端餐食识别", subtitle: "选择可用模型，并确认照片处理授权。", symbol: "sparkles", color: Palette.purple)
        Section("云端提供的服务") {
            LabeledContent("处理方", value: model.cloudAI.text("provider_name", fallback: "尚未配置"))
            if !models.isEmpty {
                Picker("识别模型", selection: $cloudModelID) {
                    Text("请选择模型").tag("")
                    ForEach(models) { value in Text(value.name).tag(value.id) }
                }
            } else {
                Text("当前没有可用模型，请稍后刷新。")
            }
            Text("服务接口与密钥由云端管理，手机只使用已开放的模型。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("照片处理授权") {
            Text(model.cloudAI.flag("external")
                 ? "识别时，所选餐食照片和相关说明会交给上方披露的外部处理方。"
                 : "识别时，所选餐食照片和相关说明会发送到云端处理。")
                .font(.subheadline)
            Toggle("允许当前处理方分析所选餐食照片", isOn: $allowProcessing)
            Text("仅授权当前披露的处理方。处理方改变后需要重新确认，可随时关闭授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("保存云端 AI 设置", action: saveCloud).buttonStyle(FilledActionStyle())
                .disabled(loading || cloudModelID.isEmpty || !model.cloudReady)
            Button("刷新云端配置") {
                loaded = false
                run { context in
                    await loadConfiguration()
                    try validate(context)
                }
            }.disabled(loading)
            if loading { ProgressView() }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var legacySections: some View {
        Group {
            FormIntro(title: "让每一餐更好记", subtitle: "保存接口与模型后，下次识别会自动使用。", symbol: "sparkles", color: Palette.purple)
            Section("Responses API 接口") {
                FormField(title: "接口地址") {
                    TextField("https://api.openai.com/v1", text: $configuration.baseUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                FormField(title: "API 密钥") {
                    SecureField(model.hasSavedAIKey(for: configuration) ? "已保存密钥，留空保持" : "API Key", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("ai.key")
                }
                if model.hasSavedAIKey(for: configuration) {
                    Text("已保存的密钥不回显。留空时，保存、读取模型和测试连接都会使用原密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("调用方式", selection: $configuration.execution) {
                    Text("通过私有后台").tag("gateway")
                    Text("由 iPhone 直连").tag("direct")
                }
                Text("接口使用 POST /responses。可填写 API 根地址或完整 /responses 地址，保存后自动规范化。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("模型") {
                if !models.isEmpty {
                    Picker("可用模型", selection: $configuration.model) {
                        Text("请选择模型").tag("")
                        if !configuration.model.isEmpty && !models.contains(where: { $0.id == configuration.model }) {
                            Text(configuration.model + "（手动填写）").tag(configuration.model)
                        }
                        ForEach(models) { value in Text(value.name).tag(value.id) }
                    }
                }
                FormField(title: "模型标识") {
                    TextField("选择模型或手动填写", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("读取可用模型列表", action: loadModels).disabled(loading)
                Toggle("使用严格 JSON 结构化输出", isOn: $configuration.structuredOutput)
                Stepper("输出上限 \(configuration.maxOutputTokens) tokens", value: $configuration.maxOutputTokens, in: 1024...16384, step: 1024)
                Text("接口未提供模型能力字段时，图像与结构化输出兼容性在实际识别中校验。").font(.caption).foregroundStyle(.secondary)
            }
            Section("照片处理授权") {
                Toggle("该接口位于外网或会转发到外部模型", isOn: $configuration.external)
                if configuration.external {
                    Toggle("同意向此接口发送选中的餐食照片", isOn: $allowProcessing)
                }
                if configuration.execution == "gateway" {
                    Toggle("内网不可达时允许手机直连此 AI", isOn: $configuration.allowOutsideLan)
                }
                Text(configuration.execution == "gateway"
                     ? "密钥保存在本机钥匙串，并加密保存到你的私有后台。更换接口时会重新确认授权。"
                     : "密钥保存在本机钥匙串，手机直接向所选 HTTPS 接口发起请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("测试连接", action: testConnection).disabled(loading)
                Button("保存 AI 设置", action: saveLegacy).buttonStyle(FilledActionStyle()).disabled(loading)
                if loading { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if model.aiConfigurationPending { Text("本机设置已保存，等待连接后台后同步").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func loadConfiguration() async {
        let context = model.localDataContext
        guard !loaded || loadedContext != context else { return }
        if model.isCloudMode {
            await model.refreshCloudAccount()
            guard context == model.localDataContext, model.canUseAI else { return }
            cloudModelID = model.cloudAI.text("model_id")
            models = model.cloudAI.objects("models").map { AIModelOption(id: $0.text("id"), name: $0.text("name", fallback: $0.text("id"))) }
            allowProcessing = model.cloudConsent.flag("allowed")
                && model.cloudConsent["provider_revision"] == model.cloudAI["provider_revision"]
        } else {
            guard model.canUseAI else { return }
            await model.hydrateAIConfiguration()
            guard context == model.localDataContext, model.canUseAI, !model.isCloudMode else { return }
            configuration = model.aiConfiguration
            allowProcessing = model.externalAIConsent
            models = model.availableAIModels
        }
        apiKey = ""
        loadedContext = context
        loaded = true
    }

    private func loadModels() {
        let value = configuration, key = apiKey
        run { context in
            guard !model.isCloudMode else { throw CancellationError() }
            let result = try await model.loadAIModels(configuration: value, apiKey: key)
            try validate(context)
            models = result
            message = "已读取 \(result.count) 个模型，请选择支持图像输入的模型"
        }
    }

    private func testConnection() {
        let value = configuration, key = apiKey
        run { context in
            guard !model.isCloudMode else { throw CancellationError() }
            let result = try await model.testAI(configuration: value, apiKey: key)
            try validate(context)
            message = result
        }
    }

    private func saveLegacy() {
        let value = configuration, key = apiKey, consent = allowProcessing
        run { context in
            guard !model.isCloudMode else { throw CancellationError() }
            try await model.saveAIConfiguration(value, apiKey: key)
            try validate(context)
            model.externalAIConsent = consent
            model.aiMode = "server"
            model.notice = "AI 地址与模型已保存，后续启动自动复用"
            dismiss()
        }
    }

    private func saveCloud() {
        let selected = cloudModelID, consent = allowProcessing
        run { context in
            guard model.isCloudMode else { throw CancellationError() }
            if selected != model.cloudAI.text("model_id") {
                try await model.selectCloudAIModel(selected)
                try validate(context)
            }
            try await model.setCloudAIConsent(consent)
            try validate(context)
            message = "云端模型和照片处理授权已保存"
        }
    }

    private func validate(_ context: UUID) throws {
        try Task.checkCancellation()
        guard context == model.localDataContext else { throw CancellationError() }
        guard model.canUseAI else { throw APIError(code: "AI_ACCESS_DENIED", message: model.aiAccessMessage) }
    }

    private func run(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !loading else { return }
        let context = model.localDataContext, identifier = UUID()
        operationID = identifier
        loading = true
        message = ""
        error = nil
        operationTask = Task { @MainActor in
            defer { if operationID == identifier { loading = false } }
            do {
                try validate(context)
                try await operation(context)
            } catch is CancellationError { }
            catch {
                guard context == model.localDataContext, operationID == identifier else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
