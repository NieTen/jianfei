import Foundation

actor APIClient {
    private var baseURL: URL?
    private var credentials: SessionCredentials?
    private var refreshTask: Task<SessionCredentials, Error>?
    private let session: URLSession
    private let defaults: UserDefaults
    private let persistCredentials: Bool
    private var contextVersion = UUID()

    /// 默认沿用持久化会话；测试或临时客户端可显式使用独立偏好与纯内存凭据。
    init(defaults: UserDefaults = .standard, persistCredentials: Bool = true) {
        self.defaults = defaults
        self.persistCredentials = persistCredentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 240
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        if let value = defaults.string(forKey: "server_url") { baseURL = URL(string: value) }
        if persistCredentials, let data = KeychainStore.read("active_session") {
            credentials = try? Codec.decoder().decode(SessionCredentials.self, from: data)
        }
    }

    func configure(_ url: String) throws {
        let parsed = try ServerAddress.normalize(url)
        if parsed != baseURL {
            clearSession()
        }
        baseURL = parsed
        defaults.set(parsed.absoluteString, forKey: "server_url")
    }

    func currentSession() -> SessionCredentials? { credentials }
    func requestContext() -> UUID { contextVersion }

    func setSession(_ value: SessionCredentials) throws {
        if let baseURL, let expected = defaults.string(forKey: "server_expected_instance:" + baseURL.absoluteString),
           expected != value.instanceId {
            throw APIError(code: "SERVER_IDENTITY", message: "服务器身份与已核对的配对信息不一致")
        }
        if let previous = credentials,
           previous.userId != value.userId || previous.instanceId != value.instanceId
            || previous.deviceId != value.deviceId || previous.generation != value.generation {
            clearSession()
        }
        if persistCredentials { try KeychainStore.save(Codec.encoder().encode(value), key: "active_session") }
        credentials = value
    }

    func clearSession() {
        contextVersion = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        if persistCredentials { KeychainStore.delete("active_session") }
    }

    private func endpoint(_ path: String, query: [String: String]) throws -> URL {
        guard let baseURL else { throw APIError(code: "NO_SERVER", message: "请先配置私有服务器") }
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = baseURL.appendingPathComponent("api/v1").appendingPathComponent(clean)
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            throw APIError(code: "SERVER_URL", message: "服务地址无效")
        }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw APIError(code: "SERVER_URL", message: "服务地址无效") }
        return url
    }

    func send(_ path: String, method: String = "GET", body: JSONObject? = nil, query: [String: String] = [:],
              authenticated: Bool = true, expectedContext: UUID? = nil) async throws -> JSONValue {
        let data = try body.map { try JSONEncoder().encode($0) }
        let result = try await request(path, method: method, data: data, query: query,
                                       contentType: "application/json", authenticated: authenticated, expectedContext: expectedContext)
        return result.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: result)
    }

    func request(_ path: String, method: String = "GET", data: Data? = nil, query: [String: String] = [:],
                 contentType: String = "application/json", authenticated: Bool = true, mayRefresh: Bool = true,
                 extraHeaders: [String: String] = [:], expectedContext: UUID? = nil) async throws -> Data {
        try Task.checkCancellation()
        // 多步骤操作携带首次捕获的身份；在同一 actor 内核对后才构造地址与认证头。
        guard expectedContext == nil || expectedContext == contextVersion else {
            throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新操作")
        }
        let context = contextVersion
        var request = URLRequest(url: try endpoint(path, query: query))
        request.httpMethod = method
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if authenticated {
            guard let credentials else { throw APIError(code: "AUTH_REQUIRED", message: "请先登录私有服务器") }
            request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        }
        let (responseData, response) = try await session.data(for: request)
        guard context == contextVersion else { throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新操作") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw APIError(code: "NETWORK", message: "服务器响应无效", retryable: true) }
        if http.statusCode == 401 && authenticated && mayRefresh {
            // 并发请求的旧令牌可能在另一个请求刷新后才返回401，直接重试新令牌。
            if request.value(forHTTPHeaderField: "Authorization") == credentials.map({ "Bearer " + $0.accessToken }) {
                try await renewSession()
            }
            guard context == contextVersion else { throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新操作") }
            try Task.checkCancellation()
            return try await self.request(path, method: method, data: data, query: query, contentType: contentType,
                                          authenticated: true, mayRefresh: false, extraHeaders: extraHeaders,
                                          expectedContext: expectedContext ?? context)
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONDecoder().decode(JSONObject.self, from: responseData)) ?? [:]
            throw APIError.response(status: http.statusCode, object: object)
        }
        return responseData
    }

    private func renewSession() async throws {
        let context = contextVersion
        if let refreshTask {
            let value = try await refreshTask.value
            guard context == contextVersion else { throw CancellationError() }
            try setSession(value)
            return
        }
        guard let credentials else { throw APIError(code: "AUTH_REQUIRED", message: "请重新登录") }
        let task = Task<SessionCredentials, Error> {
            let response = try await self.send("auth/refresh", method: "POST",
                body: ["refresh_token": .string(credentials.refreshToken)], authenticated: false, expectedContext: context)
            guard let object = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "登录响应无效") }
            return try Codec.decode(SessionCredentials.self, from: object)
        }
        refreshTask = task
        defer { if context == contextVersion { refreshTask = nil } }
        let value = try await task.value
        guard context == contextVersion else { throw CancellationError() }
        try setSession(value)
    }

    func login(username: String, password: String, deviceId: String, name: String) async throws -> SessionCredentials {
        let input = try AccountInput(username: username, password: password).validated(registration: false)
        clearSession()
        let context = contextVersion
        let response = try await send("auth/login", method: "POST",
            body: ["username": .string(input.username), "password": .string(input.password),
                   "device_id": .string(deviceId), "device_name": .string(name)], authenticated: false, expectedContext: context)
        guard let value = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "登录响应无效") }
        let credentials = try Codec.decode(SessionCredentials.self, from: value)
        guard context == contextVersion else { throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新登录") }
        try setSession(credentials)
        return credentials
    }

    func register(username: String, password: String, name: String, deviceId: String) async throws -> SessionCredentials {
        let input = try AccountInput(username: username, password: password, displayName: name).validated(registration: true)
        clearSession()
        let context = contextVersion
        let response = try await send("auth/register", method: "POST", body: [
            "username": .string(input.username), "password": .string(input.password), "display_name": .string(input.displayName),
            "device_id": .string(deviceId), "device_name": .string("我的 iPhone")
        ], authenticated: false, expectedContext: context)
        guard let value = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "注册响应无效") }
        let credentials = try Codec.decode(SessionCredentials.self, from: value)
        guard context == contextVersion else { throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新登录") }
        try setSession(credentials)
        return credentials
    }
    func registerCloud(email: String, password: String, name: String, code: String, deviceId: String) async throws -> SessionCredentials {
        clearSession()
        let context = contextVersion
        let response = try await send("auth/register", method: "POST", body: [
            "email": .string(email), "email_code": .string(code), "password": .string(password),
            "display_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "device_id": .string(deviceId), "device_name": .string("我的 iPhone")
        ], authenticated: false, expectedContext: context)
        guard let value = response.object else { throw APIError(code: "INVALID_RESPONSE", message: "注册响应无效") }
        let credentials = try Codec.decode(SessionCredentials.self, from: value)
        guard context == contextVersion else { throw APIError(code: "SESSION_CHANGED", message: "账号或服务器已切换，请重新登录") }
        try setSession(credentials)
        return credentials
    }

}
