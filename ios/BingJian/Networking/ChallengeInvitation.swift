import Foundation

enum ChallengeInvitation {
    static func valid(_ code: String) -> Bool {
        code.utf8.count == 24 && code.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func link(code: String, server: String) -> String {
        if let url = URL(string: server), url.scheme == "https", url.host != nil,
           var parts = URLComponents(url: url.appendingPathComponent("join"), resolvingAgainstBaseURL: false) {
            parts.fragment = code
            return parts.string ?? code
        }
        var parts = URLComponents()
        parts.scheme = "bingjian"
        parts.host = "join"
        parts.queryItems = [URLQueryItem(name: "code", value: code)]
        return parts.string ?? code
    }

    static func read(_ url: URL, server: String) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return nil }
        var value: String?
        if parts.scheme == "bingjian", parts.host == "join" {
            if let origin = parts.queryItems?.first(where: { $0.name == "origin" })?.value,
               !matchesOrigin(URL(string: origin), server: server) { return nil }
            value = parts.queryItems?.first(where: { $0.name == "code" })?.value
        } else if matchesOrigin(url, server: server), let base = URL(string: server),
                  url.path == base.appendingPathComponent("join").path {
            value = parts.fragment
        }
        guard let code = value, valid(code) else { return nil }
        return code
    }

    private static func matchesOrigin(_ origin: URL?, server: String) -> Bool {
        guard let origin, let base = URL(string: server), let host = base.host, base.scheme == "https" else { return false }
        return origin.scheme == "https" && origin.host?.lowercased() == host.lowercased()
            && (origin.port ?? 443) == (base.port ?? 443)
    }
}

/// 用服务器签发的时长限制旧服务端的长租约，客户端回拨时钟后拒绝展示缓存。
enum SharedSummaryLease {
    /// 通用共享按服务器剩余时长和网络耗时计算，手机时钟落后不能延长授权。
    static func grantDuration(_ summary: JSONObject, elapsed: TimeInterval) -> TimeInterval {
        guard let until = TimeFormat.parse(summary.text("expires_at")),
              let server = TimeFormat.parse(summary.text("server_time")), elapsed >= 0 else { return 0 }
        return max(0, min(60, until.timeIntervalSince(server) - elapsed))
    }

    static func expiry(_ summary: JSONObject, now: Date = Date()) -> Date? {
        guard let until = TimeFormat.parse(summary.text("cached_until")),
              let server = TimeFormat.parse(summary.text("server_time")),
              let saved = TimeFormat.parse(summary.text("cached_at_local")), now >= saved else { return nil }
        let expiry = saved.addingTimeInterval(min(300, until.timeIntervalSince(server)))
        return expiry > now ? expiry : nil
    }
}
