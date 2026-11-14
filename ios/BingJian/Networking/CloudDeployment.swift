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
