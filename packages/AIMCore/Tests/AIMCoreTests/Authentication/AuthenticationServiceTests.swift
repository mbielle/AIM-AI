import Foundation
import XCTest
@testable import AIMCore

final class AuthenticationServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testRestoresCachedSessionWithoutNetwork() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.cachedSessionResult = .success(makeSession(user: user, expiresAt: now.addingTimeInterval(600)))
        let service = makeService(backend: backend)

        let state = try await service.restoreSession()

        XCTAssertEqual(state, .authenticated(user))
        XCTAssertEqual(backend.refreshSessionCallCount, 0)
    }

    func testMissingCachedSessionRestoresSignedOutState() async throws {
        let backend = FakeAuthenticationBackend()
        backend.cachedSessionResult = .success(nil)

        let state = try await makeService(backend: backend).restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(backend.refreshSessionCallCount, 0)
    }

    func testExpiredSessionIsRefreshed() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.cachedSessionResult = .success(makeSession(user: user, expiresAt: now.addingTimeInterval(-1)))
        backend.refreshSessionResult = .success(makeSession(user: user, expiresAt: now.addingTimeInterval(600)))

        let state = try await makeService(backend: backend).restoreSession()

        XCTAssertEqual(state, .authenticated(user))
        XCTAssertEqual(backend.refreshSessionCallCount, 1)
    }

    func testUnrefreshableExpiredSessionIsPurgedLocally() async throws {
        let backend = FakeAuthenticationBackend()
        backend.cachedSessionResult = .success(makeSession(expiresAt: now.addingTimeInterval(-1)))
        backend.refreshSessionResult = .failure(AuthenticationError.sessionExpired)

        let state = try await makeService(backend: backend).restoreSession()

        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(backend.signOutLocalCallCount, 1)
    }

    func testSignInReturnsUser() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.signInResult = .success(makeSession(user: user))

        let signedInUser = try await makeService(backend: backend).signIn(
            email: "person@example.com",
            password: "correct horse battery staple"
        )

        XCTAssertEqual(signedInUser, user)
        XCTAssertEqual(backend.lastSignInEmail, "person@example.com")
    }

    func testSignInPreservesInvalidCredentialsAndNetworkErrors() async {
        for expectedError in [AuthenticationError.invalidCredentials, .networkUnavailable] {
            let backend = FakeAuthenticationBackend()
            backend.signInResult = .failure(expectedError)

            do {
                _ = try await makeService(backend: backend).signIn(email: "person@example.com", password: "wrong")
                XCTFail("Expected sign-in to fail")
            } catch {
                XCTAssertEqual(error as? AuthenticationError, expectedError)
            }
        }
    }

    func testSignUpPassesFullNameAndCanonicalCallback() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser(email: "new@example.com")
        backend.signUpResult = .success(.confirmationRequired(user))

        let result = try await makeService(backend: backend).signUp(
            email: "new@example.com",
            password: "correct horse battery staple",
            fullName: "Ada Lovelace"
        )

        XCTAssertEqual(result, .confirmationRequired(email: "new@example.com"))
        XCTAssertEqual(backend.lastSignUpFullName, "Ada Lovelace")
        XCTAssertEqual(backend.lastSignUpRedirectURL?.absoluteString, "aim://auth-callback")
    }

    func testSignUpWithImmediateSessionReturnsAuthenticatedState() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.signUpResult = .success(.session(makeSession(user: user)))

        let result = try await makeService(backend: backend).signUp(
            email: "person@example.com",
            password: "correct horse battery staple",
            fullName: "Ada Lovelace"
        )

        XCTAssertEqual(result, .authenticated(user))
    }

    func testPasswordResetUsesCanonicalCallback() async throws {
        let backend = FakeAuthenticationBackend()

        try await makeService(backend: backend).requestPasswordReset(email: "person@example.com")

        XCTAssertEqual(backend.lastPasswordResetEmail, "person@example.com")
        XCTAssertEqual(backend.lastPasswordResetRedirectURL?.absoluteString, "aim://auth-callback")
    }

    func testRecoveryCallbackEntersPasswordRecoveryState() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.callbackResult = .success(.passwordRecovery(makeSession(user: user)))

        let state = try await makeService(backend: backend).handleCallback(
            try XCTUnwrap(URL(string: "aimai://auth-callback?code=test&type=recovery"))
        )

        XCTAssertEqual(state, .passwordRecovery(user))
    }

    func testConfirmationCallbackAuthenticatesUser() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.callbackResult = .success(.authenticated(makeSession(user: user)))

        let state = try await makeService(backend: backend).handleCallback(
            try XCTUnwrap(URL(string: "aim://auth-callback?code=test"))
        )

        XCTAssertEqual(state, .authenticated(user))
    }

    func testUnexpectedCallbackIsRejectedBeforeBackend() async {
        let backend = FakeAuthenticationBackend()

        do {
            _ = try await makeService(backend: backend).handleCallback(
                URL(string: "aim://unexpected?code=test") ?? URL(fileURLWithPath: "/")
            )
            XCTFail("Expected callback rejection")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .invalidCallback)
            XCTAssertEqual(backend.handleCallbackCallCount, 0)
        }
    }

    func testUpdatePasswordReturnsAuthenticatedUser() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.updatePasswordResult = .success(user)

        let state = try await makeService(backend: backend).updatePassword("a new strong password")

        XCTAssertEqual(state, .authenticated(user))
        XCTAssertEqual(backend.lastUpdatedPassword, "a new strong password")
    }

    func testSignOutUsesLocalScope() async {
        let backend = FakeAuthenticationBackend()

        await makeService(backend: backend).signOut()

        XCTAssertEqual(backend.signOutLocalCallCount, 1)
    }

    func testAppleSignInPassesRawNonceTokenAndFirstConsentName() async throws {
        let backend = FakeAuthenticationBackend()
        let user = makeUser()
        backend.appleSignInResult = .success(makeSession(user: user))

        let result = try await makeService(backend: backend).signInWithApple(
            identityToken: "apple.identity.token",
            rawNonce: "raw-nonce",
            fullName: "Ada Lovelace"
        )

        XCTAssertEqual(result, user)
        XCTAssertEqual(backend.lastAppleIdentityToken, "apple.identity.token")
        XCTAssertEqual(backend.lastAppleRawNonce, "raw-nonce")
        XCTAssertEqual(backend.lastAppleFullName, "Ada Lovelace")
    }

    func testGoogleAuthorizationURLUsesCanonicalRedirect() throws {
        let backend = FakeAuthenticationBackend()
        backend.oauthURLResult = .success(
            URL(string: "https://example.supabase.co/auth/v1/authorize?provider=google")
                ?? URL(fileURLWithPath: "/")
        )

        let url = try makeService(backend: backend).googleAuthorizationURL()

        XCTAssertEqual(url.host, "example.supabase.co")
        XCTAssertEqual(backend.lastOAuthProvider, .google)
        XCTAssertEqual(backend.lastOAuthRedirectURL?.absoluteString, "aim://auth-callback")
    }

    func testBackendEventsAreMappedWithoutTokens() async {
        let user = makeUser()
        let backend = FakeAuthenticationBackend()
        backend.queuedEvents = [
            .initialSession(makeSession(user: user)),
            .signedOut,
        ]
        var iterator = makeService(backend: backend).events().makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(first, .initialSession(user))
        XCTAssertEqual(second, .signedOut)
    }

    private func makeService(backend: FakeAuthenticationBackend) -> AuthenticationService {
        let now = now
        return AuthenticationService(backend: backend, now: { now })
    }

    private func makeUser(
        email: String = "person@example.com"
    ) -> AuthenticatedUser {
        AuthenticatedUser(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            email: email,
            fullName: "Ada Lovelace"
        )
    }

    private func makeSession(
        user: AuthenticatedUser? = nil,
        expiresAt: Date? = nil
    ) -> AuthenticationBackendSession {
        AuthenticationBackendSession(
            user: user ?? makeUser(),
            expiresAt: expiresAt ?? now.addingTimeInterval(600)
        )
    }
}

private final class FakeAuthenticationBackend: AuthenticationBackend, @unchecked Sendable {
    var cachedSessionResult: Result<AuthenticationBackendSession?, Error> = .success(nil)
    var refreshSessionResult: Result<AuthenticationBackendSession, Error> = .failure(AuthenticationError.missingSession)
    var signInResult: Result<AuthenticationBackendSession, Error> = .failure(AuthenticationError.unexpected)
    var signUpResult: Result<AuthenticationBackendSignUpResult, Error> = .failure(AuthenticationError.unexpected)
    var callbackResult: Result<AuthenticationBackendCallbackResult, Error> = .failure(AuthenticationError.invalidCallback)
    var updatePasswordResult: Result<AuthenticatedUser, Error> = .failure(AuthenticationError.unexpected)
    var appleSignInResult: Result<AuthenticationBackendSession, Error> = .failure(AuthenticationError.unexpected)
    var oauthURLResult: Result<URL, Error> = .failure(AuthenticationError.unexpected)
    var queuedEvents: [AuthenticationBackendEvent] = []

    private(set) var refreshSessionCallCount = 0
    private(set) var signOutLocalCallCount = 0
    private(set) var handleCallbackCallCount = 0
    private(set) var lastSignInEmail: String?
    private(set) var lastSignUpFullName: String?
    private(set) var lastSignUpRedirectURL: URL?
    private(set) var lastPasswordResetEmail: String?
    private(set) var lastPasswordResetRedirectURL: URL?
    private(set) var lastUpdatedPassword: String?
    private(set) var lastAppleIdentityToken: String?
    private(set) var lastAppleRawNonce: String?
    private(set) var lastAppleFullName: String?
    private(set) var lastOAuthProvider: ExternalAuthenticationProvider?
    private(set) var lastOAuthRedirectURL: URL?

    func cachedSession() throws -> AuthenticationBackendSession? {
        try cachedSessionResult.get()
    }

    func refreshSession() async throws -> AuthenticationBackendSession {
        refreshSessionCallCount += 1
        return try refreshSessionResult.get()
    }

    func signIn(email: String, password _: String) async throws -> AuthenticationBackendSession {
        lastSignInEmail = email
        return try signInResult.get()
    }

    func signUp(
        email _: String,
        password _: String,
        fullName: String,
        redirectTo: URL
    ) async throws -> AuthenticationBackendSignUpResult {
        lastSignUpFullName = fullName
        lastSignUpRedirectURL = redirectTo
        return try signUpResult.get()
    }

    func requestPasswordReset(email: String, redirectTo: URL) async throws {
        lastPasswordResetEmail = email
        lastPasswordResetRedirectURL = redirectTo
    }

    func handleCallback(_ url: URL) async throws -> AuthenticationBackendCallbackResult {
        handleCallbackCallCount += 1
        return try callbackResult.get()
    }

    func updatePassword(_ password: String) async throws -> AuthenticatedUser {
        lastUpdatedPassword = password
        return try updatePasswordResult.get()
    }

    func signOutLocal() async {
        signOutLocalCallCount += 1
    }

    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticationBackendSession {
        lastAppleIdentityToken = identityToken
        lastAppleRawNonce = rawNonce
        lastAppleFullName = fullName
        return try appleSignInResult.get()
    }

    func oauthAuthorizationURL(
        provider: ExternalAuthenticationProvider,
        redirectTo: URL
    ) throws -> URL {
        lastOAuthProvider = provider
        lastOAuthRedirectURL = redirectTo
        return try oauthURLResult.get()
    }

    func events() -> AsyncStream<AuthenticationBackendEvent> {
        let queuedEvents = queuedEvents
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            for event in queuedEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
