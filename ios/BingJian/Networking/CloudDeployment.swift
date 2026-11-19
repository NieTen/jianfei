import Foundation

/// 官方地址只来自构建配置；空值保留历史私有部署，非法非空值按云模式关闭 AI。
enum CloudDeployment {
    // 仅为当前明确指定的内网部署放行 HTTP，其他云服务仍要求 HTTPS。
    static let localHTTPServerURL = URL(string: "http://192.168.50.229:8000")!

    static var configuredValue: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "BingJianCloudServerURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }
    static var requested: Bool { !configuredValue.isEmpty }
    static var serverURL: URL? { validatedURL(configuredValue) }

    static func validatedURL(_ value: String) -> URL? {
        guard !value.isEmpty, let parsed = try? ServerAddress.normalize(value),
              parsed.scheme == "https" || parsed == localHTTPServerURL else { return nil }
        return parsed
    }
}

/// 权益只短期缓存用于展示；按服务端剩余时长计算，避免手机修改时钟延长资格。
enum CloudEntitlementLease {
    static func duration(_ value: JSONObject) -> TimeInterval {
        guard value.flag("ai_food_recognition"),
              let serverTime = TimeFormat.parse(value.text("server_time")),
              let expiry = TimeFormat.parse(value.text("valid_until")) else { return 0 }
        return min(300, max(0, expiry.timeIntervalSince(serverTime)))
    }
}

/// 待撤回是本机用户意图；服务端旧的 allowed=true 不得覆盖它。
struct CloudAIRevocationStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func scope(server: String, instance: String, user: String) -> String {
        // 授权属于云账号；同账号重新关联另一份离线空间也不能丢掉尚未确认的撤回。
        let parts = [server, instance, user]
        let encoded = (try? JSONEncoder().encode(parts)) ?? Data()
        return "pending_cloud_ai_revocation:" + encoded.base64EncodedString()
    }

    func pendingToken(for scope: String) -> String? { defaults.string(forKey: scope) }

    @discardableResult
    func request(for scope: String) -> String {
        let token = UUID().uuidString
        defaults.set(token, forKey: scope)
        return token
    }

    func acknowledge(scope: String, token: String) {
        // 旧请求迟到的确认不能清掉用户随后再次发出的撤回意图。
        guard pendingToken(for: scope) == token else { return }
        defaults.removeObject(forKey: scope)
    }

    func applyingLocalDenial(to consent: JSONObject, scope: String) -> JSONObject {
        guard pendingToken(for: scope) != nil else { return consent }
        var result = consent
        result["allowed"] = .bool(false)
        return result
    }
}
