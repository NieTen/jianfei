import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity

struct WatchEntry: Codable, Identifiable {
    var id: String
    var kind: String
    var value: Double
    var name: String
    var timestamp: String
    var ownerId: String
}

@MainActor
final class WatchModel: NSObject, ObservableObject {
    @Published var entries: [WatchEntry] = []
    @Published var summary: [String: String] = [:]
    @Published var steps: Double?
    @Published var message = ""
    @Published var reachable = false
    @Published var ownerId = ""
    private let healthStore = HKHealthStore()
    private let queueURL: URL

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queueURL = root.appendingPathComponent("pending-records.json")
        super.init()
        if let data = try? Data(contentsOf: queueURL), let entries = try? JSONDecoder().decode([WatchEntry].self, from: data) { self.entries = entries }
        ownerId = UserDefaults.standard.string(forKey: "phone_owner") ?? ""
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func save(kind: String, value: Double, name: String = "") throws {
        guard value.isFinite, kind == "weight" ? value > 0 && value <= 600 : value >= 0 && value <= 100000 else {
            throw NSError(domain: "并肩", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效数值"])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entries.append(WatchEntry(id: UUID().uuidString.lowercased(), kind: kind, value: value, name: name,
                                  timestamp: formatter.string(from: Date()), ownerId: ownerId))
        try persist()
        message = "已保存在手表"
        flush()
    }

    func associateUnbound() throws {
        guard !ownerId.isEmpty else { return }
        for index in entries.indices where entries[index].ownerId.isEmpty { entries[index].ownerId = ownerId }
        try persist()
        flush()
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func acknowledge(_ id: String) {
        entries.removeAll { $0.id == id }
        do { try persist(); message = "已交给手机保存" }
        catch { message = "本地回执保存失败，下次会安全重试" }
    }

    func flush() {
        guard WCSession.default.activationState == .activated else { return }
        reachable = WCSession.default.isReachable
        for entry in entries where !entry.ownerId.isEmpty && entry.ownerId == ownerId {
            let payload: [String: Any] = ["id": entry.id, "kind": entry.kind, "value": entry.value,
                                          "name": entry.name, "timestamp": entry.timestamp, "owner_id": entry.ownerId]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(payload, replyHandler: { response in
                    Task { @MainActor in
                        if response["saved"] as? Bool == true { self.acknowledge(entry.id) }
                        else { self.message = response["error"] as? String ?? "等待手机确认" }
                    }
                }, errorHandler: { _ in WCSession.default.transferUserInfo(payload) })
            } else {
                let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains { ($0.userInfo["id"] as? String) == entry.id }
                if !alreadyQueued { WCSession.default.transferUserInfo(payload) }
            }
        }
    }

    func authorizeHealth() async {
        do {
            guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }
            try await healthStore.requestAuthorization(toShare: [], read: [type])
            await refreshSteps()
        } catch { message = error.localizedDescription }
    }

    func refreshSteps() async {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let query = HKStatisticsQuery(quantityType: type,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
            options: .cumulativeSum) { _, result, _ in
                Task { @MainActor in self.steps = result?.sumQuantity()?.doubleValue(for: .count()) }
            }
        healthStore.execute(query)
    }

    private func receiveContext(_ context: [String: Any]) {
        if let id = context["owner_id"] as? String {
            ownerId = id
            UserDefaults.standard.set(id, forKey: "phone_owner")
        }
        summary = context.compactMapValues {
            if let text = $0 as? String { return text }
            if let value = $0 as? Double { return value.formatted(.number.precision(.fractionLength(0...1))) }
            return nil
        }
        flush()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.receiveContext(session.receivedApplicationContext) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.flush() } }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receiveContext(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            if let id = userInfo["ack"] as? String { self.acknowledge(id) }
            if let error = userInfo["record_error"] as? String { self.message = error }
        }
    }
}
