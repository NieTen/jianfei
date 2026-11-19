import Foundation
import XCTest
@testable import BingJian

/// URLSession仍走真实APIClient；仅此测试显式注入协议，所有响应均为合成夹具。
private final class CloudModelHTTPFixture: @unchecked Sendable {
    let host = "cloud-model-" + UUID().uuidString.lowercased() + ".invalid"
    let instance = "fixture-" + UUID().uuidString.lowercased()
    private let lock = NSLock()
    private var user = "basic"
    private var svip = false
    private var consent = true
    private var revision = 1
    private var failedRights = false
    private var failedRevocation = false
    private var paths: [String] = []
    var url: URL { URL(string: "https://" + host)! }

    func setSVIP(_ allowed: Bool) { lock.lock(); svip = allowed; lock.unlock() }
    func failRights(_ failed: Bool) { lock.lock(); failedRights = failed; lock.unlock() }
    func failRevocation(_ failed: Bool) { lock.lock(); failedRevocation = failed; lock.unlock() }
    func requestedPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }

    func response(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        paths.append(path)
        let body = (try? JSONDecoder().decode(JSONObject.self, from: bodyData(request))) ?? [:]
        func result(_ value: JSONValue, status: Int = 200) -> (Int, Data) {
            (status, (try? JSONEncoder().encode(value)) ?? Data())
        }
        func failure(_ code: String) -> (Int, Data) {
            result(.object(["code": .string(code), "message": .string("测试服务暂不可用")]), status: 503)
        }
        switch path {
        case "/api/v1/health": return result(.object(["fixture": .bool(true)]))
        case "/api/v1/app/config": return result(.object(["deployment_mode": .string("cloud")]))
        case "/api/v1/auth/login":
            let name = body.text("username")
            user = name.hasPrefix("svip") ? "svip" : name.hasPrefix("second") ? "second" : "basic"
            svip = user == "svip"
            let credentials = SessionCredentials(accessToken: "fixture-access-" + user, refreshToken: "fixture-refresh-" + user,
                expiresIn: 3600, userId: user, displayName: "合成测试账号", deviceId: body.text("device_id"),
                generation: 1, epoch: "fixture-epoch", instanceId: instance)
            return (200, (try? Codec.encoder().encode(credentials)) ?? Data())
        case "/api/v1/identity/bind", "/api/v1/auth/logout": return result(.object([:]))
        case "/api/v1/capabilities":
            return result(.object(["instance_id": .string(instance), "deployment_mode": .string("cloud"), "epoch": .string("fixture-epoch")]))
        case "/api/v1/challenges": return result(.array([]))
        case "/api/v1/me": return result(.object(["id": .string(user), "email": .string(user + "@example.invalid")]))
        case "/api/v1/me/entitlements":
            if failedRights { return failure("TEMPORARY") }
            return result(.object(["tier": .string(svip ? "svip" : "basic"), "ai_food_recognition": .bool(svip),
                "server_time": .string(TimeFormat.iso()), "valid_until": .string(TimeFormat.iso(Date().addingTimeInterval(3600)))]))
        case "/api/v1/me/ai-consent":
            if request.httpMethod == "PUT" {
                if !body.flag("allowed"), failedRevocation { return failure("TEMPORARY") }
                consent = body.flag("allowed"); revision += 1
            }
            return result(.object(["allowed": .bool(consent), "revision": .number(Double(revision)), "provider_revision": .number(1)]))
        case "/api/v1/me/ai-preferences":
            guard svip else { return failure("UNEXPECTED_BASIC_AI_REQUEST") }
            return result(.object(["model_id": .string("fixture-model"), "provider_revision": .number(1),
                "provider_name": .string("合成模型"), "models": .array([.object(["id": .string("fixture-model"), "name": .string("合成模型")])])]))
        default: return failure("UNEXPECTED_TEST_REQUEST")
        }
    }

    private func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 1024 * 1024 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class CloudModelTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: CloudModelHTTPFixture] = [:]
    static func install(_ fixture: CloudModelHTTPFixture) { lock.lock(); fixtures[fixture.host] = fixture; lock.unlock() }
    static func remove(_ fixture: CloudModelHTTPFixture) { lock.lock(); fixtures[fixture.host] = nil; lock.unlock() }
    private static func fixture(_ request: URLRequest) -> CloudModelHTTPFixture? {
        lock.lock(); defer { lock.unlock() }; return fixtures[request.url?.host ?? ""]
    }
    override class func canInit(with request: URLRequest) -> Bool { fixture(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let (status, data) = fixture.response(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CloudModelIntegrationTests: XCTestCase {
    func testExplicitSessionInjectionUsesOnlySyntheticResponses() async throws {
        let fixture = CloudModelHTTPFixture()
        CloudModelTestProtocol.install(fixture)
        defer { CloudModelTestProtocol.remove(fixture) }
        let name = "cloud-protocol-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(fixture.url.absoluteString, forKey: "server_url")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudModelTestProtocol.self]
        let api = APIClient(defaults: defaults, persistCredentials: false, sessionConfiguration: configuration)
        let result = try await api.send("health", authenticated: false)
        XCTAssertTrue(result.object?.flag("fixture") == true)
        XCTAssertEqual(fixture.requestedPaths(), ["/api/v1/health"])
    }

    #if os(iOS)
    @MainActor
    func testActualModelClosesBasicAndFailedEntitlementsAndIsolatesAccounts() async throws {
        try await withModel { model, fixture, _ in
            try await model.authenticateCloud(email: "basic@example.invalid", password: "fixture-password", displayName: "", emailCode: "", register: false, mergeLocal: false, acceptedRulesVersion: nil)
            XCTAssertTrue(model.cloudReady)
            XCTAssertEqual(model.session?.userId, "basic")
            XCTAssertFalse(model.canUseAI)
            XCTAssertFalse(fixture.requestedPaths().contains("/api/v1/me/ai-preferences"))
            let meal = try AppRecord(kind: "meal", day: TimeFormat.day(), value: MealEntry(photoIds: [UUID().uuidString.lowercased()]))
            for mode in ["device", "server"] {
                model.aiMode = mode; model.aiConfiguration.execution = "direct"
                do { _ = try await model.recognize(record: meal); XCTFail("普通账号不得进入任何AI实现") }
                catch { XCTAssertEqual((error as? APIError)?.code, "SVIP_REQUIRED") }
            }
            try await model.recordWeight(70, unit: .kg, measuredAt: Date(), note: "基础账号可记录", representative: false)
            let originalIds = Set(model.records.map(\.id))
            let originalStore = try model.requireStore()
            fixture.setSVIP(true)
            await model.refreshCloudAccount()
            XCTAssertTrue(model.canUseAI)
            XCTAssertEqual(model.cloudAI.text("model_id"), "fixture-model")
            fixture.failRights(true)
            await model.refreshCloudAccount()
            XCTAssertFalse(model.canUseAI, "刷新失败不能继续复用旧权益")
            fixture.failRights(false)
            await model.refreshCloudAccount()
            XCTAssertTrue(model.canUseAI)
            let oldContext = model.localDataContext
            try await model.authenticateCloud(email: "second@example.invalid", password: "fixture-password", displayName: "", emailCode: "", register: false, mergeLocal: false, acceptedRulesVersion: nil)
            XCTAssertNotEqual(model.localDataContext, oldContext)
            XCTAssertFalse(model.canUseAI)
            XCTAssertTrue(model.records.isEmpty)
            let retained = try await originalStore.allRecords()
            XCTAssertEqual(Set(retained.map(\.id)), originalIds)
            XCTAssertFalse(fixture.requestedPaths().contains { $0.contains("food-recognition") || $0.contains("upload-init") })
        }
    }

    @MainActor
    func testActualModelRetainsOfflineRevocationAfterRecreationUntilServerConfirmation() async throws {
        try await withModel { model, fixture, api in
            try await model.authenticateCloud(email: "svip@example.invalid", password: "fixture-password", displayName: "", emailCode: "", register: false, mergeLocal: false, acceptedRulesVersion: nil)
            XCTAssertTrue(model.canUseAI)
            XCTAssertTrue(model.cloudConsent.flag("allowed"))
            fixture.failRevocation(true)
            do { try await model.setCloudAIConsent(false); XCTFail("模拟离线撤回不能被当成服务端已确认") }
            catch { XCTAssertEqual((error as? APIError)?.code, "TEMPORARY") }
            XCTAssertTrue(model.cloudAIRevocationPending)
            XCTAssertFalse(model.canUseAI)
            let reopened = AppModel(cloudServerURL: fixture.url, api: api)
            reopened.session = await api.currentSession()
            await reopened.refreshCloudAccount()
            XCTAssertTrue(reopened.cloudAIRevocationPending)
            XCTAssertFalse(reopened.canUseAI)
            XCTAssertFalse(reopened.cloudConsent.flag("allowed"))
            fixture.failRevocation(false)
            await reopened.refreshCloudAccount()
            XCTAssertFalse(reopened.cloudAIRevocationPending)
            XCTAssertFalse(reopened.cloudConsent.flag("allowed"))
            XCTAssertTrue(reopened.canUseAI, "SVIP资格仍在，但照片处理授权需要用户重新同意")
        }
    }

    @MainActor
    private func withModel(_ action: (AppModel, CloudModelHTTPFixture, APIClient) async throws -> Void) async throws {
        let fixture = CloudModelHTTPFixture(), defaults = UserDefaults.standard
        let namespace = "cloud-model-test-" + UUID().uuidString.lowercased()
        let users = ["basic", "svip", "second"]
        let scopes = users.map { CloudAIRevocationStore.scope(server: fixture.url.absoluteString, instance: fixture.instance, user: $0) }
        let keys = ["local_namespace", "anonymous_namespace", "server_url", "sync_enabled", "health_enabled", "setup_completed", "device_id", "last_username", "ai_mode", AppModel.weightUnitPreferenceKey,
                    "server_deployment:" + fixture.url.absoluteString]
            + users.map { "namespace:" + fixture.instance + ":" + $0 }
            + users.map { "device:" + fixture.url.absoluteString + ":" + $0 + "@example.invalid" } + scopes
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            CloudModelTestProtocol.remove(fixture)
        }
        defaults.set(namespace, forKey: "local_namespace")
        defaults.set(namespace + "-anonymous", forKey: "anonymous_namespace")
        defaults.set(fixture.url.absoluteString, forKey: "server_url")
        defaults.set(false, forKey: "sync_enabled"); defaults.set(false, forKey: "health_enabled")
        defaults.set(true, forKey: "setup_completed")
        for user in users {
            let target = namespace + "-" + user
            defaults.set(target, forKey: "namespace:" + fixture.instance + ":" + user)
            try await LocalDatabase(namespace: target).setMetadata("automatic_backup", value: "off")
        }
        CloudModelTestProtocol.install(fixture)
        let suite = "cloud-model-api-" + UUID().uuidString
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { isolated.removePersistentDomain(forName: suite) }
        isolated.set(fixture.url.absoluteString, forKey: "server_url")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudModelTestProtocol.self]
        let api = APIClient(defaults: isolated, persistCredentials: false, sessionConfiguration: configuration)
        let model = AppModel(cloudServerURL: fixture.url, api: api)
        try await model.requireStore().setMetadata("automatic_backup", value: "off")
        try await action(model, fixture, api)
    }
    #endif
}
