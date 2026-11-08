import SwiftUI
import UIKit

@main
@MainActor
struct BingJianApp: App {
    @UIApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.health)
                .environmentObject(model.reminders)
                .tint(Palette.teal)
                .overlay {
                    if scenePhase != .active {
                        ZStack {
                            Palette.canvas.ignoresSafeArea()
                            Text("并肩").font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.teal)
                        }
                    }
                }
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.enteredForeground() }
                }
                .onOpenURL { url in
                    if url.scheme == "bingjian", url.host == "join",
                       let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value {
                        UserDefaults.standard.set(code, forKey: "pending_invite")
                        model.notice = "邀请码已读取，请到伙伴页面加入"
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = "today"
    var body: some View {
        Group {
            if !model.hasLoadedRecords { ProgressView("正在载入记录…") }
            else if !model.setupCompleted || !model.profileSetupCompleted { OnboardingView() }
            else { MainTabs(selection: $selectedTab) }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice).font(.subheadline).padding(16).background(.regularMaterial, in: Capsule())
                    .padding().onTapGesture { model.notice = nil }
                    .task(id: notice) { try? await Task.sleep(for: .seconds(5)); model.notice = nil }
            }
        }
    }

}

struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String

    var body: some View {
        // iOS 17 的 TabView 会在重新选中时恢复系统底栏；这里仅保留自定义菜单。
        VStack(spacing: 0) {
            PersistentTabHost(selection: selection) { tab in
                NavigationStack { page(tab) }
                    .environmentObject(model).environmentObject(model.health).environmentObject(model.reminders)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            AppTabBar(selection: $selection)
        }
        .toolbarBackground(Palette.canvas, for: .navigationBar)
    }

    @ViewBuilder
    private func page(_ tab: String) -> some View {
        switch tab {
        case "meals": MealsView()
        case "trends": TrendsView()
        case "community": CommunityView()
        case "settings": SettingsView()
        default: DashboardView()
        }
    }
}

// 只替换标签页容器，原有 SwiftUI 页面与导航栈保持不变。
struct PersistentTabHost<Content: View>: UIViewControllerRepresentable {
    let selection: String
    let content: (String) -> Content

    init(selection: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.selection = selection
        self.content = content
    }

    func makeUIViewController(context: Context) -> PersistentTabController {
        PersistentTabController()
    }

    func updateUIViewController(_ controller: PersistentTabController, context: Context) {
        // 继承外部的语言、字号、颜色与其他环境设置，截图和实际页面采用相同配置。
        let root = AnyView(content(selection).environment(\.self, context.environment))
        controller.select(selection, rootView: root)
    }
}

@MainActor
final class PersistentTabController: UIViewController {
    private var pages: [String: UIHostingController<AnyView>] = [:]
    private var activePage: UIHostingController<AnyView>?
    private var visible = false

    // 手动转发生命周期：切走时取消页面任务，重新进入时恢复刷新，缓存本身保留导航状态。
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activePage?.beginAppearanceTransition(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activePage?.endAppearanceTransition()
        visible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        activePage?.beginAppearanceTransition(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        activePage?.endAppearanceTransition()
    }

    func select(_ key: String, rootView: AnyView) {
        let next: UIHostingController<AnyView>
        if let cached = pages[key] {
            next = cached
            next.rootView = rootView
        } else {
            next = UIHostingController(rootView: rootView)
            next.view.backgroundColor = .clear
            pages[key] = next
        }
        guard next !== activePage else { return }
        loadViewIfNeeded()
        let previous = activePage
        previous?.willMove(toParent: nil)
        addChild(next)
        if visible {
            previous?.beginAppearanceTransition(false, animated: false)
            next.beginAppearanceTransition(true, animated: false)
        }
        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        activePage = next
        if visible {
            previous?.endAppearanceTransition()
            next.endAppearanceTransition()
        }
    }
}

struct AppTabBar: View {
    @Binding var selection: String
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 23
    private let items = [("today", "今天", "sun.max.fill"), ("meals", "饮食", "fork.knife"),
                         ("trends", "趋势", "chart.xyaxis.line"), ("community", "伙伴", "person.2.fill"),
                         ("settings", "我的", "person.crop.circle.fill")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    VStack(spacing: 5) {
                        // 菜单需要同时容纳五个入口，限制图标与短标签放大，正文仍完整支持辅助功能字号。
                        Image(systemName: item.2).font(.system(size: min(iconSize, 28), weight: .medium))
                        Text(item.1).font(.caption2.weight(selection == item.0 ? .semibold : .regular))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge).lineLimit(1).minimumScaleFactor(0.8)
                    }.padding(.horizontal, 13).padding(.vertical, 8)
                        .foregroundStyle(selection == item.0 ? Palette.teal : Palette.secondary)
                        .background(selection == item.0 ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(.plain).accessibilityLabel(item.1)
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                    .accessibilityIdentifier("tab.\(item.0)")
            }
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            .background { Palette.card.ignoresSafeArea(edges: .bottom) }
            .overlay(alignment: .top) { Rectangle().fill(Palette.border.opacity(0.65)).frame(height: 0.5) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("navigation.bottom")
    }
}
