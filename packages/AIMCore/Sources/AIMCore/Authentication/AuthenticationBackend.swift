import Foundation

public struct AuthenticationBackendSession: Equatable, Sendable {
    public let user: AuthenticatedUser
    public let expiresAt: Date

    public init(user: AuthenticatedUser, expiresAt: Date) {
        self.user = user
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt <= date
    }
}

public enum AuthenticationBackendSignUpResult: Equatable, Sendable {
    case confirmationRequired(AuthenticatedUser)
    case session(AuthenticationBackendSession)
}

public enum AuthenticationBackendCallbackResult: Equatable, Sendable {
    case authenticated(AuthenticationBackendSession)
    case passwordRecovery(AuthenticationBackendSession)
}

public enum AuthenticationBackendEvent: Equatable, Sendable {
    case initialSession(AuthenticationBackendSession?)
    case signedIn(AuthenticationBackendSession)
    case signedOut
    case passwordRecovery(AuthenticationBackendSession)
    case tokenRefreshed(AuthenticationBackendSession)
    case userUpdated(AuthenticationBackendSession)
}

public enum ExternalAuthenticationProvider: Equatable, Sendable {
    case google
}

public protocol AuthenticationBackend: Sendable {
    func cachedSession() throws -> AuthenticationBackendSession?
    func refreshSession() async throws -> AuthenticationBackendSession
    func signIn(email: String, password: String) async throws -> AuthenticationBackendSession
    func signUp(
        email: String,
        password: String,
        fullName: String,
        redirectTo: URL
    ) async throws -> AuthenticationBackendSignUpResult
    func requestPasswordReset(email: String, redirectTo: URL) async throws
    func handleCallback(_ url: URL) async throws -> AuthenticationBackendCallbackResult
    func updatePassword(_ password: String) async throws -> AuthenticatedUser
    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticationBackendSession
    func oauthAuthorizationURL(
        provider: ExternalAuthenticationProvider,
        redirectTo: URL
    ) throws -> URL
    func signOutLocal() async
    func events() -> AsyncStream<AuthenticationBackendEvent>
}
