import BackgroundTasks
import Foundation

@MainActor
enum BackgroundCoordinator {
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.bingjian.health") + ".refresh"
    static var onRefresh: (() async -> Bool)?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let operation = Task { @MainActor in
                schedule()
                let success = await onRefresh?() ?? false
                task.setTaskCompleted(success: success && !Task.isCancelled)
            }
            task.expirationHandler = { operation.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
