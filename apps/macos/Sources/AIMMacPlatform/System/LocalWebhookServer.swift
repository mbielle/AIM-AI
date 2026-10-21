import AIMApplication
import CryptoKit
import Foundation
import Network

/// A minimal HTTP/1.1 listener bound to 127.0.0.1 for task webhooks:
/// `POST /aim/tasks/<task-id>` with `Authorization: Bearer <token>` and an
/// optional body (≤ 64 KB) handed to the run as untrusted trigger data.
/// Nothing outside this Mac can reach it.
public final class LocalWebhookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ taskID: UUID, _ token: String, _ body: String) async -> Int

    public static let defaultPort: UInt16 = 47_823
    static let maximumBody = 65_536

    private let queue = DispatchQueue(label: "com.aimai.webhooks")
    private let stateLock = NSLock()
    private var privacyTask: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var listener: NWListener?
    private let handler: Handler
    public private(set) var port: UInt16
    /// Why the listener stopped (for example, the port is used by another app).
    public private(set) var lastError: String?

    public init(port: UInt16 = LocalWebhookServer.defaultPort, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        let changes = RuntimePrivacyPolicy.globalChanges()
        privacyTask = Task { [weak self] in
            for await enabled in changes { if enabled { self?.stop() } }
        }
    }

    public static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "aimwh_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison of a presented token with a stored hash.
    public static func matches(_ token: String, hash: String) -> Bool {
        let presented = Array(tokenHash(token).utf8), stored = Array(hash.utf8)
        guard presented.count == stored.count else { return false }
        return zip(presented, stored).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public func start() throws {
        try RuntimePrivacyPolicy.requireNetwork()
        try stateLock.withLock {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 47_823)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                NSLog("AIM webhook listener failed on port %d: %@", Int(self?.port ?? 0), "\(error)")
                self?.lastError = "\(error)"
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        }
    }

    public func stop() {
        let active = stateLock.withLock { () -> [NWConnection] in
            listener?.cancel(); listener = nil
            let active = Array(connections.values); connections.removeAll()
            return active
        }
        for connection in active { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard !RuntimePrivacyPolicy.isEnabled else { connection.cancel(); return }
        let id = UUID()
        stateLock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { _ = self?.stateLock.withLock { self?.connections.removeValue(forKey: id) } }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard !RuntimePrivacyPolicy.isEnabled else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .incomplete where !complete && error == nil && buffer.count <= Self.maximumBody + 8_192:
                self.receive(connection, buffer: buffer)
            case .incomplete:
                self.respond(connection, status: 400)
            case .invalid(let status):
                self.respond(connection, status: status)
            case .request(let taskID, let token, let body):
                let handler = self.handler
                Task {
                    guard !RuntimePrivacyPolicy.isEnabled else { connection.cancel(); return }
                    let status = await handler(taskID, token, body)
                    self.respond(connection, status: status)
                }
            }
        }
    }

    enum Parsed: Equatable {
        case incomplete
        case invalid(Int)
        case request(taskID: UUID, token: String, body: String)
    }

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 8_192 ? .invalid(431) : .incomplete
        }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(400) }
        guard requestLine[0] == "POST" else { return .invalid(405) }
        let path = requestLine[1].split(separator: "?").first.map(String.init) ?? ""
        guard path.hasPrefix("/aim/tasks/"), let taskID = UUID(uuidString: String(path.dropFirst("/aim/tasks/".count))) else {
            return .invalid(404)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let authorization = headers["authorization"], authorization.lowercased().hasPrefix("bearer ") else {
            return .invalid(401)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maximumBody).contains(length) else { return .invalid(413) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = String(decoding: data[bodyStart..<data.index(bodyStart, offsetBy: length)], as: UTF8.self)
        return .request(taskID: taskID, token: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces), body: body)
    }

    deinit { privacyTask?.cancel(); listener?.cancel(); for connection in connections.values { connection.cancel() } }

    private func respond(_ connection: NWConnection, status: Int) {
        guard !RuntimePrivacyPolicy.isEnabled else { connection.cancel(); return }
        let reason = [202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 431: "Headers Too Large"][status] ?? "Error"
        let body = "{\"status\":\(status)}"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
