import SwiftUI
import HealthKit
import UIKit
import XCTest
@testable import BingJian

final class AppearanceTests: XCTestCase {
    @MainActor
    func testMainPagesInLightDarkAndLargeType() async throws {
        let previousNamespace = UserDefaults.standard.string(forKey: "local_namespace")
        let previousWeightUnit = UserDefaults.standard.string(forKey: AppModel.weightUnitPreferenceKey)
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: "local_namespace")
        defer {
            UserDefaults.standard.set(previousNamespace, forKey: "local_namespace")
            UserDefaults.standard.set(previousWeightUnit, forKey: AppModel.weightUnitPreferenceKey)
        }
        let model = AppModel()
        model.setupCompleted = true
        model.syncEnabled = false
        model.healthEnabled = false
        try await seedRecords(model)

        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for tab in ["today", "meals", "trends", "community", "settings"] {
                try await capture(MainTabs(selection: .constant(tab)), model: model,
                                  name: "\(tab)-\(mode)", dark: dark)
            }
            try await capture(OnboardingView(), model: model, name: "welcome-\(mode)", dark: dark)
            // 二级页面与主页面一起验收，避免表单、邀请页在深色下出现样式断层。
            try await capture(NavigationStack { ProfileEditorView() }, model: model, name: "profile-\(mode)", dark: dark)
            try await capture(NavigationStack { AIConnectionEditorView() }, model: model, name: "ai-connection-\(mode)", dark: dark)
            try await capture(NavigationStack { ConnectionSettingsView() }, model: model, name: "server-account-\(mode)", dark: dark)
            try await capture(NavigationStack { CreateChallengeView() }, model: model, name: "challenge-create-\(mode)", dark: dark)
            try await capture(NavigationStack { InvitationView(code: "preview-invitation") }, model: model, name: "invitation-\(mode)", dark: dark)
            try await capture(NavigationStack { ReminderSettingsView() }, model: model, name: "reminders-\(mode)", dark: dark)
        }
        for tab in ["today", "meals", "trends", "settings"] {
            try await capture(MainTabs(selection: .constant(tab)), model: model,
                              name: "\(tab)-large-text", largeText: true)
        }
        try await capture(OnboardingView(), model: model, name: "welcome-large-text", largeText: true)
        try await capture(MainTabs(selection: .constant("today")), model: model,
                          name: "today-small-screen", compact: true)
        for unit in [WeightUnit.kg, .jin] {
            model.setWeightUnit(unit)
            try await capture(NavigationStack { WeightEditorView() }, model: model, name: "weight-entry-\(unit.rawValue)")
            try await capture(NavigationStack { WeightHistoryView() }, model: model, name: "weight-history-\(unit.rawValue)")
        }
        try await capture(MainTabs(selection: .constant("settings")), model: model, name: "settings-jin-large-text", largeText: true)
        let accountExamples = [
            ("account-short-password", AccountInput(username: "abc", password: "abc", displayName: "abc")),
            ("account-multiple-errors", AccountInput(username: "ab", password: "abc", displayName: ""))
        ]
        for (name, input) in accountExamples {
            try await capture(NavigationStack {
                AppForm {
                    Section("创建新账号") {
                        AccountFieldsView(username: .constant(input.username), password: .constant(input.password),
                                          displayName: .constant(input.displayName),
                                          registration: true, errors: input.validationErrors(registration: true))
                    }
                }.navigationTitle("服务器与账号")
            }, model: model, name: name)
        }
        try await capture(NavigationStack { MealEditorView(initialMealType: "lunch") }, model: model, name: "meal-photo-entry")
        let manual = try AppRecord(kind: "meal", day: model.day,
            value: MealEntry(status: "confirmed", items: [try MealInput.calorieItem(650)]))
        try await capture(NavigationStack { MealEditorView(existing: manual) }, model: model, name: "meal-manual-calories")
        let photoMeal = try AppRecord(kind: "meal", day: model.day, value: MealEntry(items: [
            FoodItem(name: "米饭", amount: 150, basisKcal: 116, basisProteinG: 2.6, basisCarbsG: 25.9, basisFatG: 0.3, source: "ai_estimate"),
            FoodItem(name: "鸡胸肉", amount: 120, basisKcal: 165, basisProteinG: 31, basisCarbsG: 0, basisFatG: 3.6, source: "ai_estimate")]))
        try await capture(NavigationStack { MealEditorView(existing: photoMeal) }, model: model, name: "meal-nutrition-summary")
        try await capture(OnboardingView(initialStep: 1), model: model, name: "welcome-activity")
        try await capture(OnboardingView(initialStep: 2), model: model, name: "welcome-connections")
        try await capture(OnboardingView(), model: model, name: "welcome-small-screen", compact: true)
        try await capture(NavigationStack { AIConnectionEditorView() }, model: model, name: "ai-connection-large-text", largeText: true)
        try await capture(NavigationStack { ConnectionSettingsView() }, model: model, name: "server-account-large-text", largeText: true)
        try await capture(NavigationStack { InvitationView(code: "preview-invitation") }, model: model, name: "invitation-small-screen", compact: true)
        _ = model.health.reportFailure(NSError(domain: HKErrorDomain, code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Missing com.apple.developer.healthkit entitlement."]))
        try await capture(NavigationStack { HealthSettingsView() }, model: model, name: "health-signing-help")
    }

    @MainActor
    private func seedRecords(_ model: AppModel) async throws {
        // 示例只写入测试专用命名空间，便于检查真实记录在页面中的排版。
        let day = model.day
        let profile = BodyProfile(displayName: "小满", age: 30, sexForFormula: "female", heightCm: 165)
        try await model.saveRecord(AppRecord(kind: "profile", day: day, value: profile))
        for offset in 0..<14 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            let weight = WeightEntry(measuredAt: TimeFormat.iso(date), weightKg: 62.4 + Double(offset) * 0.08)
            try await model.saveRecord(AppRecord(kind: "weight", day: TimeFormat.day(date), value: weight))
        }
        let breakfast = FoodItem(name: "燕麦酸奶碗", basisKcal: 360, basisProteinG: 18, basisCarbsG: 48, basisFatG: 11)
        let lunch = FoodItem(name: "鸡肉杂粮饭", basisKcal: 620, basisProteinG: 36, basisCarbsG: 78, basisFatG: 18)
        try await model.saveRecord(AppRecord(kind: "meal", day: day,
            value: MealEntry(mealType: "breakfast", status: "confirmed", items: [breakfast])))
        try await model.saveRecord(AppRecord(kind: "meal", day: day,
            value: MealEntry(mealType: "lunch", status: "confirmed", items: [lunch])))
        let window = try XCTUnwrap(TimeFormat.window(day, timezone: model.profile.timezone))
        let health = HealthDay(windowStart: TimeFormat.iso(window.start), windowEnd: TimeFormat.iso(window.end),
                               steps: 6240, activeKcal: 286)
        try await model.saveRecord(AppRecord(kind: "health_day", day: day, value: health))
        XCTAssertEqual(model.meals.count, 2)
        XCTAssertEqual(model.summary.intake, 980)
    }

    @MainActor
    private func capture<Content: View>(_ content: Content, model: AppModel, name: String,
                                       dark: Bool = false, largeText: Bool = false, compact: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        if compact { window.frame = CGRect(x: 0, y: 0, width: 375, height: 667) }
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: content
            .environmentObject(model).environmentObject(model.health).environmentObject(model.reminders)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            .preferredColorScheme(dark ? .dark : .light)
            .tint(Palette.teal))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        // 等待 SwiftUI 布局、原生导航栏和异步趋势计算完成后采集。
        try await Task.sleep(for: .seconds(2))
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 10_000, "页面截图应包含实际内容")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StyleReview", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
