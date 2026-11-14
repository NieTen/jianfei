import XCTest
@testable import BingJian

final class CloudAccessTests: XCTestCase {
    func testOfficialServerKeepsHTTPSValidationAndRejectsCredentials() {
        XCTAssertNil(CloudDeployment.validatedURL("http://cloud.example.test"))
        XCTAssertNil(CloudDeployment.validatedURL("https://user:password@cloud.example.test"))
        XCTAssertNil(CloudDeployment.validatedURL("https://cloud.example.test?api_key=value"))
        XCTAssertNil(CloudDeployment.validatedURL("https://cloud.example.test#fragment"))
        XCTAssertEqual(CloudDeployment.validatedURL("https://cloud.example.test/api/v1")?.absoluteString, "https://cloud.example.test")
    }

    func testOfficialServerAllowsOnlyTheSpecifiedLocalHTTPRoot() {
        for address in ["http://192.168.50.229:8000", " HTTP://192.168.50.229:8000/api/v1/ "] {
            XCTAssertEqual(CloudDeployment.validatedURL(address), CloudDeployment.localHTTPServerURL)
        }
        for address in [
            "http://192.168.50.229", "http://192.168.50.229:8001",
            "http://192.168.50.228:8000", "http://192.168.50.229.evil.test:8000",
            "http://192.168.50.229:8000/other", "http://127.0.0.1:8000", "http://10.0.0.1:8000",
            "http://user:password@192.168.50.229:8000", "http://192.168.50.229:8000?api_key=value",
            "http://192.168.50.229:8000#fragment", ""
        ] {
            XCTAssertNil(CloudDeployment.validatedURL(address), "不应接受未明确允许的云地址：\(address)")
        }
    }

    func testEntitlementLeaseUsesServerRemainingTimeAndFailsClosed() {
        let active: JSONObject = ["ai_food_recognition": .bool(true),
            "server_time": .string("2026-11-13T00:00:00+00:00"), "valid_until": .string("2026-11-14T00:00:00+00:00")]
        XCTAssertEqual(CloudEntitlementLease.duration(active), 300)
        var short = active
        short["valid_until"] = .string("2026-11-13T00:00:10+00:00")
        XCTAssertEqual(CloudEntitlementLease.duration(short), 10)
        short["valid_until"] = .string("2026-11-12T00:00:00+00:00")
        XCTAssertEqual(CloudEntitlementLease.duration(short), 0)
        short["valid_until"] = .null
        XCTAssertEqual(CloudEntitlementLease.duration(short), 0)
        short = active
        short["ai_food_recognition"] = .bool(false)
        XCTAssertEqual(CloudEntitlementLease.duration(short), 0)
        XCTAssertEqual(CloudEntitlementLease.duration([:]), 0)
    }

    #if os(iOS)
    @MainActor
    func testCloudCannotUseDeviceDirectOrSavedProviderWithoutEntitlement() async throws {
        let defaults = UserDefaults.standard
        let keys = ["local_namespace", "anonymous_namespace", "server_url", "sync_enabled", "health_enabled", "ai_mode", AppModel.weightUnitPreferenceKey]
        let previousSession = KeychainStore.read("active_session")
        let prior = keys.map { defaults.object(forKey: $0) }
        let namespace = "cloud-access-test-" + UUID().uuidString.lowercased()
        defaults.set(namespace, forKey: "local_namespace")
        defaults.set(namespace + "-anonymous", forKey: "anonymous_namespace")
        KeychainStore.delete("active_session")
        defaults.removeObject(forKey: "server_url")
        defaults.set(false, forKey: "sync_enabled")
        defaults.set(false, forKey: "health_enabled")
        defer {
            for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) }
            if let previousSession { try? KeychainStore.save(previousSession, key: "active_session") }
            else { KeychainStore.delete("active_session") }
        }
        let model = AppModel(cloudServerURL: URL(string: "https://cloud.example.test")!)
        XCTAssertTrue(model.isCloudMode)
        XCTAssertFalse(model.canUseAI)
        let record = try AppRecord(kind: "meal", day: "2026-11-13",
                                   value: MealEntry(photoIds: [UUID().uuidString.lowercased()]))
        for mode in ["device", "server"] {
            model.aiMode = mode
            model.aiConfiguration.execution = "direct"
            model.aiConfiguration.allowOutsideLan = true
            do {
                _ = try await model.recognize(record: record)
                XCTFail("云端账号没有权益时不应进入任何识别分支")
            } catch let error as APIError { XCTAssertEqual(error.code, "SVIP_REQUIRED") }
        }
        do {
            _ = try await model.loadAIModels(configuration: model.aiConfiguration, apiKey: "test-key")
            XCTFail("云端不应执行用户自定义接口请求")
        } catch let error as APIError { XCTAssertEqual(error.code, "CLOUD_AI_MANAGED") }
        try await model.recordWeight(70, unit: .kg, measuredAt: Date(), note: "基础记录", representative: false)
        let stored = try await model.requireStore().allRecords()
        XCTAssertEqual(stored.filter { $0.kind == "weight" }.count, 1)
        let original = model.localDataContext
        await model.logout()
        XCTAssertNotEqual(model.localDataContext, original)
        XCTAssertThrowsError(try model.checkLocalContext(original))
        XCTAssertFalse(model.canUseAI)
    }
    #endif
}
