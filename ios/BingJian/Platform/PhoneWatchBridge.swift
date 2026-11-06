import Foundation
import WatchConnectivity

@MainActor
final class PhoneWatchBridge: NSObject {
    var onRecord: (([String: Any]) async throws -> Void)?
    private var pendingContext: [String: Any]?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ values: [String: Any]) {
        pendingContext = values
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(values)
    }

    private func accept(_ payload: [String: Any]) async throws {
        guard let onRecord else { throw APIError(code: "PHONE_NOT_READY", message: "请先打开手机应用") }
        try await onRecord(payload)
        if let id = payload["id"] as? String { WCSession.default.transferUserInfo(["ack": id]) }
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let values = self.pendingContext { self.update(values) }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            do { try await self.accept(userInfo) }
            catch { session.transferUserInfo(["record_error": error.localizedDescription, "id": userInfo["id"] as? String ?? ""]) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                try await self.accept(message)
                replyHandler(["saved": true, "id": message["id"] as? String ?? ""])
            } catch { replyHandler(["saved": false, "error": error.localizedDescription]) }
        }
    }
}
