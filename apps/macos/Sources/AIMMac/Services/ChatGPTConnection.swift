import AIMCore
import AIMApplication
import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// Official "Sign in with ChatGPT": the system browser, a one-shot loopback callback on
/// `http://127.0.0.1:<port>/callback`, PKCE S256, state and nonce. No credential logging.
@MainActor @Observable
final class ChatGPTConnection {
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

    /// This installation's identity with OpenAI (not secret): the agent host ID and, after the
    /// first sign-in, the client ID OpenAI issued. Kept across disconnects.
    struct Installation: Codable { var hostID: String; var clientID: String? }
    private static let installationKey = "aim.chatgpt.installation"

    static var installation: Installation {
        get {
            if let data = UserDefaults.standard.data(forKey: installationKey),
               let saved = try? JSONDecoder().decode(Installation.self, from: data) { return saved }
            let fresh = Installation(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), clientID: nil)
            installation = fresh
            return fresh
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: installationKey) }
    }

    func cancel() {
        generation = UUID()
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        exchange?.cancel(); exchange = nil
        clients.forEach { $0.cancel() }; clients = []
        connecting = false
        privacyLease?.cancelUnstarted(); privacyLease = nil
    }

    func credentialReadFailed() {
        status = "Could not read the saved ChatGPT connection. Unlock your keychain and try again; existing credentials were preserved."
    }

    func start(previous saved: ChatGPTPlanAuth.Session? = nil, save: @escaping @MainActor (ChatGPTPlanAuth.Session) throws -> Void) {
        cancel(); status = nil
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { status = "Application private mode blocks sign-in."; return }
        guard let verifier = Self.random(), let state = Self.random(), let nonce = Self.random() else {
            status = "Could not start secure sign-in."; return
        }
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        // A legacy record has no verified account binding: preserve it until a new,
        // explicit registration succeeds; never reuse it as an authenticated session.
        let previous = saved.flatMap { $0.hasValidatedIdentity ? $0 : nil }
        let installation = Installation(hostID: previous?.hostID ?? Self.installation.hostID, clientID: previous?.clientID)
        let id = generation
        do {
            privacyLease = try AIMNativeNetworkLifetime("ChatGPT sign-in callback")
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server; connecting = true
            guard let lifetime = privacyLease else { server.cancel(); return }
            let listenerToken = lifetime.attach()
            server.stateUpdateHandler = { [weak self] serverState in
                switch serverState {
                case .cancelled, .failed: lifetime.complete(listenerToken)
                default: break
                }
                Task { @MainActor in
                    guard let self, self.generation == id, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return }
                    if case .ready = serverState, let port = server.port {
                        let redirect = "http://127.0.0.1:\(port.rawValue)/callback"
                        let url = ChatGPTPlanAuth.authorizationURL(clientID: installation.clientID, hostID: installation.hostID,
                                                                   redirectURI: redirect, state: state, nonce: nonce, codeChallenge: challenge, previous: previous)
                        if !NSWorkspace.shared.open(url) { self.cancel(); self.status = "Could not open the browser." }
                    } else if case .failed = serverState { self.cancel(); self.status = "Could not open the local sign-in callback." }
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
                    guard let self, self.generation == id, self.connecting, !RuntimePrivacyPolicy.isApplicationNetworkBlocked, let port = server.port else { connection.cancel(); return }
                    self.clients.append(connection)
                    let flow = Flow(id: id, verifier: verifier, state: state, nonce: nonce, previous: previous, installation: installation,
                                    redirect: "http://127.0.0.1:\(port.rawValue)/callback")
                    self.receive(connection, buffer: Data(), flow: flow, save: save)
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

    private struct Flow { let id: UUID; let verifier: String; let state: String; let nonce: String; let previous: ChatGPTPlanAuth.Session?; let installation: Installation; let redirect: String }

    /// The callback's outcome, read from the request line `GET /callback?… HTTP/1.1`.
    enum Callback: Equatable, Sendable { case code(String, clientID: String?), denied, invalid }

    nonisolated static func parse(requestLine: String, state: String) -> Callback {
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == "/callback" else { return .invalid }
        let items = url.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard Set(items.map(\.name)).count == items.count, value("state") == state else { return .invalid }
        if value("error") != nil { return .denied }
        guard let code = value("code"), !code.isEmpty else { return .invalid }
        return .code(code, clientID: value("client_id").flatMap { $0.isEmpty ? nil : $0 })
    }

    private func receive(_ connection: NWConnection, buffer: Data, flow: Flow,
                         save: @escaping @MainActor (ChatGPTPlanAuth.Session) throws -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.generation == flow.id, self.connecting else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
                let header = String(decoding: bytes, as: UTF8.self)
                guard header.contains("\r\n\r\n") else {
                    if !done { self.receive(connection, buffer: bytes, flow: flow, save: save) } else { connection.cancel() }
                    return
                }
                let line = header.components(separatedBy: "\r\n").first ?? ""
                switch Self.parse(requestLine: line, state: flow.state) {
                case .invalid:
                    connection.cancel()
                case .denied:
                    self.listener?.cancel(); self.listener = nil
                    self.status = ChatGPTPlanAuth.AuthError.denied.errorDescription
                    Self.reply("Sign-in cancelled. You can return to AIM.", to: connection)
                    self.timer?.cancel(); self.timer = nil; self.connecting = false; self.privacyLease = nil
                case .code(let code, let issuedClientID):
                    guard self.exchange == nil else { connection.cancel(); return }
                    self.listener?.cancel(); self.listener = nil
                    self.exchange = Task { [weak self] in
                        guard let self else { connection.cancel(); return }
                        do {
                            let clientID = try ChatGPTPlanAuth.issuedClientID(callback: issuedClientID, selected: flow.installation.clientID)
                            let request = ChatGPTPlanAuth.exchangeRequest(code: code, clientID: clientID,
                                                                          verifier: flow.verifier, redirectURI: flow.redirect)
                            let http = ChatGPTPlanAuth.networkSession()
                            defer { http.invalidateAndCancel() }
                            let (data, response) = try await http.data(for: request)
                            guard self.generation == flow.id, !Task.isCancelled, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { connection.cancel(); return }
                            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTPlanAuth.AuthError.invalidResponse }
                            let jwks = try await ChatGPTPlanAuth.fetchJWKS(using: http)
                            guard self.generation == flow.id, !Task.isCancelled, !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { connection.cancel(); return }
                            let session = try ChatGPTPlanAuth.session(from: data, clientID: clientID, hostID: flow.installation.hostID,
                                                                     previous: flow.previous, nonce: flow.nonce, jwks: jwks)
                            try save(session)
                            Self.installation = Installation(hostID: flow.installation.hostID, clientID: clientID)
                            self.status = session.canUsePlan ? "ChatGPT connected." : "Signed in. ChatGPT plan usage was not granted; review permissions in ChatGPT."
                            Self.reply("Connected. You can return to AIM.", to: connection)
                        } catch {
                            guard self.generation == flow.id else { connection.cancel(); return }
                            self.status = (error as? ChatGPTPlanAuth.AuthError)?.errorDescription
                                ?? "Sign-in could not be completed. Please try again."
                            Self.reply("Sign-in failed. Return to AIM and try again.", to: connection)
                        }
                        self.timer?.cancel(); self.timer = nil; self.connecting = false; self.privacyLease = nil
                    }
                }
            }
        }
    }

    private static func reply(_ body: String, to connection: NWConnection) {
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    private static func random() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
