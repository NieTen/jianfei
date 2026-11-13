import Foundation
import XCTest
@testable import BingJian

private actor APITestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct APITestObservedRequest: Sendable {
    var server: String
    var request: LocalHTTPRequest
}

private actor APITestRequestLog {
    private var values: [APITestObservedRequest] = []
    func record(_ request: LocalHTTPRequest, server: String = "original") {
        values.append(APITestObservedRequest(server: server, request: request))
    }
    func matching(_ path: String, server: String? = nil) -> [LocalHTTPRequest] {
        values.filter { $0.request.path == path && (server == nil || $0.server == server) }.map(\.request)
    }
}

/// 所有会话仅驻内存，偏好使用随机独立 suite；绝不读取、备份或清除用户的 active_session。
private final class APISessionFixture {
    let client: APIClient
    private let defaults: UserDefaults
    private let suiteName = "api-session-tests-" + UUID().uuidString.lowercased()

    init(address: String) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(address, forKey: "server_url")
        client = APIClient(defaults: defaults, persistCredentials: false)
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }
}

final class APIClientSessionTests: XCTestCase {
    func testDefaultHTTPServerStillServesExistingStaticResponses() async throws {
        let server = try LocalHTTPTestServer()
        defer { server.stop() }
        let port = try await server.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let response = try await fixture.client.send("health", authenticated: false)
        XCTAssertEqual(response.object?.text("status"), "ok")
    }

    func testOldRequestContextCannotSendToANewAccountOrAddress() async throws {
        let log = APITestRequestLog()
        let server = try LocalHTTPTestServer(handler: { request in
            await log.record(request)
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        let destination = try LocalHTTPTestServer(handler: { request in
            await log.record(request, server: "destination")
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        defer { server.stop(); destination.stop() }
        let port = try await server.start(), destinationPort = try await destination.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let client = fixture.client
        try await client.setSession(credentials(user: "a", access: "access-a", refresh: "refresh-a"))
        let originalContext = await client.requestContext()
        try await client.setSession(credentials(user: "b", access: "access-b", refresh: "refresh-b"))
        let staleSend = Task { try await client.send("protected", expectedContext: originalContext) }
        assertDiscarded(await staleSend.result)
        let beforeAddressChange = await log.matching("/api/v1/protected")
        XCTAssertTrue(beforeAddressChange.isEmpty, "直接setSession切换身份后，旧流程也必须在构造新账号请求之前被拒绝")

        let beforeClearContext = await client.requestContext()
        await client.clearSession()
        try await client.setSession(credentials(user: "b", access: "access-b", refresh: "refresh-b"))
        let staleAfterClear = Task { try await client.send("protected", expectedContext: beforeClearContext) }
        assertDiscarded(await staleAfterClear.result)

        let previousAddressContext = await client.requestContext()
        try await client.configure("http://127.0.0.1:\(destinationPort)")
        try await client.setSession(credentials(user: "b", access: "access-b", refresh: "refresh-b"))
        let staleUpload = Task { try await client.request("protected", method: "POST", data: Data("old-photo-chunk".utf8),
                                                          expectedContext: previousAddressContext) }
        assertDiscarded(await staleUpload.result)
        let beforeNewRequest = await log.matching("/api/v1/protected")
        XCTAssertTrue(beforeNewRequest.isEmpty, "地址改变后，旧上传流程不得向新服务发送任何字节")
        let currentContext = await client.requestContext()
        let response = try await client.send("protected", expectedContext: currentContext)
        XCTAssertEqual(response.object?.text("owner"), "b")
        let currentRequests = await log.matching("/api/v1/protected", server: "destination")
        XCTAssertEqual(currentRequests.count, 1)
        XCTAssertEqual(currentRequests.first?.headers["authorization"], "Bearer access-b")
    }

    func testSessionIdentityFieldsInvalidateOldContextButTokenRotationDoesNot() async throws {
        let log = APITestRequestLog()
        let server = try LocalHTTPTestServer(handler: { request in
            await log.record(request)
            return LocalHTTPResponse(status: 200, body: Data("{\"status\":\"ok\"}".utf8))
        })
        defer { server.stop() }
        let port = try await server.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let client = fixture.client
        let baseline = credentials(user: "a", access: "access-a", refresh: "refresh-a")
        for field in ["user", "instance", "device", "generation"] {
            try await client.setSession(baseline)
            let oldContext = await client.requestContext()
            var changed = baseline
            switch field {
            case "user": changed.userId = "another-user"
            case "instance": changed.instanceId = "another-instance"
            case "device": changed.deviceId = "another-device"
            default: changed.generation += 1
            }
            try await client.setSession(changed)
            let stale = Task { try await client.send("protected", expectedContext: oldContext) }
            assertDiscarded(await stale.result)
        }
        let unexpected = await log.matching("/api/v1/protected")
        XCTAssertTrue(unexpected.isEmpty, "任一身份维度变化都必须在网络请求前拒绝旧上下文")
        try await client.setSession(baseline)
        let sameIdentityContext = await client.requestContext()
        var rotated = baseline
        rotated.accessToken = "rotated-access"
        rotated.refreshToken = "rotated-refresh"
        try await client.setSession(rotated)
        let response = try await client.send("protected", expectedContext: sameIdentityContext)
        XCTAssertEqual(response.object?.text("status"), "ok")
        let accepted = await log.matching("/api/v1/protected")
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.headers["authorization"], "Bearer rotated-access")
    }

    func testConcurrentUnauthorizedRequestsShareOneRefreshAndRetryWithRotatedToken() async throws {
        let count = 4
        let receivedOldRequests = expectation(description: "并发旧令牌请求全部到达真实服务")
        receivedOldRequests.expectedFulfillmentCount = count
        let receivedRefresh = expectation(description: "收到刷新请求")
        let requestGate = APITestGate(), refreshGate = APITestGate(), log = APITestRequestLog()
        let original = credentials(user: "a", access: "access-a-old", refresh: "refresh-a")
        let rotated = credentials(user: "a", access: "access-a-new", refresh: "refresh-a-rotated")
        let rotatedData = try Codec.encoder().encode(rotated)
        let server = try LocalHTTPTestServer(handler: { request in
            await log.record(request)
            if request.path == "/api/v1/auth/refresh" {
                receivedRefresh.fulfill()
                await refreshGate.wait()
                return LocalHTTPResponse(status: 200, body: rotatedData)
            }
            if request.headers["authorization"] == "Bearer access-a-old" {
                receivedOldRequests.fulfill()
                await requestGate.wait()
                return LocalHTTPResponse(status: 401, body: Data("{\"code\":\"AUTH_EXPIRED\",\"message\":\"测试令牌已过期\"}".utf8))
            }
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"a\"}".utf8))
        })
        defer {
            server.stop()
            Task { await requestGate.release(); await refreshGate.release() }
        }
        let port = try await server.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let client = fixture.client
        try await client.setSession(original)
        let originalContext = await client.requestContext()
        let requests = (0..<count).map { _ in Task { try await client.send("protected", expectedContext: originalContext) } }
        await fulfillment(of: [receivedOldRequests], timeout: 5)
        await requestGate.release()
        await fulfillment(of: [receivedRefresh], timeout: 5)
        await refreshGate.release()
        for request in requests {
            let response = try await request.value
            XCTAssertEqual(response.object?.text("owner"), "a")
        }
        let refreshes = await log.matching("/api/v1/auth/refresh")
        let protected = await log.matching("/api/v1/protected")
        XCTAssertEqual(refreshes.count, 1, "四个并发401必须共用一次令牌轮换")
        let body = try JSONDecoder().decode(JSONObject.self, from: try XCTUnwrap(refreshes.first?.body))
        XCTAssertEqual(body.text("refresh_token"), "refresh-a")
        XCTAssertEqual(protected.filter { $0.headers["authorization"] == "Bearer access-a-old" }.count, count)
        XCTAssertEqual(protected.filter { $0.headers["authorization"] == "Bearer access-a-new" }.count, count)
        let current = await client.currentSession()
        XCTAssertEqual(current?.accessToken, rotated.accessToken)
        XCTAssertEqual(current?.refreshToken, rotated.refreshToken)
    }

    func testClearSessionDuringRefreshDoesNotRetryUsingTheNextAccount() async throws {
        try await verifyRefreshInterruption(changeServer: false)
    }

    func testConfigureDuringRefreshDoesNotRetryAtTheNewAddress() async throws {
        try await verifyRefreshInterruption(changeServer: true)
    }

    func testClearSessionDuringLoginDiscardsTheOldLoginResponse() async throws {
        try await verifyLoginInterruption(changeServer: false)
    }

    func testConfigureDuringLoginDiscardsTheOldLoginResponse() async throws {
        try await verifyLoginInterruption(changeServer: true)
    }

    private func verifyRefreshInterruption(changeServer: Bool) async throws {
        let receivedRefresh = expectation(description: "刷新请求已进入等待")
        let gate = APITestGate(), log = APITestRequestLog()
        let original = credentials(user: "a", access: "access-a-old", refresh: "refresh-a")
        let oldReply = try Codec.encoder().encode(credentials(user: "a", access: "access-a-late", refresh: "refresh-a-late"))
        let next = credentials(user: "b", access: "access-b", refresh: "refresh-b")
        let server = try LocalHTTPTestServer(handler: { request in
            await log.record(request)
            if request.path == "/api/v1/auth/refresh" {
                receivedRefresh.fulfill()
                await gate.wait()
                return LocalHTTPResponse(status: 200, body: oldReply)
            }
            if request.headers["authorization"] == "Bearer access-a-old" {
                return LocalHTTPResponse(status: 401, body: Data("{\"code\":\"AUTH_EXPIRED\",\"message\":\"测试过期\"}".utf8))
            }
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        let destination = try LocalHTTPTestServer(handler: { request in
            await log.record(request, server: "destination")
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        defer { server.stop(); destination.stop(); Task { await gate.release() } }
        let port = try await server.start(), destinationPort = try await destination.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let client = fixture.client
        try await client.setSession(original)
        let oldRequest = Task { try await client.send("protected") }
        await fulfillment(of: [receivedRefresh], timeout: 5)
        if changeServer { try await client.configure("http://127.0.0.1:\(destinationPort)") }
        else { await client.clearSession() }
        try await client.setSession(next)
        await gate.release()
        assertDiscarded(await oldRequest.result)
        let beforeNewRequest = await log.matching("/api/v1/protected")
        XCTAssertEqual(beforeNewRequest.count, 1, "旧调用不能以B账号重试，也不能发送到新地址")
        XCTAssertEqual(beforeNewRequest.first?.headers["authorization"], "Bearer access-a-old")
        let current = await client.currentSession()
        XCTAssertEqual(current?.userId, "b")
        XCTAssertEqual(current?.accessToken, "access-b", "迟到的刷新响应不能覆盖新账号凭据")
        let refreshes = await log.matching("/api/v1/auth/refresh")
        XCTAssertEqual(refreshes.count, 1)
        let newResponse = try await client.send("protected")
        XCTAssertEqual(newResponse.object?.text("owner"), "b")
        let newRequests = await log.matching("/api/v1/protected", server: changeServer ? "destination" : "original")
        XCTAssertEqual(newRequests.filter { $0.headers["authorization"] == "Bearer access-b" }.count, 1,
                       "新账号仅接收随后显式发起的新调用")
    }

    private func verifyLoginInterruption(changeServer: Bool) async throws {
        let receivedLogin = expectation(description: "登录请求已进入等待")
        let gate = APITestGate(), log = APITestRequestLog()
        let oldReply = try Codec.encoder().encode(credentials(user: "a", access: "access-a-late", refresh: "refresh-a-late"))
        let next = credentials(user: "b", access: "access-b", refresh: "refresh-b")
        let server = try LocalHTTPTestServer(handler: { request in
            await log.record(request)
            if request.path == "/api/v1/auth/login" {
                receivedLogin.fulfill()
                await gate.wait()
                return LocalHTTPResponse(status: 200, body: oldReply)
            }
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        let destination = try LocalHTTPTestServer(handler: { request in
            await log.record(request, server: "destination")
            return LocalHTTPResponse(status: 200, body: Data("{\"owner\":\"b\"}".utf8))
        })
        defer { server.stop(); destination.stop(); Task { await gate.release() } }
        let port = try await server.start(), destinationPort = try await destination.start()
        let fixture = try APISessionFixture(address: "http://127.0.0.1:\(port)")
        let client = fixture.client
        let oldLogin = Task { try await client.login(username: "fixture_user_a", password: "fixture-password", deviceId: "fixture-device", name: "测试设备") }
        await fulfillment(of: [receivedLogin], timeout: 5)
        if changeServer { try await client.configure("http://127.0.0.1:\(destinationPort)") }
        else { await client.clearSession() }
        try await client.setSession(next)
        await gate.release()
        assertDiscarded(await oldLogin.result)
        let current = await client.currentSession()
        XCTAssertEqual(current?.userId, "b")
        XCTAssertEqual(current?.accessToken, "access-b", "迟到的登录响应不能覆盖新账号")
        let logins = await log.matching("/api/v1/auth/login")
        XCTAssertEqual(logins.count, 1)
        let unexpected = await log.matching("/api/v1/protected")
        XCTAssertTrue(unexpected.isEmpty)
        let response = try await client.send("protected")
        XCTAssertEqual(response.object?.text("owner"), "b")
        let destinationRequests = await log.matching("/api/v1/protected", server: changeServer ? "destination" : "original")
        XCTAssertEqual(destinationRequests.count, 1)
        XCTAssertEqual(destinationRequests.first?.headers["authorization"], "Bearer access-b")
    }

    private func credentials(user: String, access: String, refresh: String) -> SessionCredentials {
        SessionCredentials(accessToken: access, refreshToken: refresh, expiresIn: 3600, userId: user,
                           displayName: "测试账号", deviceId: "fixture-device-" + user, generation: 1,
                           epoch: "fixture-epoch", instanceId: "fixture-instance")
    }

    private func assertDiscarded<Value>(_ result: Result<Value, Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("旧会话调用必须丢弃，不能在新身份下完成", file: file, line: line)
        case .failure(let error):
            if let api = error as? APIError { XCTAssertEqual(api.code, "SESSION_CHANGED", file: file, line: line) }
            else { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled,
                                 "应为会话变化或取消，实际：\(error)", file: file, line: line) }
        }
    }
}
