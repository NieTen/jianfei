import XCTest
@testable import BingJian

final class ConfigurationAndValidationTests: XCTestCase {
    func testServerPairingRoundTrip() throws {
        let original = ServerPairing(kind: "bingjian_server", version: 1, url: "https://example.com",
                                     instanceId: UUID().uuidString.lowercased(), caSha256: String(repeating: "a", count: 64))
        let parsed = try ServerPairing.parse(Codec.json(original))
        XCTAssertEqual(parsed.instanceId, original.instanceId)
        XCTAssertEqual(parsed.pinKey, "server_ca_pin:example.com:443")
        XCTAssertThrowsError(try ServerPairing.parse("{}"))
    }

    func testAIAddressAcceptsResponsesEndpoint() throws {
        XCTAssertEqual(try AIAddress.normalize("https://example.com/v1/responses/").absoluteString, "https://example.com/v1")
        XCTAssertEqual(try AIAddress.normalize("example.com").absoluteString, "https://example.com/v1")
        XCTAssertThrowsError(try AIAddress.normalize("http://example.com/v1"))
        XCTAssertThrowsError(try AIAddress.normalize("https://user:secret@example.com/v1"))
    }

    func testBackendAddressNormalizesAPISuffix() throws {
        XCTAssertEqual(try ServerAddress.normalize("https://example.com/api/v1/").absoluteString, "https://example.com")
    }

    func testAISettingsRoundTrip() throws {
        var value = AIConfiguration()
        value.model = "test-vision"
        value.execution = "direct"
        value.maxOutputTokens = 8192
        XCTAssertEqual(try Codec.decoder().decode(AIConfiguration.self, from: Codec.encoder().encode(value)), value)
    }

    func testKeychainCreatesUpdatesAndDeletesCredentials() throws {
        let key = "test_keychain:" + UUID().uuidString
        defer { KeychainStore.delete(key) }
        XCTAssertNil(KeychainStore.read(key))
        try KeychainStore.save(Data("first-test-value".utf8), key: key)
        XCTAssertEqual(KeychainStore.read(key), Data("first-test-value".utf8))
        try KeychainStore.save(Data("replacement-test-value".utf8), key: key)
        XCTAssertEqual(KeychainStore.read(key), Data("replacement-test-value".utf8))
        KeychainStore.delete(key)
        XCTAssertNil(KeychainStore.read(key))
    }

    @MainActor
    func testDirectAISettingsAndKeySurviveModelReload() async throws {
        let defaults = UserDefaults.standard
        let previousNamespace = defaults.string(forKey: "local_namespace")
        let namespace = "test-ai-credentials-" + UUID().uuidString.lowercased()
        defaults.set(namespace, forKey: "local_namespace")
        defer {
            KeychainStore.delete("ai_key:" + namespace)
            for prefix in ["ai_configuration:", "ai_configuration_pending:", "ai_clear_key:", "external_ai_consent:"] {
                defaults.removeObject(forKey: prefix + namespace)
            }
            defaults.set(previousNamespace, forKey: "local_namespace")
        }
        // 使用虚构密钥调用与设置页相同的保存入口，不连接外部服务。
        var value = AIConfiguration()
        value.execution = "direct"
        value.baseUrl = "https://example.com/v1/responses"
        value.model = "test-vision"
        let model = AppModel()
        try await model.saveAIConfiguration(value, apiKey: "ci-not-a-real-api-key")
        let reloaded = AppModel()
        XCTAssertEqual(reloaded.aiConfiguration.baseUrl, "https://example.com/v1")
        XCTAssertEqual(reloaded.aiConfiguration.model, "test-vision")
        XCTAssertEqual(reloaded.aiConfiguration.execution, "direct")
        XCTAssertEqual(reloaded.aiAPIKey(), "ci-not-a-real-api-key")
        XCTAssertFalse(reloaded.aiConfigurationPending)

        value.model = "test-vision-updated"
        try await reloaded.saveAIConfiguration(value, apiKey: "")
        XCTAssertEqual(AppModel().aiAPIKey(), "ci-not-a-real-api-key")
        try await reloaded.saveAIConfiguration(value, apiKey: "ci-replacement-key")
        XCTAssertEqual(AppModel().aiAPIKey(), "ci-replacement-key")
    }

    func testUnknownPortionRequiresConfirmation() throws {
        var food = FoodItem(name: "待确认食物")
        food.requiresPortion = true
        let meal = MealEntry(status: "confirmed", items: [food])
        let record = try AppRecord(kind: "meal", day: "2026-11-03", value: meal)
        XCTAssertThrowsError(try RecordValidator.validate(record))
    }

    func testNegativeNutrientsAreRejected() {
        let food = FoodItem(name: "食物", basisKcal: -1)
        XCTAssertThrowsError(try RecordValidator.food(food))
    }

    func testNewestDayTakesPriorityOverOlderRepresentative() throws {
        let older = try AppRecord(kind: "weight", day: "2026-11-01",
            value: WeightEntry(measuredAt: "2026-11-01T08:00:00Z", weightKg: 75, representative: true))
        let newer = try AppRecord(kind: "weight", day: "2026-11-02",
            value: WeightEntry(measuredAt: "2026-11-02T08:00:00Z", weightKg: 74))
        let index = RecordIndex(records: [older, newer])
        XCTAssertEqual(EnergyCalculator.weight(index.forSummary(day: "2026-11-03"), day: "2026-11-03"), 74)
    }

    func testWeightTimeComparisonUsesActualInstant() throws {
        let early = try AppRecord(kind: "weight", day: "2026-11-03",
            value: WeightEntry(measuredAt: "2026-11-03T11:00:00+08:00", weightKg: 75))
        let later = try AppRecord(kind: "weight", day: "2026-11-03",
            value: WeightEntry(measuredAt: "2026-11-03T08:00:00Z", weightKg: 74))
        XCTAssertEqual(EnergyCalculator.weight([early, later], day: "2026-11-03"), 74)
    }
}
