import AIMApplication
import AIMCore
import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth 2.1 for remote MCP servers, per the MCP authorization spec: protected
/// resource metadata → authorization server metadata → dynamic client
/// registration → authorization code with PKCE through the person's browser and
/// a one-shot loopback redirect → tokens in the Keychain, refreshed when needed.
public enum MCPOAuth {
    public struct ServerMetadata: Codable, Equatable, Sendable {
        public let issuer: String?
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
        public let scopes: [String]
    }

    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var clientID: String
        public var tokenEndpoint: URL
        public var resource: String

        var isFresh: Bool { expiresAt.map { $0.timeIntervalSinceNow > 60 } ?? true }
    }

    public enum OAuthError: LocalizedError, Equatable {
        case noMetadata, noRegistration, denied(String), timedOut, invalidResponse(String), needsSignIn(String)
        public var errorDescription: String? {
            switch self {
            case .noMetadata: "The server does not publish OAuth metadata."
            case .noRegistration: "The server does not allow dynamic client registration; add a bearer token instead."
            case .denied(let reason): "Sign-in was refused: \(reason)."
            case .timedOut: "Sign-in timed out (no answer from the browser within 5 minutes)."
            case .invalidResponse(let detail): "Unexpected OAuth response: \(detail)."
            case .needsSignIn(let name): "The MCP server \(name) needs sign-in: Settings → Connectors → Sign in."
            }
        }
    }

    static let tokenSecretName = "OAUTH_TOKENS"

    // MARK: Token storage

    public static func storedTokens(serverID: UUID) -> Tokens? {
        guard let data = try? KeychainSecureStore(service: MCPSecretStore.service)
            .readData(forKey: "\(serverID.uuidString)/\(tokenSecretName)") else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func store(_ tokens: Tokens, serverID: UUID) throws {
        try KeychainSecureStore(service: MCPSecretStore.service)
            .store(try JSONEncoder().encode(tokens), forKey: "\(serverID.uuidString)/\(tokenSecretName)")
    }

    public static func signOut(serverID: UUID) {
        try? KeychainSecureStore(service: MCPSecretStore.service).removeData(forKey: "\(serverID.uuidString)/\(tokenSecretName)")
    }

    /// A usable access token: the stored one, refreshed when it is about to expire.
    static func accessToken(serverID: UUID, session: URLSession = RuntimeManagedNetworkSession.shared, forceRefresh: Bool = false) async throws -> String? {
        guard var tokens = storedTokens(serverID: serverID) else { return nil }
        if tokens.isFresh && !forceRefresh { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { return forceRefresh ? nil : tokens.accessToken }
        let response = try await tokenRequest(tokens.tokenEndpoint, form: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": tokens.clientID, "resource": tokens.resource], session: session)
        tokens.accessToken = response.accessToken
        tokens.refreshToken = response.refreshToken ?? refresh
        tokens.expiresAt = response.expiresAt
        try store(tokens, serverID: serverID)
        return tokens.accessToken
    }

    // MARK: Discovery

    /// `resource_metadata="…"` from a 401's WWW-Authenticate header.
    static func resourceMetadataURL(fromChallenge header: String?) -> URL? {
        guard let header, let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        let value = header[range].dropFirst("resource_metadata=\"".count).dropLast()
        return URL(string: String(value))
    }

    public static func discover(serverURL: URL, session: URLSession = RuntimeManagedNetworkSession.shared) async throws -> ServerMetadata {
        // 1. Unauthenticated probe for the resource-metadata hint.
        var probe = URLRequest(url: serverURL)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
        let challenge = (try? await session.data(for: probe)).flatMap {
            ($0.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
        }
        var origin = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        origin.path = ""; origin.query = nil; origin.fragment = nil
        let base = origin.url!
        var issuers: [URL] = []
        let resourceCandidates = [resourceMetadataURL(fromChallenge: challenge),
                                  base.appendingPathComponent(".well-known/oauth-protected-resource" + serverURL.path),
                                  base.appendingPathComponent(".well-known/oauth-protected-resource")].compactMap { $0 }
        for candidate in resourceCandidates {
            if let object = try? await json(candidate, session: session),
               let servers = object["authorization_servers"] as? [String] {
                issuers = servers.compactMap(URL.init(string:))
                break
            }
        }
        if issuers.isEmpty { issuers = [base] }
        // 2. Authorization server metadata (RFC 8414, then OpenID discovery).
        for issuer in issuers {
            let path = issuer.path == "/" ? "" : issuer.path
            var root = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
            root.path = ""
            for suffix in [".well-known/oauth-authorization-server" + path, ".well-known/openid-configuration" + path] {
                guard let url = root.url?.appendingPathComponent(suffix),
                      let object = try? await json(url, session: session),
                      let authorization = (object["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                      let token = (object["token_endpoint"] as? String).flatMap(URL.init(string:)) else { continue }
                return ServerMetadata(issuer: object["issuer"] as? String, authorizationEndpoint: authorization,
                    tokenEndpoint: token,
                    registrationEndpoint: (object["registration_endpoint"] as? String).flatMap(URL.init(string:)),
                    scopes: object["scopes_supported"] as? [String] ?? [])
            }
        }
        throw OAuthError.noMetadata
    }

    static func register(_ metadata: ServerMetadata, redirectURI: String, session: URLSession = RuntimeManagedNetworkSession.shared) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint else { throw OAuthError.noRegistration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "AIM AI", "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none"])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = object["client_id"] as? String else {
            throw OAuthError.invalidResponse("client registration failed")
        }
        return clientID
    }

    // MARK: PKCE

    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(_ metadata: ServerMetadata, clientID: String, redirectURI: String,
                                 challenge: String, state: String, resource: String) -> URL? {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
                  URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "code_challenge", value: challenge),
                  URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state),
                  URLQueryItem(name: "resource", value: resource)]
        if !metadata.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: metadata.scopes.joined(separator: " "))) }
        components?.queryItems = items
        return components?.url
    }

    // MARK: Sign-in

    /// The full interactive flow. Opens the person's default browser; returns
    /// once tokens are stored. Never call it without a person's action.
    @discardableResult
    public static func signIn(server: MCPServerConfiguration, session: URLSession = RuntimeManagedNetworkSession.shared,
                              openBrowser: @Sendable (URL) async -> Void = { url in _ = await MainActor.run { NSWorkspace.shared.open(url) } })
        async throws -> Tokens {
        try RuntimePrivacyPolicy.requireNetwork()
        guard let raw = server.url, let serverURL = URL(string: raw) else { throw OAuthError.noMetadata }
        let metadata = try await discover(serverURL: serverURL, session: session)
        let callback = try LoopbackRedirect()
        defer { callback.stop() }
        let redirectURI = "http://127.0.0.1:\(try await callback.start())/callback"
        let clientID = try await register(metadata, redirectURI: redirectURI, session: session)
        let verifier = codeVerifier()
        let state = codeVerifier()
        guard let url = authorizationURL(metadata, clientID: clientID, redirectURI: redirectURI,
                                         challenge: codeChallenge(for: verifier), state: state, resource: raw) else {
            throw OAuthError.invalidResponse("authorization URL")
        }
        await openBrowser(url)
        let query = try await callback.wait(timeout: 300)
        if let error = query["error"] { throw OAuthError.denied(query["error_description"] ?? error) }
        guard query["state"] == state, let code = query["code"] else { throw OAuthError.invalidResponse("state mismatch") }
        let response = try await tokenRequest(metadata.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier, "resource": raw], session: session)
        let tokens = Tokens(accessToken: response.accessToken, refreshToken: response.refreshToken,
                            expiresAt: response.expiresAt, clientID: clientID,
                            tokenEndpoint: metadata.tokenEndpoint, resource: raw)
        try store(tokens, serverID: server.id)
        return tokens
    }

    struct TokenResponse { let accessToken: String; let refreshToken: String?; let expiresAt: Date? }

    static func tokenRequest(_ endpoint: URL, form: [String: String], session: URLSession) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let access = object["access_token"] as? String else {
            throw OAuthError.invalidResponse((object["error"] as? String) ?? "token endpoint refused the request")
        }
        let expires = (object["expires_in"] as? NSNumber).map { Date.now.addingTimeInterval($0.doubleValue) }
        return TokenResponse(accessToken: access, refreshToken: object["refresh_token"] as? String, expiresAt: expires)
    }

    private static func json(_ url: URL, session: URLSession) async throws -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// A one-shot HTTP listener on 127.0.0.1 (ephemeral port) receiving the OAuth redirect.
final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.aimai.oauth-redirect")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { ready.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.claim() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.withLock {
                        if let received = self.received { continuation.resume(returning: received) } else { self.continuation = continuation }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPOAuth.OAuthError.timedOut
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1" + target)
            guard components?.path == "/callback" else {
                Self.reply(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            Self.reply(connection, status: "200 OK",
                       body: "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>AIM is signed in.</h2><p>You can close this tab and return to AIM.</p></body></html>")
            self?.lock.withLock {
                guard let self, self.received == nil else { return }
                self.received = query
                self.continuation?.resume(returning: query)
                self.continuation = nil
            }
        }
    }

    private static func reply(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
