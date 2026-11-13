import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step: Int
    @State private var input = OnboardingInput()
    @State private var errors: [String: String] = [:]
    @State private var loaded = false
    @State private var profileId = UUID().uuidString.lowercased()
    @State private var weightId = UUID().uuidString.lowercased()

    init(initialStep: Int = 0) { _step = State(initialValue: initialStep) }

    var body: some View {
        Group {
            if step == 2 {
                ConnectionSetupView(onBack: { step = 1 }) { offline in
                    try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: offline)
                }
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack { BrandMark(); Spacer(); StatusPill(title: "第 \(step + 1) 步，共 3 步", symbol: "leaf") }
                            ProgressView(value: Double(step + 1), total: 3).tint(Palette.teal)
                            PageHeading(title: step == 0 ? "先认识一下你" : "平时活动多吗？",
                                        subtitle: step == 0 ? "填写身体信息，用来估算每天的热量消耗。之后可以在“我的”中修改。" : "没有健康数据时，按你的活动水平估算消耗。",
                                        artwork: step == 0 ? .profile : .sunrise)
                            if step == 0 { bodyInformation } else { activityInformation }
                        }.padding(16)
                    }.scrollDismissesKeyboard(.interactively)
                        .safeAreaInset(edge: .bottom) {
                            Button("继续") {
                                if step == 0 {
                                    errors = input.errors
                                    guard errors.isEmpty else { return }
                                }
                                step += 1
                            }.buttonStyle(FilledActionStyle()).padding(20).background(Palette.canvas)
                        }
                        .background(Palette.canvas).navigationTitle("欢迎使用并肩").navigationBarTitleDisplayMode(.inline)
                        .modifier(KeyboardDismissToolbar())
                        .toolbar {
                            if step > 0 { ToolbarItem(placement: .navigationBarLeading) { Button("上一步") { step -= 1 } } }
                        }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let profile = model.profile
            input.age = profile.age
            if let birth = profile.birthDate.flatMap({ TimeFormat.window($0, timezone: profile.timezone)?.start }) {
                input.age = Calendar.current.dateComponents([.year], from: birth, to: Date()).year
            }
            input.heightCm = profile.heightCm
            input.sex = profile.sexForFormula
            input.unit = model.weightUnit
            input.weight = model.summary.weight.map { model.weightUnit.fromKilograms($0) }
            input.activityFactor = profile.activityFactor
            input.recordingOnly = profile.recordingOnly
        }
        .onChange(of: input) { _, _ in
            if !errors.isEmpty { errors = input.errors.filter { errors[$0.key] != nil } }
        }
    }

    private var bodyInformation: some View {
        Surface {
            HStack {
                Text("年龄")
                TextField("请输入", value: $input.age, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityLabel("年龄")
                Text("岁").foregroundStyle(.secondary)
            }.frame(minHeight: 44).modifier(AccountFieldStyle(message: errors["age"]))
            Divider()
            HStack {
                Text("身高")
                TextField("请输入", value: $input.heightCm, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel("身高")
                Text("厘米").foregroundStyle(.secondary)
            }.frame(minHeight: 44).modifier(AccountFieldStyle(message: errors["height"]))
            Divider()
            WeightInputRow(amount: $input.weight, unit: $input.unit).modifier(AccountFieldStyle(message: errors["weight"]))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("用于消耗估算的性别参数").font(.subheadline)
                Picker("性别参数", selection: $input.sex) {
                    Text("请选择").tag("unspecified")
                    Text("男性").tag("male")
                    Text("女性").tag("female")
                }.pickerStyle(.segmented)
            }.modifier(AccountFieldStyle(message: errors["sex"]))
            Text("这些信息仅用于估算，不会自动向伙伴共享。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activityInformation: some View {
        VStack(spacing: 16) {
            Surface {
                ForEach([1.2, 1.375, 1.55, 1.725, 1.9], id: \.self) { factor in
                    Button { input.activityFactor = factor } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activityTitle(factor)).font(.headline).foregroundStyle(Palette.ink)
                                Text(activityDetail(factor)).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: input.activityFactor == factor ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Palette.teal)
                        }.padding(12).frame(minHeight: 60)
                            .background(input.activityFactor == factor ? Palette.soft : Palette.canvas,
                                        in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityAddTraits(input.activityFactor == factor ? .isSelected : [])
                }
            }
            Surface {
                Toggle("仅记录，不估算消耗", isOn: $input.recordingOnly)
                Text((input.age ?? 0) < 18 ? "未满 18 岁会自动使用记录模式，保留体重与饮食记录。" : "需要只记录饮食与体重时可开启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activityTitle(_ value: Double) -> String {
        [1.2: "大多坐着", 1.375: "轻度活动", 1.55: "中等活动", 1.725: "活动较多", 1.9: "高强度活动"][value] ?? "活动水平"
    }
    private func activityDetail(_ value: Double) -> String {
        [1.2: "工作学习以坐着为主，很少运动", 1.375: "日常走动，偶尔运动", 1.55: "每周规律运动，日常活动适中", 1.725: "多数日子运动或经常体力活动", 1.9: "持续高强度运动或重体力活动"][value] ?? ""
    }
}


struct ConnectionSetupView: View {
    let onBack: () -> Void
    let onFinish: (Bool) async throws -> Void
    @EnvironmentObject private var model: AppModel
    @State private var message: String?
    @State private var checking = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        BrandMark()
                        Spacer()
                        StatusPill(title: "支持离线记录", symbol: "iphone")
                    }
                    PageHeading(title: "最后，连接你的服务",
                                subtitle: "第 3 步，共 3 步。可以登录云端账号，也可以先离线记录；身体信息先保存在本机。", artwork: .connection)
                    Surface {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: "person.crop.circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("云端账号").font(.headline).foregroundStyle(Palette.ink)
                                Text("跨设备保留自己的记录").font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                        if model.cloudServerConfigured {
                            NavigationLink(model.isCloudMode && model.cloudServerSelected && model.session != nil ? "查看云端账号" : "登录或注册云端账号") {
                                CloudAccountView()
                            }.frame(minHeight: 44, alignment: .leading)
                            HintLabel(text: "基础记录与同步可继续使用，AI 识图由云端账号的 SVIP 权益控制。")
                        } else {
                            Text("当前版本尚未启用官方云服务，可以先离线记录或连接已有的私有服务器。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !model.isCloudMode {
                    Surface {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: "externaldrive")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("连接你的后台").font(.headline).foregroundStyle(Palette.ink)
                                Text("用于同步记录与伙伴共享").font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                        FormField(title: "后台地址") {
                            TextField("http://192.168.50.186:18080", text: $model.serverURL)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Button("测试并保存地址") {
                            let context = model.localDataContext
                            checking = true
                            Task {
                                defer { if context == model.localDataContext { checking = false } }
                                do {
                                    guard context == model.localDataContext else { return }
                                    try await model.checkConnection()
                                } catch { if context == model.localDataContext { message = error.localizedDescription } }
                            }
                        }.buttonStyle(SoftActionStyle()).disabled(checking || model.serverURL.isEmpty)
                        if checking { ProgressView() }
                        NavigationLink("登录或创建后台账号") { ConnectionSettingsView() }.frame(minHeight: 44, alignment: .leading)
                        NavigationLink("使用部署者的配对信息") { ServerPairingView() }.frame(minHeight: 44, alignment: .leading)
                        HintLabel(text: "支持 HTTP 和 HTTPS，保存后自动复用。HTTP 明文传输，建议仅在可信局域网使用。")
                    }
                    }
                    if model.canUseAI {
                        Surface {
                            HStack(spacing: 12) {
                                SymbolBadge(symbol: "sparkles", color: Palette.purple)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("让记录轻松一点").font(.headline).foregroundStyle(Palette.ink)
                                    Text(model.isCloudMode ? "云端模型与照片处理授权" : "配置 AI 接口与模型")
                                        .font(.caption).foregroundStyle(Palette.secondary)
                                }
                            }
                            if model.isCloudMode {
                                Text(model.cloudAI.text("provider_name", fallback: "云端餐食识别"))
                                    .font(.subheadline)
                                NavigationLink("核对云端 AI 与照片授权") { AIConnectionEditorView() }
                                    .frame(minHeight: 44, alignment: .leading)
                                HintLabel(text: "仅在你同意处理照片后使用云端识别，也可以随时手动记录。")
                            } else {
                                if model.aiConfiguration.configured {
                                    Text(model.aiConfiguration.model).font(.subheadline)
                                    Text(model.aiConfiguration.baseUrl).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("支持 Responses API 风格的接口，可读取模型列表或手动填写模型。")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                NavigationLink("设置 AI 地址、密钥和模型") { AIConnectionEditorView() }
                                    .frame(minHeight: 44, alignment: .leading)
                                HintLabel(text: "也可以先使用本机识别或手动记录，之后再配置 AI。")
                            }
                        }
                    }
                }.padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    Button(checking ? "正在保存…" : "完成设置") {
                        Task { await finish(offline: false) }
                    }.buttonStyle(FilledActionStyle()).disabled(checking)
                    Button("暂不连接，开始记录") {
                        Task { await finish(offline: true) }
                    }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).disabled(checking)
                }.padding(.horizontal, 20).padding(.top, 12).background(Palette.canvas)
            }
            .background(Palette.canvas).navigationTitle("连接服务").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("上一步", action: onBack).disabled(checking) } }
        }
        .onChange(of: model.localDataContext) { _, _ in checking = false; message = nil }
        .alert("连接尚未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
    private func finish(offline: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do { try await onFinish(offline) }
        catch { message = error.localizedDescription }
    }

}
