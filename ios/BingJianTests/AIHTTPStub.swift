import Foundation
@testable import BingJian

struct AIRecordedRequest {
    let url: URL?
    let authorization: String?
    let body: JSONObject
}

// 只供测试使用；每个测试使用独立域名，所有请求均在进程内响应，不访问真实 AI。
final class AIHTTPStub: @unchecked Sendable {
    let host = "ai-" + UUID().uuidString.lowercased() + ".invalid"
    private let lock = NSLock()
    private var replies: [JSONObject] = []
    private var recorded: [AIRecordedRequest] = []

    var requests: [AIRecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func reset(_ responses: [JSONObject]) {
        lock.lock(); defer { lock.unlock() }
        replies = responses
        recorded = []
    }

    func respond(to request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = data.isEmpty ? [:] : try JSONDecoder().decode(JSONObject.self, from: data)
        lock.lock(); defer { lock.unlock() }
        recorded.append(AIRecordedRequest(url: request.url, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return try JSONEncoder().encode(replies[min(recorded.count - 1, replies.count - 1)])
    }

    func session() -> URLSession {
        AIStubURLProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class AIStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [String: AIHTTPStub] = [:]

    static func register(_ stub: AIHTTPStub) {
        lock.lock(); defer { lock.unlock() }
        stubs[stub.host] = stub
    }

    static func unregister(_ stub: AIHTTPStub) {
        lock.lock(); defer { lock.unlock() }
        stubs.removeValue(forKey: stub.host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stubs[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            guard let stub, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.unsupportedURL)
            }
            let data = try stub.respond(to: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}
