import Foundation
import Network

// 使用真实 TCP 服务验证 URLSession 和应用 ATS 配置，不替换网络协议实现。
final class LocalHTTPTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bingjian.tests.http")
    private let status: Int
    private let body: Data

    init(status: Int = 200, body: Data = Data("{\"status\":\"ok\"}".utf8)) throws {
        self.status = status
        self.body = body
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        let queue = self.queue
        let body = self.body
        let status = self.status
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                var response = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: NSError(domain: "HTTPTestServer", code: 1))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }
}
