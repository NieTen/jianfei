import Foundation

struct AIConfiguration: Codable, Equatable, Sendable {
    var baseUrl = "https://api.openai.com/v1"
    var model = ""
    var execution = "gateway"
    var external = true
    var structuredOutput = true
    var allowOutsideLan = false
    var useServerDefaults = false
    var maxOutputTokens = 4096

    var configured: Bool { useServerDefaults || (!baseUrl.isEmpty && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
}

struct AIModelOption: Codable, Identifiable, Sendable {
    var id: String
    var name: String
}

enum AIAddress {
    static func normalize(_ input: String) throws -> URL {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw APIError(code: "AI_URL", message: "请输入有效的 HTTPS AI API 地址")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/responses") { path = String(path.dropLast("/responses".count)) }
        components.path = path.isEmpty ? "/v1" : path
        guard let url = components.url else { throw APIError(code: "AI_URL", message: "AI 地址无效") }
        return url
    }
}
