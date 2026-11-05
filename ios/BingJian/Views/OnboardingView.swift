import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var checking = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        BrandMark()
                        Spacer()
                        StatusPill(title: "支持离线记录", symbol: "iphone")
                    }
                    PageHeading(title: "和自己的身体\n慢慢熟悉",
                                subtitle: "先设置一次，之后安心记录。后台与 AI 配置会保存，以后可在“我的”里修改。")
                    Surface {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: "externaldrive")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("连接你的后台").font(.headline).foregroundStyle(Palette.ink)
                                Text("用于同步记录与伙伴共享").font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                        TextField("https://192.168.1.10:8443", text: $model.serverURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityLabel("后台地址")
                        Button("测试并保存地址") {
                            Task {
                                checking = true
                                defer { checking = false }
                                do { try await model.checkConnection() }
                                catch { message = error.localizedDescription }
                            }
                        }.frame(minHeight: 44).disabled(checking || model.serverURL.isEmpty)
                        if checking { ProgressView() }
                        NavigationLink("登录或创建后台账号") { ConnectionSettingsView() }.frame(minHeight: 44, alignment: .leading)
                        NavigationLink("使用部署者的配对信息") { ServerPairingView() }.frame(minHeight: 44, alignment: .leading)
                        HintLabel(text: "地址可先保存。连接内网服务时，需要信任部署者提供的 HTTPS 证书。")
                    }
                    Surface {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: "viewfinder")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("让记录轻松一点").font(.headline).foregroundStyle(Palette.ink)
                                Text("配置 AI 接口与模型").font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                        if model.aiConfiguration.configured {
                            Text(model.aiConfiguration.model).font(.subheadline)
                            Text(model.aiConfiguration.baseUrl).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("支持 Responses API 风格的接口，可读取模型列表或手动填写模型。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        NavigationLink("设置 AI 地址、密钥和模型") { AIConnectionEditorView() }.frame(minHeight: 44, alignment: .leading)
                        HintLabel(text: "也可以先使用本机识别或手动记录，之后再配置 AI。")
                    }
                }.padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    Button("保存并进入") {
                        model.perform { try await model.completeSetup() }
                    }.buttonStyle(FilledActionStyle())
                    Button("先离线记录，稍后配置") {
                        model.perform { try await model.completeSetup(offline: true) }
                    }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                }.padding(.horizontal, 20).padding(.top, 12).background(Palette.canvas)
            }
            .background(Palette.canvas).navigationTitle("欢迎使用并肩").navigationBarTitleDisplayMode(.inline)
        }
        .alert("连接尚未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}
