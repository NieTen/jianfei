import XCTest
@testable import BingJian

final class AICredentialReuseTests: XCTestCase {
    @MainActor
    private func isolated(_ operation: (AppModel, AIHTTPStub) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "local_namespace")
        let namespace = "test-ai-reuse-" + UUID().uuidString.lowercased()
        defaults.set(namespace, forKey: "local_namespace")
        let stub = AIHTTPStub()
        let session = stub.session()
        defer {
            session.invalidateAndCancel()
            AIStubURLProtocol.unregister(stub)
            KeychainStore.delete("ai_key:" + namespace)
            for prefix in ["ai_configuration:", "ai_configuration_pending:", "ai_clear_key:", "external_ai_consent:", "ai_models:", "ai_server_key:"] {
                defaults.removeObject(forKey: prefix + namespace)
            }
            defaults.set(previous, forKey: "local_namespace")
        }
        let model = AppModel(responses: ResponsesClient(session: session))
        var configuration = AIConfiguration()
        configuration.baseUrl = "https://" + stub.host + "/v1"
        configuration.model = "original-model"
        configuration.execution = "direct"
        try await model.saveAIConfiguration(configuration, apiKey: "saved-test-key")
        try await operation(model, stub)
    }

    @MainActor
    func testModelChangeKeepsLocalKeyEvenWhenServerAlsoHasKey() async throws {
        try await isolated { model, _ in
            model.aiHasServerKey = true
            var edited = model.aiConfiguration
            edited.model = "new-model"
            edited.baseUrl += "/responses/"
            try await model.saveAIConfiguration(edited, apiKey: "")
            XCTAssertEqual(model.aiAPIKey(), "saved-test-key")
            XCTAssertEqual(model.aiConfiguration.model, "new-model")
            XCTAssertTrue(model.hasSavedAIKey(for: edited))
            XCTAssertEqual(AppModel().aiAPIKey(), "saved-test-key")
        }
    }

    @MainActor
    func testModelListAndConnectionTestUseSavedKeyWithEmptyEditor() async throws {
        try await isolated { model, stub in
            stub.reset([["data": .array([.object(["id": .string("new-model")])])]])
            var edited = model.aiConfiguration
            edited.model = "new-model"
            let models = try await model.loadAIModels(configuration: edited, apiKey: "")
            XCTAssertEqual(models.map(\.id), ["new-model"])
            let message = try await model.testAI(configuration: edited, apiKey: "   ")
            XCTAssertTrue(message.contains("连接成功"))
            XCTAssertEqual(stub.requests.count, 2)
            XCTAssertTrue(stub.requests.allSatisfy { $0.authorization == "Bearer saved-test-key" && $0.url?.path == "/v1/models" })
        }
    }

    @MainActor
    func testReplacementKeyIsUsedAndBlankSaveDoesNotEraseIt() async throws {
        try await isolated { model, stub in
            stub.reset([["data": .array([])]])
            _ = try await model.loadAIModels(configuration: model.aiConfiguration, apiKey: "replacement-test-key")
            XCTAssertEqual(stub.requests.first?.authorization, "Bearer replacement-test-key")
            XCTAssertEqual(model.aiAPIKey(), "saved-test-key", "直连测试不应提前覆盖已保存密钥")
            try await model.saveAIConfiguration(model.aiConfiguration, apiKey: "replacement-test-key")
            try await model.saveAIConfiguration(model.aiConfiguration, apiKey: "")
            XCTAssertEqual(model.aiAPIKey(), "replacement-test-key")
        }
    }

    @MainActor
    func testDifferentEndpointDoesNotReceiveSavedKey() async throws {
        try await isolated { model, stub in
            var edited = model.aiConfiguration
            edited.baseUrl = "https://another-provider.invalid/v1"
            XCTAssertFalse(model.hasSavedAIKey(for: edited))
            do {
                _ = try await model.loadAIModels(configuration: edited, apiKey: "")
                XCTFail("更换接口时不能发送原接口密钥")
            } catch { XCTAssertEqual((error as? APIError)?.code, "AI_KEY_REQUIRED") }
            XCTAssertTrue(stub.requests.isEmpty)
            XCTAssertEqual(model.aiAPIKey(), "saved-test-key")
        }
    }

    @MainActor
    func testServerOnlyKeyCanBePreservedWithoutInventingLocalKey() async throws {
        try await isolated { model, _ in
            try await model.saveAIConfiguration(model.aiConfiguration, apiKey: "", clearKey: true)
            model.aiHasServerKey = true
            var edited = model.aiConfiguration
            edited.execution = "gateway"
            edited.model = "gateway-model"
            try await model.saveAIConfiguration(edited, apiKey: "")
            XCTAssertTrue(model.hasSavedAIKey(for: edited))
            XCTAssertEqual(model.aiAPIKey(), "")
            edited.execution = "direct"
            XCTAssertThrowsError(try model.aiRequestKey(configuration: edited, enteredKey: "")) {
                XCTAssertEqual(($0 as? APIError)?.code, "AI_LOCAL_KEY_REQUIRED")
            }
        }
    }
}
