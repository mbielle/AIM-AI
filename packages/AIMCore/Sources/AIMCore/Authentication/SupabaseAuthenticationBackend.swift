import Foundation
import Supabase

public final class SupabaseAuthenticationBackend: AuthenticationBackend, Sendable {
    private let client: SupabaseClient

    public convenience init(
        configuration: AppConfiguration,
        secureStore: any SecureStoring = KeychainSecureStore(),
        redirectPolicy: AuthRedirectPolicy = AuthRedirectPolicy()
    ) throws {
        self.init(client: try Self.makeClient(configuration: configuration, secureStore: secureStore, redirectPolicy: redirectPolicy))
    }

    /// The client this backend uses, for apps that share it with other services
    /// (one session, one token refresh).
    public static func makeClient(
        configuration: AppConfiguration,
        secureStore: any SecureStoring = KeychainSecureStore(),
        redirectPolicy: AuthRedirectPolicy = AuthRedirectPolicy()
    ) throws -> SupabaseClient {
        guard let redirectURL = redirectPolicy.canonicalURL else {
            throw AuthenticationError.invalidCallback
        }
        let client = SupabaseClient(
            supabaseURL: configuration.projectURL,
            supabaseKey: configuration.publicAPIKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: SupabaseAuthLocalStorage(secureStore: secureStore),
                    redirectToURL: redirectURL,
                    storageKey: SupabaseAuthStorageConfiguration.sessionKey,
                    flowType: .pkce,
                    autoRefreshToken: !AIMNetworkPrivacyPolicy.isEnabled,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: AIMManagedNetworkSession.shared)
            )
        )
        AIMNativeRealtime.register(client: client, projectURL: configuration.projectURL, publicKey: configuration.publicAPIKey)
        return client
    }

    /// Shares one client (and its session refresh) with other services of the same app.
    public init(client: SupabaseClient) {
        self.client = client
    }

    public func cachedSession() throws -> AuthenticationBackendSession? {
        client.auth.currentSession.map(map)
    }

    public func refreshSession() async throws -> AuthenticationBackendSession {
        try await translatingErrors {
            map(try await client.auth.session)
        }
    }

    public func signIn(email: String, password: String) async throws -> AuthenticationBackendSession {
        try await translatingErrors {
            map(try await client.auth.signIn(email: email, password: password))
        }
    }

    public func signUp(
        email: String,
        password: String,
        fullName: String,
        redirectTo: URL
    ) async throws -> AuthenticationBackendSignUpResult {
        try await translatingErrors {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["full_name": .string(fullName)],
                redirectTo: redirectTo
            )
            if let session = response.session {
                return .session(map(session))
            }
            return .confirmationRequired(map(response.user))
        }
    }

    public func requestPasswordReset(email: String, redirectTo: URL) async throws {
        try await translatingErrors {
            try await client.auth.resetPasswordForEmail(email, redirectTo: redirectTo)
        }
    }

    public func handleCallback(_ url: URL) async throws -> AuthenticationBackendCallbackResult {
        try await translatingErrors {
            let session = map(try await client.auth.session(from: url))
            if callbackType(in: url) == "recovery" {
                return .passwordRecovery(session)
            }
            return .authenticated(session)
        }
    }

    public func updatePassword(_ password: String) async throws -> AuthenticatedUser {
        try await translatingErrors {
            map(try await client.auth.update(user: UserAttributes(password: password)))
        }
    }

    public func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticationBackendSession {
        try await translatingErrors {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: identityToken,
                    nonce: rawNonce
                )
            )

            guard let fullName, !fullName.isEmpty else {
                return map(session)
            }
            let updatedUser = try await client.auth.update(
                user: UserAttributes(data: ["full_name": .string(fullName)])
            )
            return AuthenticationBackendSession(
                user: map(updatedUser),
                expiresAt: Date(timeIntervalSince1970: session.expiresAt)
            )
        }
    }

    public func oauthAuthorizationURL(
        provider: ExternalAuthenticationProvider,
        redirectTo: URL
    ) throws -> URL {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            switch provider {
            case .google:
                return try client.auth.getOAuthSignInURL(
                    provider: .google,
                    redirectTo: redirectTo
                )
            }
        } catch let error as AuthError {
            throw map(error)
        } catch {
            throw AuthenticationError.unexpected
        }
    }

    public func signOutLocal() async {
        // Supabase purges its local cache before the local-scope request is sent. A network
        // failure must therefore never restore or retain credentials on this device.
        try? await client.auth.signOut(scope: .local)
    }

    public func events() -> AsyncStream<AuthenticationBackendEvent> {
        let authStateChanges = client.auth.authStateChanges
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                for await change in authStateChanges {
                    if let event = map(change.event, session: change.session) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func callbackType(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "type" })?
            .value
    }

    private func map(_ session: Session) -> AuthenticationBackendSession {
        AuthenticationBackendSession(
            user: map(session.user),
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }

    private func map(_ user: User) -> AuthenticatedUser {
        AuthenticatedUser(
            id: user.id,
            email: user.email,
            fullName: user.userMetadata["full_name"]?.stringValue
                ?? user.userMetadata["name"]?.stringValue
        )
    }

    private func map(
        _ event: AuthChangeEvent,
        session: Session?
    ) -> AuthenticationBackendEvent? {
        switch event {
        case .initialSession:
            return .initialSession(session.map(map))
        case .signedIn:
            return session.map { .signedIn(map($0)) }
        case .signedOut, .userDeleted:
            return .signedOut
        case .passwordRecovery:
            return session.map { .passwordRecovery(map($0)) }
        case .tokenRefreshed:
            return session.map { .tokenRefreshed(map($0)) }
        case .userUpdated:
            return session.map { .userUpdated(map($0)) }
        case .mfaChallengeVerified:
            return nil
        }
    }

    private func translatingErrors<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            return try await operation()
        } catch let error as AuthenticationError {
            throw error
        } catch let error as AuthError {
            throw map(error)
        } catch {
            if NetworkErrorClassifier.isConnectivityFailure(error) {
                throw AuthenticationError.networkUnavailable
            }
            throw AuthenticationError.unexpected
        }
    }

    private func map(_ error: AuthError) -> AuthenticationError {
        switch error.errorCode {
        case .invalidCredentials:
            .invalidCredentials
        case .emailNotConfirmed:
            .emailNotConfirmed
        case .emailExists, .userAlreadyExists:
            .emailAlreadyRegistered
        case .weakPassword:
            .weakPassword
        case .sessionExpired, .refreshTokenAlreadyUsed, .refreshTokenNotFound:
            .sessionExpired
        case .sessionNotFound:
            .missingSession
        case .providerDisabled, .emailProviderDisabled:
            .providerUnavailable
        default:
            if case .pkceGrantCodeExchange = error {
                .invalidCallback
            } else {
                .unexpected
            }
        }
    }
}
