import Foundation
import CoreFoundation

/// OpenAI's official "Sign in with ChatGPT" for agents: requests use the person's ChatGPT plan
/// (the Work and Codex usage included in Plus/Pro, no extra charge) through the public
/// Responses API. Public client without secret: PKCE, loopback redirect, refresh tokens.
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
public enum ChatGPTPlanAuth {
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let resource = "https://api.openai.com/v1"
    public static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    /// Keychain names: the current access token (read like any provider key) and the session.
    public static let sessionKey = "chatgpt.oauth"

    /// What AIM keeps between launches (in the Keychain).
    public struct Session: Codable, Equatable, Sendable {
        public var clientID: String
        public var hostID: String
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
        public var email: String?

        public var issuer: String? = nil
        public var subject: String? = nil
        public var idToken: String? = nil
        public var scopes: [String]? = nil
        public var hasValidatedIdentity: Bool {
            issuer == ChatGPTIdentityValidator.issuer && subject?.isEmpty == false && clientID != "dynamic_agent_client" && !clientID.isEmpty
        }
        public var canUsePlan: Bool { hasValidatedIdentity && scopes?.contains(ChatGPTPlanAuth.planScope) == true && scopes?.contains("resource.invoke") == true }
        public var isFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }
    }

    /// The browser URL. First sign-in uses `dynamic_agent_client`; OpenAI then issues this
    /// installation's own client ID, used from then on.
    public static func authorizationURL(clientID: String?, hostID: String, redirectURI: String,
                                        state: String, nonce: String, codeChallenge: String, previous: Session? = nil) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID ?? "dynamic_agent_client"),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "resource", value: resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "ext_agent_host_id", value: hostID),
        ]
        if clientID == nil { items.append(.init(name: "agent_name_hint", value: "AIM AI")) }
        if let previous, previous.hasValidatedIdentity, previous.clientID == clientID {
            if let token = previous.idToken { items.append(.init(name: "id_token_hint", value: token)) }
            if let email = previous.email { items.append(.init(name: "login_hint", value: email)) }
        }
        components.queryItems = items
        return components.url!
    }

    public static func tokenRequest(form: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        return request
    }

    public static func exchangeRequest(code: String, clientID: String, verifier: String, redirectURI: String) -> URLRequest {
        tokenRequest(form: ["grant_type": "authorization_code", "code": code, "client_id": clientID,
                            "code_verifier": verifier, "redirect_uri": redirectURI, "resource": resource])
    }

    public static func refreshRequest(_ session: Session) -> URLRequest? {
        guard session.hasValidatedIdentity, let refresh = session.refreshToken, !refresh.isEmpty else { return nil }
        return tokenRequest(form: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": session.clientID, "resource": resource])
    }

    public enum AuthError: LocalizedError, Equatable {
        case denied, missingPlanAccess, invalidResponse, invalidIdentity, reauthorizationRequired
        public var errorDescription: String? {
            switch self {
            case .denied: "ChatGPT sign-in was cancelled."
            case .missingPlanAccess: "ChatGPT did not allow AIM to use your plan. Review the permissions in ChatGPT and your plan’s availability and limits."
            case .invalidIdentity: "ChatGPT identity could not be verified. Your saved connection was preserved."
            case .reauthorizationRequired: "Please sign in with ChatGPT again to verify this saved connection. Existing credentials were preserved."
            case .invalidResponse: "ChatGPT sign-in could not be completed. Please try again."
            }
        }
    }

    /// New authorization requires a verified ID token + nonce. Refreshes bind any new
    /// ID token to the saved verified subject; omitted scopes retain only a verified grant.
    public static func session(from data: Data, clientID: String, hostID: String, previous: Session? = nil,
                               nonce: String? = nil, jwks: Data? = nil, now: Date = .now) throws -> Session {
        guard !clientID.isEmpty, !hostID.isEmpty, clientID != "dynamic_agent_client",
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              (json["token_type"] as? String)?.lowercased() == "bearer",
              let lifetimeNumber = json["expires_in"] as? NSNumber, CFGetTypeID(lifetimeNumber) != CFBooleanGetTypeID(),
              case let lifetime = lifetimeNumber.doubleValue, lifetime.isFinite, lifetime > 0 else { throw AuthError.invalidResponse }
        let refreshing = nonce == nil
        if refreshing {
            guard let previous, previous.hasValidatedIdentity, previous.clientID == clientID, previous.hostID == hostID else { throw AuthError.reauthorizationRequired }
        }
        let identity: ChatGPTIdentityValidator.Identity?
        let idToken = json["id_token"] as? String
        guard json["id_token"] == nil || idToken?.isEmpty == false else { throw AuthError.invalidIdentity }
        if let idToken {
            guard let jwks else { throw AuthError.invalidIdentity }
            identity = try ChatGPTIdentityValidator.validate(idToken, jwks: jwks, clientID: clientID, nonce: nonce,
                                                            expectedSubject: previous?.subject, now: now)
        } else {
            guard refreshing else { throw AuthError.invalidIdentity }
            identity = nil
        }
        let scopes: [String]
        if let granted = json["scope"] as? String { scopes = granted.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        else if json["scope"] == nil, refreshing, let retained = previous?.scopes { scopes = retained }
        else { throw AuthError.missingPlanAccess }
        let replacementRefresh = json["refresh_token"] as? String
        if refreshing || scopes.contains("offline_access") {
            guard replacementRefresh?.isEmpty == false else { throw AuthError.invalidResponse }
        }
        // Identity-only consent is retained, but can never supply a plan access token.
        return Session(clientID: clientID, hostID: hostID, accessToken: access,
                       refreshToken: replacementRefresh,
                       expiresAt: now.addingTimeInterval(lifetime),
                       email: identity?.email ?? previous?.email,
                       issuer: identity?.issuer ?? previous?.issuer, subject: identity?.subject ?? previous?.subject,
                       idToken: idToken ?? previous?.idToken, scopes: scopes)
    }

    /// Runtime credential readers share one long-lived managed, no-redirect session.
    public static let runtimeNetworkSession = networkSession()

    public static func networkSession() -> URLSession {
        RuntimeManagedNetworkSession.make(configuration: .ephemeral, delegate: ChatGPTNoRedirects(), delegateQueue: nil)
    }

    /// One fresh HTTPS key-set per token validation also handles unfamiliar/rotated kid.
    /// No token-controlled discovery URL or redirect is followed by the supplied session.
    public static func fetchJWKS(using http: URLSession) async throws -> Data {
        var request = URLRequest(url: ChatGPTIdentityValidator.jwksURL, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == ChatGPTIdentityValidator.jwksURL, data.count <= 262144 else { throw AuthError.invalidIdentity }
        return data
    }

    public static func issuedClientID(callback: String?, selected: String?) throws -> String {
        if let selected {
            guard !selected.isEmpty, selected != "dynamic_agent_client", callback == nil || callback == selected else { throw AuthError.invalidResponse }
            return selected
        }
        guard let callback, !callback.isEmpty, callback != "dynamic_agent_client" else { throw AuthError.invalidResponse }
        return callback
    }

    /// A plan usage limit (HTTP 429 body or a `response.failed` event).
    public static func isPlanLimit(_ text: String) -> Bool {
        text.contains("subscription_sharing_usage_limit_exceeded") || text.contains("usage_limit_reached")
    }

    /// Plan usage temporarily unavailable for this account (not a limit the person reached).
    public static func isPlanUnavailable(_ text: String) -> Bool {
        text.contains("subscription_sharing_usage_unavailable")
    }
}

private final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
