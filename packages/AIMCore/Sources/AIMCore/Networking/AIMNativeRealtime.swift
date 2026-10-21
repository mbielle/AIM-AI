import Foundation
import Supabase

public struct AIMRealtimeSubscription: Sendable {
    public let table: String
    public let event: String
    public let filter: String?
    public init(table: String, event: String = "*", filter: String? = nil) {
        self.table = table; self.event = event; self.filter = filter
    }
}

/// AIM owns these sockets, their session and their native invalidation receipt.
/// No SDK disconnect status is treated as socket termination.
public enum AIMNativeRealtime {
    private struct Configuration { weak var client: SupabaseClient?; let url: URL; let key: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configurations: [ObjectIdentifier: Configuration] = [:]
    nonisolated(unsafe) private static var connections: [UUID: NativeRealtimeConnection] = [:]
    public static func register(client: SupabaseClient, projectURL: URL, publicKey: String) {
        lock.withLock {
            configurations = configurations.filter { $0.value.client != nil }
            configurations[ObjectIdentifier(client)] = Configuration(client: client, url: projectURL, key: publicKey)
        }
    }
    public static func changes(client: SupabaseClient, subscriptions: [AIMRealtimeSubscription]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                var connection: NativeRealtimeConnection?
                do {
                    try AIMNetworkPrivacyPolicy.requireNetwork()
                    guard let config = lock.withLock({ configurations[ObjectIdentifier(client)] }), config.client === client else {
                        throw AIMNetworkPrivacyTransactionError.invalidReceipt
                    }
                    let value = try NativeRealtimeConnection(projectURL: config.url, key: config.key)
                    connection = value
                    lock.withLock { connections[value.id] = value }
                    // Revalidate after registration: a concurrent preparation's closeAll
                    // must see this socket before it can start a network task.
                    try AIMNetworkPrivacyPolicy.requireNetwork()
                    try await withTaskCancellationHandler {
                        try await value.run(client: client, subscriptions: subscriptions) { continuation.yield($0) }
                    } onCancel: { value.beginClose() }
                    try await value.close()
                    lock.withLock { _ = connections.removeValue(forKey: value.id) }
                    continuation.finish()
                } catch {
                    if let connection {
                        do {
                            try await connection.close()
                            lock.withLock { _ = connections.removeValue(forKey: connection.id) }
                        } catch { /* Keep ownership until closeAll can obtain a native receipt. */ }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public static func closeAll() async throws {
        let current = lock.withLock { Array(connections.values) }
        for connection in current {
            try await connection.close()
            lock.withLock { _ = connections.removeValue(forKey: connection.id) }
        }
    }
}

private final class RealtimeCloseDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    var isInvalidated: Bool { lock.withLock { invalidated } }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.withLock { invalidated = true }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiatedProtocol: String?) {}
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}

private final class NativeRealtimeConnection: @unchecked Sendable {
    let id = UUID()
    private let delegate = RealtimeCloseDelegate()
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var closing = false
    private let topic = "realtime:aim-native-" + UUID().uuidString.lowercased()
    init(projectURL: URL, key: String) throws {
        guard var url = URLComponents(url: projectURL, resolvingAgainstBaseURL: false), url.scheme == "https", url.host != nil else {
            throw AIMNetworkPrivacyTransactionError.invalidReceipt
        }
        url.scheme = "wss"; url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = "/" + (url.path.isEmpty ? "" : url.path + "/") + "realtime/v1/websocket"
        url.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let endpoint = url.url else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
        var request = URLRequest(url: endpoint); request.setValue(key, forHTTPHeaderField: "apikey")
        session = AIMManagedNetworkSession.make(configuration: .ephemeral, delegate: delegate)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
    }
    func beginClose() {
        lock.withLock {
            closing = true
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }
    func close() async throws {
        beginClose()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !delegate.isInvalidated {
            guard ContinuousClock.now < deadline else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
            // Cancellation of the caller cannot masquerade as successful closure.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
        AIMManagedNetworkSession.forgetClosedSession(session)
    }
    private func send(event: String, payload: [String: Any], ref: String, topic override: String? = nil) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard !lock.withLock({ closing }) else { throw CancellationError() }
        let object: [String: Any] = ["topic": override ?? topic, "event": event, "payload": payload, "ref": ref]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }
    func run(client: SupabaseClient, subscriptions: [AIMRealtimeSubscription], yield: @escaping @Sendable (String) -> Void) async throws {
        guard !subscriptions.isEmpty else { return }
        let token = try await client.auth.session.accessToken
        try AIMNetworkPrivacyPolicy.requireNetwork()
        lock.withLock { if !closing { socket.resume() } }
        var changes: [[String: String]] = []
        for subscription in subscriptions {
            var value = ["schema": "public", "table": subscription.table, "event": subscription.event]
            if let filter = subscription.filter { value["filter"] = filter }
            changes.append(value)
        }
        try await send(event: "phx_join", payload: ["config": ["broadcast": ["ack": false, "self": false],
            "presence": ["key": "", "enabled": false], "private": false, "postgres_changes": changes], "access_token": token], ref: "1")
        let heartbeat = Task {
            var index = 2
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(20))
                try await self.send(event: "heartbeat", payload: [:], ref: String(index), topic: "phoenix")
                let current = try await client.auth.session.accessToken
                try await self.send(event: "access_token", payload: ["access_token": current], ref: String(index + 1))
                index = index >= Int.max - 2 ? 2 : index + 2
            }
        }
        defer { heartbeat.cancel() }
        while !Task.isCancelled {
            try AIMNetworkPrivacyPolicy.requireNetwork()
            let message = try await socket.receive()
            let bytes: Data
            switch message { case .string(let text): bytes = Data(text.utf8); case .data(let data): bytes = data; @unknown default: continue }
            guard bytes.count <= 1_048_576,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object["topic"] as? String == topic, let event = object["event"] as? String else { continue }
            if event == "phx_error" || event == "phx_close" { throw URLError(.networkConnectionLost) }
            if event == "phx_reply", let payload = object["payload"] as? [String: Any], payload["status"] as? String == "error" {
                throw URLError(.userAuthenticationRequired)
            }
            if event == "postgres_changes", let payload = object["payload"] as? [String: Any],
               let data = payload["data"] as? [String: Any], let table = data["table"] as? String,
               subscriptions.contains(where: { $0.table == table }) { yield(table) }
        }
    }
}
