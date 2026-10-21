import AIMCore
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private(set) var state: AuthenticationState = .signedOut
    private(set) var isLoading = false
    private(set) var error: AuthenticationError?

    private let service: any AuthenticationServicing
    private let webAuthenticator: any WebAuthenticationServicing
    private let callbackDeduplicator: AuthenticationCallbackDeduplicator
    private let nonce: @Sendable () throws -> String
    private var pendingAppleNonce: String?
    private var eventTask: Task<Void, Never>?

    init(
        service: any AuthenticationServicing,
        webAuthenticator: any WebAuthenticationServicing = ASWebAuthenticationSessionClient(),
        callbackDeduplicator: AuthenticationCallbackDeduplicator = AuthenticationCallbackDeduplicator(),
        nonce: @escaping @Sendable () throws -> String = { try SecureNonceGenerator().generate() }
    ) {
        self.service = service
        self.webAuthenticator = webAuthenticator
        self.callbackDeduplicator = callbackDeduplicator
        self.nonce = nonce
    }

    func start() async {
        startObservingEventsIfNeeded()
        await restore()
    }

    func restore() async {
        state = .restoring
        isLoading = true
        error = nil
        do {
            state = try await service.restoreSession()
        } catch let authenticationError as AuthenticationError {
            state = .signedOut
            error = authenticationError
        } catch {
            state = .signedOut
            self.error = .unexpected
        }
        isLoading = false
    }

    func recoverForProtectedOperation() async -> Bool {
        await restore()
        if case .authenticated = state { return true }
        return false
    }

    func signIn(email: String, password: String) async {
        await perform {
            state = .authenticated(try await service.signIn(email: email, password: password))
        }
    }

    func signUp(email: String, password: String, fullName: String) async {
        await perform {
            let result = try await service.signUp(
                email: email,
                password: password,
                fullName: fullName
            )
            switch result {
            case let .authenticated(user):
                state = .authenticated(user)
            case let .confirmationRequired(email):
                state = .confirmationRequired(email: email)
            }
        }
    }

    func requestPasswordReset(email: String) async -> Bool {
        var succeeded = false
        await perform {
            try await service.requestPasswordReset(email: email)
            succeeded = true
        }
        return succeeded
    }

    func updatePassword(_ password: String) async {
        await perform {
            state = try await service.updatePassword(password)
        }
    }

    func beginAppleSignIn() -> String? {
        do {
            let rawNonce = try nonce()
            pendingAppleNonce = rawNonce
            error = nil
            return SecureNonceGenerator.sha256(rawNonce)
        } catch {
            self.error = .unexpected
            return nil
        }
    }

    func completeAppleSignIn(identityToken: Data?, fullName: String?) async {
        guard
            let rawNonce = pendingAppleNonce,
            let identityToken,
            let token = String(data: identityToken, encoding: .utf8),
            !token.isEmpty
        else {
            pendingAppleNonce = nil
            error = .missingIdentityToken
            return
        }
        pendingAppleNonce = nil

        await perform {
            state = .authenticated(
                try await service.signInWithApple(
                    identityToken: token,
                    rawNonce: rawNonce,
                    fullName: fullName
                )
            )
        }
    }

    func cancelAppleSignIn() {
        pendingAppleNonce = nil
        error = nil
    }

    func failAppleSignIn() {
        pendingAppleNonce = nil
        error = .providerUnavailable
    }

    func signInWithGoogle() async {
        do {
            isLoading = true
            error = nil
            let authorizationURL = try service.googleAuthorizationURL()
            let callbackURL = try await webAuthenticator.authenticate(
                at: authorizationURL,
                callbackScheme: "aim",
                prefersEphemeralSession: false
            )
            isLoading = false
            await handleOpenURL(callbackURL)
        } catch WebAuthenticationError.cancelled {
            isLoading = false
            error = nil
        } catch WebAuthenticationError.couldNotStart {
            isLoading = false
            error = .providerUnavailable
        } catch WebAuthenticationError.missingCallback {
            isLoading = false
            error = .invalidCallback
        } catch let authenticationError as AuthenticationError {
            isLoading = false
            error = authenticationError
        } catch {
            isLoading = false
            self.error = .unexpected
        }
    }

    func handleOpenURL(_ url: URL) async {
        guard await callbackDeduplicator.claim(url) else {
            return
        }

        do {
            isLoading = true
            error = nil
            state = try await service.handleCallback(url)
            isLoading = false
        } catch let authenticationError as AuthenticationError {
            await callbackDeduplicator.release(url)
            isLoading = false
            error = authenticationError
        } catch {
            await callbackDeduplicator.release(url)
            isLoading = false
            self.error = .unexpected
        }
    }

    func signOut() async {
        isLoading = true
        error = nil
        await service.signOut()
        state = .signedOut
        isLoading = false
    }

    func clearError() {
        error = nil
    }

    private func startObservingEventsIfNeeded() {
        guard eventTask == nil else { return }
        let events = service.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: AuthenticationEvent) {
        switch event {
        case .initialSession:
            // restore() is the single source of truth at launch: it validates
            // expiration and refreshes when needed. The SDK's initial event can
            // contain an expired cached session and must not overwrite that result.
            return
        case let .signedIn(user), let .tokenRefreshed(user), let .userUpdated(user):
            state = .authenticated(user)
        case .signedOut:
            state = .signedOut
        case let .passwordRecovery(user):
            state = .passwordRecovery(user)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isLoading = true
        error = nil
        do {
            try await operation()
        } catch let authenticationError as AuthenticationError {
            error = authenticationError
        } catch {
            self.error = .unexpected
        }
        isLoading = false
    }
}
