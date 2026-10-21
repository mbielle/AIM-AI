import AIMCore
import AIMApplication
import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// One-shot PKCE callback bound exclusively to loopback. No credential logging.
@MainActor @Observable
final class OpenRouterConnection {
    private(set) var connecting = false
    private var privacyTask: Task<Void, Never>?

    init() {
        let changes = RuntimePrivacyPolicy.globalChanges()
        privacyTask = Task { [weak self] in
            for await enabled in changes where enabled { self?.cancel() }
        }
    }
    isolated deinit { privacyTask?.cancel() }
    private(set) var status: String?
    private var privacyLease: AIMNativeNetworkLifetime?
    private var listener: NWListener?
    private var timer: Task<Void, Never>?
    private var exchange: Task<Void, Never>?
    private var clients: [NWConnection] = []
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        exchange?.cancel(); exchange = nil
        clients.forEach { $0.cancel() }; clients = []
        connecting = false
        privacyLease?.cancelUnstarted(); privacyLease = nil
    }

    func start(save: @escaping @MainActor (String) throws -> Void) {
        cancel(); status = nil
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { status = "Application private mode blocks sign-in."; return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            status = "Could not start secure sign-in."; return
        }
        let verifier = Self.base64URL(Data(bytes))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let path = "/openrouter/" + UUID().uuidString
        let id = generation
        do {
            privacyLease = try AIMNativeNetworkLifetime("OpenRouter sign-in callback")
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server; connecting = true
            guard let lifetime = privacyLease else { server.cancel(); return }
            let listenerToken = lifetime.attach()
            server.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed: lifetime.complete(listenerToken)
                default: break
                }
                Task { @MainActor in
                    guard let self, self.generation == id, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return }
                    if case .ready = state, let port = server.port {
                        var url = URLComponents(string: "https://openrouter.ai/auth")!
                        url.queryItems = [
                            .init(name: "callback_url", value: "http://127.0.0.1:\(port.rawValue)\(path)"),
                            .init(name: "code_challenge", value: challenge),
                            .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "key_label", value: "AIM Mac")
                        ]
                        if !NSWorkspace.shared.open(url.url!) { self.cancel(); self.status = "Could not open the browser." }
                    } else if case .failed = state { self.cancel(); self.status = "Could not open the local sign-in callback." }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                let connectionToken = lifetime.attach()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .cancelled, .failed: lifetime.complete(connectionToken)
                    default: break
                    }
                }
                connection.start(queue: .main)
                Task { @MainActor in
                    guard let self, self.generation == id, self.connecting, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { connection.cancel(); return }
                    self.clients.append(connection)
                    self.receive(connection, buffer: Data(), path: path, id: id, verifier: verifier, save: save)
                }
            }
            server.start(queue: .main)
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.cancel(); self.status = "Sign-in expired. Please try again."
            }
        } catch { cancel(); status = "Could not start sign-in." }
    }

    private func receive(_ connection: NWConnection, buffer: Data, path: String, id: UUID,
                         verifier: String, save: @escaping @MainActor (String) throws -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.generation == id, self.connecting, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
                let header = String(decoding: bytes, as: UTF8.self)
                guard header.contains("\r\n\r\n") else {
                    if !done { self.receive(connection, buffer: bytes, path: path, id: id, verifier: verifier, save: save) }
                    else { connection.cancel() }
                    return
                }
                let first = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard first.count == 3, first[0] == "GET",
                      let callback = URLComponents(string: "http://127.0.0.1" + first[1]),
                      callback.path == path,
                      let code = callback.queryItems?.first(where: { $0.name == "code" })?.value,
                      !code.isEmpty, self.exchange == nil else { connection.cancel(); return }
                self.listener?.cancel(); self.listener = nil
                self.exchange = Task { [weak self] in
                    guard let self else { connection.cancel(); return }
                    do {
                        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
                        request.httpMethod = "POST"; request.timeoutInterval = 45
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
                        let session = RuntimeManagedNetworkSession.make(configuration: .ephemeral, delegate: NoSignInRedirects(), delegateQueue: nil)
                        defer { session.invalidateAndCancel() }
                        let (data, response) = try await session.data(for: request)
                        guard self.generation == id, !Task.isCancelled, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { connection.cancel(); return }
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let key = object["key"] as? String, !key.isEmpty else { throw URLError(.badServerResponse) }
                        try save(key)
                        self.status = "OpenRouter connected."
                        Self.reply("Connected. You can return to AIM.", to: connection)
                    } catch {
                        guard self.generation == id else { connection.cancel(); return }
                        self.status = "Sign-in could not be completed. Please try again."
                        Self.reply("Sign-in failed. Return to AIM and try again.", to: connection)
                    }
                    self.timer?.cancel(); self.timer = nil; self.connecting = false; self.privacyLease = nil
                }
            }
        }
    }

    private static func reply(_ body: String, to connection: NWConnection) {
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class NoSignInRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
