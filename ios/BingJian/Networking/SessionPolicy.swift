import Foundation
import CryptoKit
import Security

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let key = "server_ca_pin:" + space.host.lowercased() + ":" + String(space.port)
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let pin = UserDefaults.standard.string(forKey: key) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = space.serverTrust, SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let matches = chain.contains { certificate in
            let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            return digest.map { String(format: "%02x", $0) }.joined() == pin
        }
        completionHandler(matches ? .useCredential : .cancelAuthenticationChallenge, matches ? URLCredential(trust: trust) : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ServerAddress {
    static func normalize(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw APIError(code: "SERVER_URL", message: "请输入有效的 HTTP 或 HTTPS 后台地址")
        }
        components.scheme = scheme
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api/v1") { path = String(path.dropLast("/api/v1".count)) }
        components.path = path
        guard let url = components.url else { throw APIError(code: "SERVER_URL", message: "后台地址无效") }
        return url
    }
}
