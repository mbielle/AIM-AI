import AIMCore
import AuthenticationServices
import Foundation
import XCTest
@testable import AIM

final class SessionStoreTests: XCTestCase {
    @MainActor
    func testWebAuthenticationKeepsCancellationDistinctFromPresentationFailure() {
        let cancelled = NSError(domain: ASWebAuthenticationSessionError.errorDomain, code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)
        let presentation = NSError(domain: ASWebAuthenticationSessionError.errorDomain, code: ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue)
        XCTAssertThrowsError(try ASWebAuthenticationSessionClient.authenticationResult(callback: nil, error: cancelled).get()) {
            XCTAssertEqual($0 as? WebAuthenticationError, .cancelled)
        }
        XCTAssertThrowsError(try ASWebAuthenticationSessionClient.authenticationResult(callback: nil, error: presentation).get()) {
            XCTAssertEqual($0 as? WebAuthenticationError, .couldNotStart)
        }
    }

    @MainActor
    func testWebAuthenticationRejectsMissingCallbackAndDoesNotAcceptCallbackWithError() throws {
        XCTAssertThrowsError(try ASWebAuthenticationSessionClient.authenticationResult(callback: nil, error: nil).get()) {
            XCTAssertEqual($0 as? WebAuthenticationError, .missingCallback)
        }
        let callback = try XCTUnwrap(URL(string: "https://aim-ai.tech/auth/openrouter/ios?code=example"))
        XCTAssertEqual(try ASWebAuthenticationSessionClient.authenticationResult(callback: callback, error: nil).get(), callback)
        XCTAssertThrowsError(try ASWebAuthenticationSessionClient.authenticationResult(callback: callback, error: URLError(.timedOut)).get()) {
            XCTAssertEqual($0 as? WebAuthenticationError, .couldNotStart)
        }
    }

    @MainActor
    func testRestoreTransitionsFromLoadingToSignedOut() async {
        let service = MockAuthenticationService()
        service.restoreResult = .success(.signedOut)
        let store = SessionStore(service: service)

        await store.restore()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testFailedRestoreCannotLeaveAnAuthenticatedLookingSession() async {
        let service = MockAuthenticationService()
        service.restoreResult = .failure(AuthenticationError.missingSession)
        let store = SessionStore(service: service)

        await store.restore()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.error, .missingSession)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testSignInTransitionsToAuthenticated() async {
        let service = MockAuthenticationService()
        let user = makeUser()
        service.signInResult = .success(user)
        let store = SessionStore(service: service)

        await store.signIn(email: "person@example.com", password: "password")

        XCTAssertEqual(store.state, .authenticated(user))
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testErrorStopsLoadingAndRemainsPresentable() async {
        let service = MockAuthenticationService()
        service.signInResult = .failure(AuthenticationError.invalidCredentials)
        let store = SessionStore(service: service)

        await store.signIn(email: "person@example.com", password: "wrong")

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.error, .invalidCredentials)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testMissingAppleTokenIsReportedWithoutCallingService() async {
        let service = MockAuthenticationService()
        let store = SessionStore(service: service, nonce: { "raw-nonce" })
        XCTAssertNotNil(store.beginAppleSignIn())

        await store.completeAppleSignIn(identityToken: nil, fullName: "Ada Lovelace")

        XCTAssertEqual(store.error, .missingIdentityToken)
        XCTAssertEqual(service.appleSignInCallCount, 0)
    }

    @MainActor
    func testAppleSuccessUsesRawNonceAndCancellationIsSilent() async {
        let service = MockAuthenticationService()
        let user = makeUser()
        service.appleSignInResult = .success(user)
        let store = SessionStore(service: service, nonce: { "raw-nonce" })

        XCTAssertEqual(
            store.beginAppleSignIn(),
            "2c5d107938053a2275f022c153c9a71f65ee07754b8bca543ee97a0c3cc66990"
        )
        await store.completeAppleSignIn(
            identityToken: Data("identity-token".utf8),
            fullName: "Ada Lovelace"
        )
        store.cancelAppleSignIn()

        XCTAssertEqual(store.state, .authenticated(user))
        XCTAssertNil(store.error)
        XCTAssertEqual(service.lastAppleRawNonce, "raw-nonce")
    }

    @MainActor
    func testDuplicateWarmAndColdCallbackRunsOnce() async throws {
        let service = MockAuthenticationService()
        service.callbackResult = .success(.authenticated(makeUser()))
        let store = SessionStore(service: service)
        let url = try XCTUnwrap(URL(string: "aim://auth-callback?code=once"))

        await store.handleOpenURL(url)
        await store.handleOpenURL(url)

        XCTAssertEqual(service.callbackCallCount, 1)
    }

    @MainActor
    func testGoogleUsesNonEphemeralWebAuthenticatorAndCallback() async throws {
        let service = MockAuthenticationService()
        service.googleURLResult = .success(
            try XCTUnwrap(URL(string: "https://example.supabase.co/authorize?provider=google"))
        )
        service.callbackResult = .success(.authenticated(makeUser()))
        let webAuthenticator = MockWebAuthenticator()
        webAuthenticator.result = .success(
            try XCTUnwrap(URL(string: "aim://auth-callback?code=google"))
        )
        let store = SessionStore(service: service, webAuthenticator: webAuthenticator)

        await store.signInWithGoogle()

        XCTAssertEqual(webAuthenticator.lastCallbackScheme, "aim")
        XCTAssertFalse(webAuthenticator.usedEphemeralSession)
        XCTAssertEqual(service.callbackCallCount, 1)
    }

    @MainActor
    func testGooglePresentationFailureIsReportedAsProviderUnavailable() async throws {
        let service = MockAuthenticationService()
        service.googleURLResult = .success(
            try XCTUnwrap(URL(string: "https://example.supabase.co/authorize?provider=google"))
        )
        let webAuthenticator = MockWebAuthenticator()
        webAuthenticator.result = .failure(WebAuthenticationError.couldNotStart)
        let store = SessionStore(service: service, webAuthenticator: webAuthenticator)

        await store.signInWithGoogle()

        XCTAssertEqual(store.error, .providerUnavailable)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testAppleSystemFailureIsReportedAsProviderUnavailable() {
        let store = SessionStore(service: MockAuthenticationService(), nonce: { "raw-nonce" })
        XCTAssertNotNil(store.beginAppleSignIn())

        store.failAppleSignIn()

        XCTAssertEqual(store.error, .providerUnavailable)
    }

    private func makeUser() -> AuthenticatedUser {
        AuthenticatedUser(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            email: "person@example.com",
            fullName: "Ada Lovelace"
        )
    }
}

private final class MockAuthenticationService: AuthenticationServicing, @unchecked Sendable {
    var restoreResult: Result<AuthenticationState, Error> = .success(.signedOut)
    var signInResult: Result<AuthenticatedUser, Error> = .failure(AuthenticationError.unexpected)
    var signUpResult: Result<AuthenticationSignUpResult, Error> = .failure(AuthenticationError.unexpected)
    var callbackResult: Result<AuthenticationState, Error> = .failure(AuthenticationError.invalidCallback)
    var updatePasswordResult: Result<AuthenticationState, Error> = .failure(AuthenticationError.unexpected)
    var appleSignInResult: Result<AuthenticatedUser, Error> = .failure(AuthenticationError.unexpected)
    var googleURLResult: Result<URL, Error> = .failure(AuthenticationError.unexpected)

    private(set) var appleSignInCallCount = 0
    private(set) var callbackCallCount = 0
    private(set) var lastAppleRawNonce: String?

    func restoreSession() async throws -> AuthenticationState { try restoreResult.get() }

    func signIn(email _: String, password _: String) async throws -> AuthenticatedUser {
        try signInResult.get()
    }

    func signUp(
        email _: String,
        password _: String,
        fullName _: String
    ) async throws -> AuthenticationSignUpResult {
        try signUpResult.get()
    }

    func requestPasswordReset(email _: String) async throws {}

    func handleCallback(_ url: URL) async throws -> AuthenticationState {
        callbackCallCount += 1
        return try callbackResult.get()
    }

    func updatePassword(_ password: String) async throws -> AuthenticationState {
        try updatePasswordResult.get()
    }

    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticatedUser {
        appleSignInCallCount += 1
        lastAppleRawNonce = rawNonce
        return try appleSignInResult.get()
    }

    func googleAuthorizationURL() throws -> URL { try googleURLResult.get() }
    func signOut() async {}

    func events() -> AsyncStream<AuthenticationEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.finish()
        }
    }
}

@MainActor
private final class MockWebAuthenticator: WebAuthenticationServicing {
    var result: Result<URL, Error> = .failure(WebAuthenticationError.cancelled)
    private(set) var lastCallbackScheme: String?
    private(set) var usedEphemeralSession = true

    func authenticate(
        at url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        lastCallbackScheme = callbackScheme
        usedEphemeralSession = prefersEphemeralSession
        return try result.get()
    }
}
