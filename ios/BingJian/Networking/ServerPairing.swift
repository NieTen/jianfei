import Foundation

struct ServerPairing: Codable, Sendable {
    var kind: String
    var version: Int
    var url: String
    var instanceId: String
    var caSha256: String

    static func parse(_ text: String) throws -> ServerPairing {
        var value = try Codec.decoder().decode(ServerPairing.self, from: Data(text.utf8))
        guard value.kind == "bingjian_server", value.version == 1, UUID(uuidString: value.instanceId) != nil,
              value.caSha256.count == 64, value.caSha256.allSatisfy({ $0.isHexDigit }) else {
            throw APIError(code: "PAIRING_INVALID", message: "配对信息版本、服务身份或证书指纹无效")
        }
        value.url = try ServerAddress.normalize(value.url).absoluteString
        return value
    }

    var pinKey: String {
        let address = URL(string: url)
        return "server_ca_pin:" + (address?.host ?? "").lowercased() + ":" + String(address?.port ?? 443)
    }

    func verify() async throws {
        let base = try ServerAddress.normalize(url)
        let previous = UserDefaults.standard.string(forKey: pinKey)
        UserDefaults.standard.set(caSha256.lowercased(), forKey: pinKey)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("api/v1/server-info"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try JSONDecoder().decode(JSONObject.self, from: data).text("instance_id") == instanceId else {
                throw APIError(code: "SERVER_IDENTITY", message: "连接到的服务身份与配对信息不一致")
            }
        } catch {
            UserDefaults.standard.set(previous, forKey: pinKey)
            throw error
        }
    }
}
