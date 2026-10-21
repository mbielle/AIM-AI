import CryptoKit
import Foundation

public enum MCPAuthorizationError: LocalizedError {
    case metadata, registrationRequired, invalidCallback, invalidToken, expired
    public var errorDescription: String? {
        switch self {
        case .metadata: "The connector did not provide usable HTTPS authorization metadata."
        case .registrationRequired: "This connector requires an OAuth client registration for AIM. You can use its own bearer token instead."
        case .invalidCallback: "The connector sign-in response could not be verified."
        case .invalidToken: "The connector did not return a usable access token."
        case .expired: "Sign-in expired. Start again."
        }
    }
}
public struct MCPAuthorizationTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public let clientID: String
    public let tokenEndpoint: URL
    public let resource: URL
    public func refreshed(session: URLSession = NativeChatTransport.secretSession(), force: Bool = false) async throws -> Self {
        guard force || expiresAt.map({ $0.timeIntervalSinceNow < 60 }) == true else { return self }
        guard let refreshToken else { throw MCPAuthorizationError.expired }
        var next = try await MCPAuthorizationFlow.tokens(endpoint: tokenEndpoint, form: ["grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": clientID, "resource": resource.absoluteString], clientID: clientID, resource: resource, session: session)
        next.refreshToken = next.refreshToken ?? refreshToken
        return next
    }
}

/// OAuth 2.1 for HTTPS MCP: protected-resource discovery, DCR, S256, state and
/// resource audience. UI provides the system web session; tokens never leave Keychain.
public struct MCPAuthorizationFlow: Sendable {
    public let authorizationURL: URL
    private let tokenEndpoint: URL
    private let resource: URL
    private let callbackURL: URL
    private let clientID: String
    private let verifier: String
    private let state: String
    private let createdAt: Date
    public init(authorizationEndpoint: URL, tokenEndpoint: URL, resource: URL, callbackURL: URL, clientID: String, now: Date = .now) throws {
        for url in [authorizationEndpoint, tokenEndpoint, resource, callbackURL] { try Self.requireHTTPS(url) }
        guard callbackURL.query == nil, !clientID.isEmpty else { throw MCPAuthorizationError.metadata }
        self.tokenEndpoint = tokenEndpoint; self.resource = resource; self.callbackURL = callbackURL; self.clientID = clientID; createdAt = now
        verifier = try SecureNonceGenerator().generate(length: 64); state = try SecureNonceGenerator().generate(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else { throw MCPAuthorizationError.metadata }
        components.queryItems = [.init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callbackURL.absoluteString), .init(name: "resource", value: resource.absoluteString),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)]
        guard let url = components.url else { throw MCPAuthorizationError.metadata }; authorizationURL = url
    }
    public func exchangeRequest(callback: URL, now: Date = .now) throws -> URLRequest {
        guard now >= createdAt, now.timeIntervalSince(createdAt) <= 300 else { throw MCPAuthorizationError.expired }
        guard callback.scheme == callbackURL.scheme, callback.host == callbackURL.host, callback.port == callbackURL.port,
              callback.path == callbackURL.path, callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.count <= 4096, !items.contains(where: { $0.name == "error" }) else { throw MCPAuthorizationError.invalidCallback }
        return try Self.formRequest(tokenEndpoint, form: ["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": clientID, "redirect_uri": callbackURL.absoluteString, "resource": resource.absoluteString])
    }
    public func exchange(callback: URL, session: URLSession = NativeChatTransport.secretSession()) async throws -> MCPAuthorizationTokens {
        let request = try exchangeRequest(callback: callback)
        let (data, response) = try await session.data(for: request)
        return try Self.decodeTokens(data, response: response, clientID: clientID, resource: resource, endpoint: tokenEndpoint)
    }
    public static func prepare(resource: URL, callback: URL, session: URLSession = NativeChatTransport.secretSession()) async throws -> Self {
        try requireHTTPS(resource); try requireHTTPS(callback)
        var probe = URLRequest(url: resource, timeoutInterval: 20); probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type"); probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
        let (_, response) = try await session.data(for: probe)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        var root = URLComponents(url: resource, resolvingAgainstBaseURL: false)!; root.path = ""; root.query = nil
        var candidates: [URL] = []
        if let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression),
           let url = URL(string: String(header[range].dropFirst("resource_metadata=\"".count).dropLast())) { candidates.append(url) }
        candidates += [root.url!.appendingPathComponent(".well-known/oauth-protected-resource" + resource.path), root.url!.appendingPathComponent(".well-known/oauth-protected-resource")]
        var issuers: [URL] = []
        for url in candidates {
            guard let metadata = try? await json(url, session: session), metadata["resource"] as? String == resource.absoluteString,
                  let raw = metadata["authorization_servers"] as? [String], !raw.isEmpty, raw.count <= 10 else { continue }
            issuers = raw.compactMap(URL.init(string:)); break
        }
        for issuer in issuers {
            try requireHTTPS(issuer)
            var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!; components.path = ""; components.query = nil
            let path = issuer.path == "/" ? "" : issuer.path
            for suffix in [".well-known/oauth-authorization-server" + path, ".well-known/openid-configuration" + path] {
                guard let metadata = try? await json(components.url!.appendingPathComponent(suffix), session: session),
                      metadata["issuer"] as? String == issuer.absoluteString,
                      (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
                      let authorization = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                      let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)) else { continue }
                guard let registration = (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)) else { throw MCPAuthorizationError.registrationRequired }
                try requireHTTPS(registration); try requireHTTPS(authorization); try requireHTTPS(token)
                var request = URLRequest(url: registration, timeoutInterval: 30); request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "AIM", "redirect_uris": [callback.absoluteString],
                    "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
                let (data, response) = try await session.data(for: request)
                guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), data.count <= 1_000_000,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let client = object["client_id"] as? String,
                      object["client_secret"] == nil else { throw MCPAuthorizationError.registrationRequired }
                return try Self(authorizationEndpoint: authorization, tokenEndpoint: token, resource: resource, callbackURL: callback, clientID: client)
            }
        }
        throw MCPAuthorizationError.metadata
    }
    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil else { throw MCPAuthorizationError.metadata }
    }
    private static func json(_ url: URL, session: URLSession) async throws -> [String: Any] {
        try requireHTTPS(url)
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPAuthorizationError.metadata }
        return object
    }
    private static func formRequest(_ endpoint: URL, form: [String: String]) throws -> URLRequest {
        try requireHTTPS(endpoint)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = form.sorted { $0.key < $1.key }.map { ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: endpoint, timeoutInterval: 30); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data(body.utf8)
        return request
    }
    fileprivate static func tokens(endpoint: URL, form: [String: String], clientID: String, resource: URL, session: URLSession) async throws -> MCPAuthorizationTokens {
        let (data, response) = try await session.data(for: formRequest(endpoint, form: form))
        return try decodeTokens(data, response: response, clientID: clientID, resource: resource, endpoint: endpoint)
    }
    private static func decodeTokens(_ data: Data, response: URLResponse, clientID: String, resource: URL, endpoint: URL) throws -> MCPAuthorizationTokens {
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String,
              !access.isEmpty, access.count <= 16384, !access.contains(where: \.isWhitespace),
              (object["token_type"] as? String)?.lowercased() == "bearer" else { throw MCPAuthorizationError.invalidToken }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue
        if let expires, !expires.isFinite || expires <= 0 { throw MCPAuthorizationError.invalidToken }
        return .init(accessToken: access, refreshToken: object["refresh_token"] as? String, expiresAt: expires.map { Date().addingTimeInterval($0) }, clientID: clientID, tokenEndpoint: endpoint, resource: resource)
    }
}
