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

    func testBackendAddressAcceptsExplicitHTTPAndDefaultsToHTTPS() throws {
        XCTAssertEqual(try ServerAddress.normalize(" http://192.168.50.186:18080/api/v1/ ").absoluteString,
                       "http://192.168.50.186:18080")
        XCTAssertEqual(try ServerAddress.normalize("HTTP://nas.local:18080/").absoluteString, "http://nas.local:18080")
        XCTAssertEqual(try ServerAddress.normalize("nas.local:8443").absoluteString, "https://nas.local:8443")
        XCTAssertThrowsError(try ServerAddress.normalize("ftp://nas.local"))
        XCTAssertThrowsError(try ServerAddress.normalize("http://user:password@nas.local"))
        XCTAssertThrowsError(try ServerAddress.normalize("http://nas.local?key=test"))
    }

    func testHTTPPairingDoesNotClaimCertificateVerification() throws {
        let value = ServerPairing(kind: "bingjian_server", version: 1, url: "http://nas.local:18080",
                                  instanceId: UUID().uuidString, caSha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try ServerPairing.parse(Codec.json(value)))
    }

    @MainActor
    func testHTTPConnectionAndSavedAddressSurviveReload() async throws {
        let server = try LocalHTTPTestServer()
        defer { server.stop() }
        let port = try await server.start()
        let address = "http://127.0.0.1:\(port)"
        let defaults = UserDefaults.standard
        let previousAddress = defaults.string(forKey: "server_url")
        let previousSession = KeychainStore.read("active_session")
        defer {
            defaults.set(previousAddress, forKey: "server_url")
            if let previousSession {
                try? KeychainStore.save(previousSession, key: "active_session")
            } else {
                KeychainStore.delete("active_session")
            }
        }
        let model = AppModel()
        model.serverURL = address + "/api/v1/"
        try await model.checkConnection()
        XCTAssertEqual(model.notice, "HTTP 连接成功")
        XCTAssertEqual(defaults.string(forKey: "server_url"), address)
        let reloaded = AppModel()
        XCTAssertEqual(reloaded.serverURL, address)
        try await reloaded.checkConnection()
        XCTAssertEqual(reloaded.notice, "HTTP 连接成功")
        let policy = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertEqual(policy?["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNil(policy?["NSAllowsLocalNetworking"])
    }

    @MainActor
    func testOfficialCloudAddressMigrationClearsSessionAndKeepsLocalRecords() async throws {
        let configurationRequested = expectation(description: "新服务只接收匿名部署配置请求")
        configurationRequested.assertForOverFulfill = true
        let server = try LocalHTTPTestServer(handler: { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/app/config")
            XCTAssertNil(request.headers["authorization"], "不得向新服务转发旧服务器令牌")
            XCTAssertTrue(request.body.isEmpty)
            configurationRequested.fulfill()
            return LocalHTTPResponse(status: 200, body: Data("{\"deployment_mode\":\"cloud\"}".utf8))
        })
        defer { server.stop() }
        let port = try await server.start()
        let address = "http://127.0.0.1:\(port)"
        let defaults = UserDefaults.standard
        let namespace = "cloud-migration-test-" + UUID().uuidString.lowercased()
        let binding = "fixture-instance-" + namespace + ":fixture-user"
        let keys = ["local_namespace", "anonymous_namespace", "setup_completed", "sync_enabled", "health_enabled",
                    "server_url", "device_id", AppModel.weightUnitPreferenceKey,
                    "server_deployment:" + address, "namespace:" + binding,
                    "body_setup_completed:" + namespace, "external_ai_consent:" + namespace]
        let previous = keys.map { defaults.object(forKey: $0) }
        let previousSession = KeychainStore.read("active_session")
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            if let previousSession {
                XCTAssertNoThrow(try KeychainStore.save(previousSession, key: "active_session"))
            } else {
                KeychainStore.delete("active_session")
            }
        }
        defaults.set(namespace, forKey: "local_namespace")
        defaults.set(namespace + "-anonymous", forKey: "anonymous_namespace")
        defaults.set(namespace, forKey: "namespace:" + binding)
        defaults.set("https://old.example.invalid", forKey: "server_url")
        defaults.set(false, forKey: "sync_enabled")
        defaults.set(false, forKey: "health_enabled")
        defaults.set(false, forKey: "setup_completed")
        let oldSession = SessionCredentials(accessToken: "fixture-old-access", refreshToken: "fixture-old-refresh",
            expiresIn: 3600, userId: "fixture-user", displayName: "测试账号", deviceId: "fixture-device",
            generation: 1, epoch: "fixture-epoch", instanceId: "fixture-instance-" + namespace)
        try KeychainStore.save(Codec.encoder().encode(oldSession), key: "active_session")

        // 注入本机测试服务，不连接构建配置中的真实云端；HTTP 策略是否允许不影响地址迁移断言。
        let model = AppModel(cloudServerURL: try XCTUnwrap(URL(string: address)))
        let initialSession = await model.api.currentSession()
        XCTAssertEqual(initialSession?.accessToken, oldSession.accessToken)
        let input = OnboardingInput(age: 30, heightCm: 175, weight: 70, unit: .kg, sex: "male")
        let profileId = UUID().uuidString.lowercased(), weightId = UUID().uuidString.lowercased()
        try await model.finishOnboarding(input, profileId: profileId, weightId: weightId, offline: true)
        let originalStore = try model.requireStore()
        try await originalStore.setMetadata("bound_user", value: binding)

        await model.start()
        await fulfillment(of: [configurationRequested], timeout: 5)
        XCTAssertEqual(defaults.string(forKey: "server_url"), address)
        XCTAssertEqual(model.serverURL, address)
        XCTAssertNil(model.session)
        let migratedSession = await model.api.currentSession()
        XCTAssertNil(migratedSession)
        XCTAssertNil(KeychainStore.read("active_session"))
        XCTAssertEqual(defaults.string(forKey: "local_namespace"), namespace)
        XCTAssertEqual(defaults.string(forKey: "namespace:" + binding), namespace)
        XCTAssertEqual(Set(model.records.map(\.id)), Set([profileId, weightId]))
        XCTAssertEqual(model.profile.age, 30)
        XCTAssertEqual(model.summary.weight, 70)
        XCTAssertTrue(model.profileSetupCompleted)
        XCTAssertTrue(model.setupCompleted)
        let currentStore = try model.requireStore()
        XCTAssertTrue(currentStore === originalStore)
        let retainedBinding = try await currentStore.metadata("bound_user")
        XCTAssertEqual(retainedBinding, binding)
        let retainedRecords = try await currentStore.allRecords()
        XCTAssertEqual(Set(retainedRecords.map(\.id)), Set([profileId, weightId]))
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
