import Foundation

public struct AuthenticatedUser: Equatable, Sendable {
    public let id: UUID
    public let email: String?
    public let fullName: String?

    public init(id: UUID, email: String?, fullName: String?) {
        self.id = id
        self.email = email
        self.fullName = fullName
    }
}

public enum AuthenticationState: Equatable, Sendable {
    case restoring
    case signedOut
    case confirmationRequired(email: String)
    case authenticated(AuthenticatedUser)
    case passwordRecovery(AuthenticatedUser)
}

public enum AuthenticationEvent: Equatable, Sendable {
    case initialSession(AuthenticatedUser?)
    case signedIn(AuthenticatedUser)
    case signedOut
    case passwordRecovery(AuthenticatedUser)
    case tokenRefreshed(AuthenticatedUser)
    case userUpdated(AuthenticatedUser)
}

public enum AuthenticationSignUpResult: Equatable, Sendable {
    case confirmationRequired(email: String)
    case authenticated(AuthenticatedUser)
}

public enum AuthenticationError: Error, Equatable, Sendable {
    case invalidCredentials
    case emailNotConfirmed
    case emailAlreadyRegistered
    case weakPassword
    case networkUnavailable
    case invalidCallback
    case sessionExpired
    case missingSession
    case providerUnavailable
    case missingIdentityToken
    case unexpected
}

public protocol AuthenticationServicing: Sendable {
    func restoreSession() async throws -> AuthenticationState
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signUp(email: String, password: String, fullName: String) async throws -> AuthenticationSignUpResult
    func requestPasswordReset(email: String) async throws
    func handleCallback(_ url: URL) async throws -> AuthenticationState
    func updatePassword(_ password: String) async throws -> AuthenticationState
    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticatedUser
    func googleAuthorizationURL() throws -> URL
    func signOut() async
    func events() -> AsyncStream<AuthenticationEvent>
}
