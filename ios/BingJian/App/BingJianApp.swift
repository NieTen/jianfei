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
    var body: some View {
        Group {
            if !model.setupCompleted { OnboardingView() }
            else { tabs }
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

    private var tabs: some View {
        TabView {
            NavigationStack { DashboardView() }.tabItem { Label("今天", systemImage: "sun.max") }
            NavigationStack { MealsView() }.tabItem { Label("饮食", systemImage: "fork.knife") }
            NavigationStack { TrendsView() }.tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }
            NavigationStack { CommunityView() }.tabItem { Label("伙伴", systemImage: "person.2") }
            NavigationStack { SettingsView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
    }
}
