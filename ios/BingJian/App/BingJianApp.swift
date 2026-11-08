import SwiftUI

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
    @Binding var selection: String
    var body: some View {
        // 菜单独占布局空间，避免 TabView 内部容器忽略外层安全区后遮住滚动内容。
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                NavigationStack { DashboardView() }.toolbar(.hidden, for: .tabBar).tabItem { Label("今天", systemImage: "sun.max") }.tag("today")
                NavigationStack { MealsView() }.toolbar(.hidden, for: .tabBar).tabItem { Label("饮食", systemImage: "fork.knife") }.tag("meals")
                NavigationStack { TrendsView() }.toolbar(.hidden, for: .tabBar).tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }.tag("trends")
                NavigationStack { CommunityView() }.toolbar(.hidden, for: .tabBar).tabItem { Label("伙伴", systemImage: "person.2") }.tag("community")
                NavigationStack { SettingsView() }.toolbar(.hidden, for: .tabBar).tabItem { Label("我的", systemImage: "person.crop.circle") }.tag("settings")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            AppTabBar(selection: $selection)
        }
        .toolbarBackground(Palette.canvas, for: .navigationBar)
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
    }
}
