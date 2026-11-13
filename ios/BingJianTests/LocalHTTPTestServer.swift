import Foundation
import Network

struct LocalHTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct LocalHTTPResponse: Sendable {
    var status: Int
    var body: Data
}

// 使用真实 TCP 服务验证 URLSession 和应用 ATS 配置，不替换网络协议实现。
final class LocalHTTPTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bingjian.tests.http")
    private let status: Int
    private let body: Data
    private let handler: (@Sendable (LocalHTTPRequest) async -> LocalHTTPResponse)?
    // 连接集合仅在 queue 上访问；stop 也投递到同一队列，确保等待响应的连接能够关闭。
    private var connections: [NWConnection] = []

    init(status: Int = 200, body: Data = Data("{\"status\":\"ok\"}".utf8),
         handler: (@Sendable (LocalHTTPRequest) async -> LocalHTTPResponse)? = nil) throws {
        self.status = status
        self.body = body
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
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

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            guard buffer.count <= 1024 * 1024 else { self.finish(connection); return }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.finish(connection) }
                else { self.receive(connection, buffered: buffer) }
                return
            }
            let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count >= 2 else { self.finish(connection); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= 1024 * 1024 else { self.finish(connection); return }
            let receivedBody = buffer[separator.upperBound...]
            guard receivedBody.count >= length else {
                if complete { self.finish(connection) }
                else { self.receive(connection, buffered: buffer) }
                return
            }
            let request = LocalHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                                           body: Data(receivedBody.prefix(length)))
            if let handler = self.handler {
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            } else { self.send(LocalHTTPResponse(status: self.status, body: self.body), on: connection) }
        }
    }

    private func send(_ reply: LocalHTTPResponse, on connection: NWConnection) {
        var response = Data("HTTP/1.1 \(reply.status) Response\r\nContent-Type: application/json\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(reply.body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            if let self { self.queue.async { self.finish(connection) } }
            else { connection.cancel() }
        })
    }

    private func finish(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connection.cancel()
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        queue.async { [self] in
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
