import Foundation

public struct AuthenticationService: AuthenticationServicing, Sendable {
    private let backend: any AuthenticationBackend
    private let redirectPolicy: AuthRedirectPolicy
    private let now: @Sendable () -> Date

    public init(
        backend: any AuthenticationBackend,
        redirectPolicy: AuthRedirectPolicy = AuthRedirectPolicy(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.backend = backend
        self.redirectPolicy = redirectPolicy
        self.now = now
    }

    public func restoreSession() async throws -> AuthenticationState {
        let cachedSession = try mapErrors { try backend.cachedSession() }
        guard let cachedSession else {
            return .signedOut
        }
        guard !AIMNetworkPrivacyPolicy.isEnabled, cachedSession.isExpired(at: now()) else {
            return .authenticated(cachedSession.user)
        }

        do {
            let refreshedSession = try await mapErrors { try await backend.refreshSession() }
            return .authenticated(refreshedSession.user)
        } catch AuthenticationError.sessionExpired, AuthenticationError.missingSession {
            await backend.signOutLocal()
            return .signedOut
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await mapErrors {
            try await backend.signIn(email: email, password: password).user
        }
    }

    public func signUp(
        email: String,
        password: String,
        fullName: String
    ) async throws -> AuthenticationSignUpResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let redirectURL = try canonicalRedirectURL()
        let result = try await mapErrors {
            try await backend.signUp(
                email: email,
                password: password,
                fullName: fullName,
                redirectTo: redirectURL
            )
        }

        switch result {
        case let .confirmationRequired(user):
            return .confirmationRequired(email: user.email ?? email)
        case let .session(session):
            return .authenticated(session.user)
        }
    }

    public func requestPasswordReset(email: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let redirectURL = try canonicalRedirectURL()
        try await mapErrors {
            try await backend.requestPasswordReset(email: email, redirectTo: redirectURL)
        }
    }

    public func handleCallback(_ url: URL) async throws -> AuthenticationState {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard redirectPolicy.accepts(url) else {
            throw AuthenticationError.invalidCallback
        }
        let result = try await mapErrors { try await backend.handleCallback(url) }
        switch result {
        case let .authenticated(session):
            return .authenticated(session.user)
        case let .passwordRecovery(session):
            return .passwordRecovery(session.user)
        }
    }

    public func updatePassword(_ password: String) async throws -> AuthenticationState {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let user = try await mapErrors { try await backend.updatePassword(password) }
        return .authenticated(user)
    }

    public func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticatedUser {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await mapErrors {
            try await backend.signInWithApple(
                identityToken: identityToken,
                rawNonce: rawNonce,
                fullName: fullName
            ).user
        }
    }

    public func googleAuthorizationURL() throws -> URL {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let redirectURL = try canonicalRedirectURL()
        return try mapErrors {
            try backend.oauthAuthorizationURL(provider: .google, redirectTo: redirectURL)
        }
    }

    public func signOut() async {
        await backend.signOutLocal()
    }

    public func events() -> AsyncStream<AuthenticationEvent> {
        let backendEvents = backend.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in backendEvents {
                    continuation.yield(map(event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func canonicalRedirectURL() throws -> URL {
        guard let url = redirectPolicy.canonicalURL else {
            throw AuthenticationError.invalidCallback
        }
        return url
    }

    private func map(_ event: AuthenticationBackendEvent) -> AuthenticationEvent {
        switch event {
        case let .initialSession(session): .initialSession(session?.user)
        case let .signedIn(session): .signedIn(session.user)
        case .signedOut: .signedOut
        case let .passwordRecovery(session): .passwordRecovery(session.user)
        case let .tokenRefreshed(session): .tokenRefreshed(session.user)
        case let .userUpdated(session): .userUpdated(session.user)
        }
    }

    private func mapErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw AuthenticationError.unexpected
        }
    }

    private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw AuthenticationError.unexpected
        }
    }
}
