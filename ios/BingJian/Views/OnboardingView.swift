import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var checking = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .bottom, spacing: 8) {
                        RoundedRectangle(cornerRadius: 12).fill(Palette.teal).frame(width: 22, height: 76)
                        RoundedRectangle(cornerRadius: 12).fill(Palette.sage).frame(width: 22, height: 54)
                        Spacer()
                    }.accessibilityHidden(true)
                    Text("先设置一次\n之后安心记录").font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                    Text("后台地址、AI 接口与模型会保存在这台 iPhone。以后可在“我的”里修改。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Surface {
                        Label("后台地址", systemImage: "externaldrive").font(.headline)
                        TextField("https://192.168.1.10:8443", text: $model.serverURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("测试并保存地址") {
                            Task {
                                checking = true
                                defer { checking = false }
                                do { try await model.checkConnection() }
                                catch { message = error.localizedDescription }
                            }
                        }.disabled(checking || model.serverURL.isEmpty)
                        if checking { ProgressView() }
                        NavigationLink("登录或创建后台账号") { ConnectionSettingsView() }
                        NavigationLink("使用部署者的配对信息") { ServerPairingView() }
                        HintLabel(text: "地址可先保存。连接内网服务时，需要信任部署者提供的 HTTPS 证书。")
                    }
                    Surface {
                        Label("AI 接口与模型", systemImage: "viewfinder").font(.headline)
                        if model.aiConfiguration.configured {
                            Text(model.aiConfiguration.model).font(.subheadline)
                            Text(model.aiConfiguration.baseUrl).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("支持 Responses API 风格的接口，可读取模型列表或手动填写模型。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        NavigationLink("设置 AI 地址、密钥和模型") { AIConnectionEditorView() }
                        HintLabel(text: "也可以先使用本机识别或手动记录，之后再配置 AI。")
                    }
                    Button {
                        model.perform { try await model.completeSetup() }
                    } label: { Text("保存并进入").frame(maxWidth: .infinity).padding(.vertical, 10) }
                        .buttonStyle(.borderedProminent)
                    Button("先离线记录，稍后在设置中配置") {
                        model.perform { try await model.completeSetup(offline: true) }
                    }.font(.subheadline).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(Palette.canvas).navigationTitle("欢迎使用并肩").navigationBarTitleDisplayMode(.inline)
        }
        .alert("连接尚未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}
