import SwiftUI
import UIKit
import XCTest
@testable import BingJian

final class AppearanceTests: XCTestCase {
    @MainActor
    func testMainPagesInLightDarkAndLargeType() async throws {
        let previousNamespace = UserDefaults.standard.string(forKey: "local_namespace")
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: "local_namespace")
        defer { UserDefaults.standard.set(previousNamespace, forKey: "local_namespace") }
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
        }
        try await capture(MainTabs(selection: .constant("today")), model: model,
                          name: "today-large-text", largeText: true)
        try await capture(MainTabs(selection: .constant("settings")), model: model,
                          name: "settings-large-text", largeText: true)
        try await capture(MainTabs(selection: .constant("today")), model: model,
                          name: "today-small-screen", compact: true)
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
