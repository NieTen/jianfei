import SwiftUI

struct AIConnectionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AIConfiguration()
    @State private var apiKey = ""
    @State private var allowProcessing = false
    @State private var models: [AIModelOption] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var message = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Responses API 接口") {
                TextField("https://api.openai.com/v1", text: $configuration.baseUrl)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(model.aiHasServerKey && apiKey.isEmpty ? "后台已保存密钥，留空保持" : "API Key", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                TextField("模型标识，也可手动填写", text: $configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("读取可用模型列表") {
                    Task {
                        loading = true
                        defer { loading = false }
                        do {
                            models = try await model.loadAIModels(configuration: configuration, apiKey: apiKey)
                            message = "已读取 \(models.count) 个模型，请选择支持图像输入的模型"
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(loading)
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
                Button("测试连接") {
                    Task {
                        loading = true
                        defer { loading = false }
                        do { message = try await model.testAI(configuration: configuration, apiKey: apiKey) }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(loading)
                Button("保存 AI 设置") { Task { await save() } }.disabled(loading)
                if loading { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if model.aiConfigurationPending { Text("本机设置已保存，等待连接后台后同步").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("AI 接口与模型")
        .task {
            guard !loaded else { return }
            await model.hydrateAIConfiguration()
            configuration = model.aiConfiguration
            apiKey = model.aiAPIKey()
            allowProcessing = model.externalAIConsent
            models = model.availableAIModels
            loaded = true
        }
        .onChange(of: configuration.baseUrl) { old, new in
            guard loaded, (try? AIAddress.normalize(old)) != (try? AIAddress.normalize(new)) else { return }
            apiKey = ""
            models = []
            allowProcessing = false
            configuration.useServerDefaults = false
        }
        .onChange(of: configuration.model) { _, _ in
            if loaded { allowProcessing = false; configuration.useServerDefaults = false }
        }
        .alert("AI 设置尚未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func save() async {
        loading = true
        defer { loading = false }
        do {
            try await model.saveAIConfiguration(configuration, apiKey: apiKey)
            model.externalAIConsent = allowProcessing
            model.aiMode = "server"
            model.notice = "AI 地址与模型已保存，后续启动自动复用"
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
