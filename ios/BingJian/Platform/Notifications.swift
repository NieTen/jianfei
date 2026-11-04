import Foundation
import UserNotifications
import UIKit

@MainActor
final class ReminderManager: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "reminders_enabled")
    @Published var weightHour = UserDefaults.standard.object(forKey: "weight_hour") as? Int ?? 8
    @Published var mealHour = UserDefaults.standard.object(forKey: "meal_hour") as? Int ?? 20
    @Published var challengeHour = UserDefaults.standard.object(forKey: "challenge_hour") as? Int ?? 21

    func save() async throws {
        let center = UNUserNotificationCenter.current()
        if enabled {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { throw APIError(code: "NOTIFICATION_PERMISSION", message: "通知权限尚未开启，可在系统设置中调整") }
        }
        center.removePendingNotificationRequests(withIdentifiers: ["daily_weight", "daily_meal", "daily_challenge"])
        if enabled {
            for (id, hour, title, body) in [
                ("daily_weight", weightHour, "留下一次身体记录", "有空时记录今天的体重，慢慢观察趋势"),
                ("daily_meal", mealHour, "今天吃了什么", "补齐今天的饮食记录，再确认完整度"),
                ("daily_challenge", challengeHour, "和伙伴一起记录", "看看今日打卡，也可以送出一句鼓励")
            ] {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour), repeats: true)
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
        UserDefaults.standard.set(enabled, forKey: "reminders_enabled")
        UserDefaults.standard.set(weightHour, forKey: "weight_hour")
        UserDefaults.standard.set(mealHour, forKey: "meal_hour")
        UserDefaults.standard.set(challengeHour, forKey: "challenge_hour")
    }

    func enableRemote() async throws {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw APIError(code: "NOTIFICATION_PERMISSION", message: "请在系统设置中允许通知")
        }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    static var pushTokenHandler: ((String) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundCoordinator.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.pushTokenHandler?(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "push_registration_error")
    }
}
