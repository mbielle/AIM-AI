@testable import AIMAgentRuntime
import AIMCore
import AIMApplication
import AIMMacPlatform
@testable import AIMMac
import XCTest

@MainActor
final class MacAccountControllerTests: XCTestCase {
    func testUnconfiguredBuildKeepsLocalModeAndRejectsForeignCallback() async {
        let account = MacAccountController(infoDictionary: [:], secureStoreOverride: ConfigurationAccountSecrets())
        XCTAssertFalse(account.isConfigured)
        await account.start()
        XCTAssertEqual(account.state, .signedOut)
        await account.handleCallback(URL(string: "aim://auth-callback?code=other-device")!)
        XCTAssertEqual(account.state, .signedOut)
    }

    func testLocalIdentityPersistsAcrossRecreationAndSignOutWithoutAuthenticatingIt() async throws {
        let store = ProfileSecrets()
        let first = MacAccountController(infoDictionary: [:], secureStoreOverride: store)
        let id = try XCTUnwrap(first.identity?.storageID)
        XCTAssertTrue(first.identity?.isLocal == true)
        XCTAssertNil(first.accessUser)
        let accountUser = AuthenticatedUser(id: UUID(), email: nil, fullName: nil)
        let signed = MacAccountController(service: AccountServiceStub(user: accountUser), localProfileStore: store)
        await signed.signIn(email: "fixture@example.test", password: "fixture")
        XCTAssertEqual(signed.identity?.authenticatedUser, accountUser)
        await signed.signOut()
        XCTAssertEqual(signed.identity?.storageID, id)
        XCTAssertNil(signed.accessUser)
        XCTAssertTrue(signed.identity?.isLocal == true)
        let reopened = MacAccountController(infoDictionary: [:], secureStoreOverride: store)
        XCTAssertEqual(reopened.identity?.storageID, id)
    }

    func testLocalHistoryCopyCoordinatorRequiresAnAccountAndFencesSignOut() async throws {
        let store = ProfileSecrets(), user = AuthenticatedUser(id: UUID(), email: nil, fullName: nil)
        let account = MacAccountController(service: AccountServiceStub(user: user), localProfileStore: store)
        let model = AppModel(database: try AIMDatabase(inMemory: true), account: account)
        do { _ = try await model.localHistoryCopy.preview(); XCTFail("Local mode cannot target an unauthenticated account") }
        catch AccountServiceError.revoked {}
        await account.signIn(email: "fixture@example.test", password: "fixture")
        let preview = try await model.localHistoryCopy.preview()
        XCTAssertEqual(preview.accountID, user.id)
        await account.signOut()
        do { _ = try await model.localHistoryCopy.copy(preview, selectedIDs: []); XCTFail("Sign-out invalidates the coordinator's reviewed destination") }
        catch AccountServiceError.revoked {}
        _ = await model.prepareForTermination()
    }

    func testProfileCredentialsAndDelayedOAuthWritesAreFencedAcrossAccountChanges() async throws {
        let profiles = ProfileSecrets(), credentials = ProfileSecrets()
        let first = AuthenticatedUser(id: UUID(), email: nil, fullName: nil)
        let second = AuthenticatedUser(id: UUID(), email: nil, fullName: nil)
        let account = MacAccountController(service: AccountServiceStub(user: first, alternateUser: second), localProfileStore: profiles)
        let model = AppModel(database: try AIMDatabase(inMemory: true), account: account, providerStore: credentials)
        try model.saveProviderKey("local-fixture", provider: .openAI)
        let local = model.scopedProviderCredentials()
        await account.signIn(email: "first@example.invalid", password: "fixture")
        XCTAssertNil(try model.scopedProviderCredentials().readData(forKey: ChatProvider.openAI.rawValue))
        try model.saveProviderKey("first-fixture", provider: .openAI)
        let firstScope = model.captureCredentialScope()
        await account.signIn(email: "second@example.invalid", password: "fixture")
        XCTAssertEqual(account.identity?.storageID, second.id)
        XCTAssertNil(try model.scopedProviderCredentials().readData(forKey: ChatProvider.openAI.rawValue))
        XCTAssertThrowsError(try model.saveProviderKey("delayed-first", provider: .openAI, expectedScope: firstScope))
        try model.saveProviderKey("second-fixture", provider: .openAI)
        XCTAssertEqual(try model.scopedProviderCredentials().readData(forKey: ChatProvider.openAI.rawValue), Data("second-fixture".utf8))
        await account.signOut()
        XCTAssertEqual(try model.scopedProviderCredentials().readData(forKey: ChatProvider.openAI.rawValue), Data("local-fixture".utf8))
        XCTAssertThrowsError(try local.readData(forKey: ChatProvider.openAI.rawValue), "Returning to local mode does not revive a stale operation")
        _ = await model.prepareForTermination()
    }

    func testPublicBuildConfigurationEnablesAccountWithoutIOSCallback() {
        let account = MacAccountController(infoDictionary: [
            "AIMSupabaseURL": "https://example.supabase.co",
            "AIMSupabasePublicKey": "sb_publishable_test",
        ], secureStoreOverride: ConfigurationAccountSecrets())
        XCTAssertTrue(account.isConfigured)
        XCTAssertEqual(account.state, .signedOut)
    }

    func testSignInAndLocalSignOut() async {
        let user = AuthenticatedUser(id: UUID(), email: "mac@example.com", fullName: "Mac User")
        let service = AccountServiceStub(user: user)
        let account = MacAccountController(service: service, localProfileStore: ConfigurationAccountSecrets())
        await account.start()
        XCTAssertEqual(account.state, .signedOut)
        await account.signIn(email: "mac@example.com", password: "example")
        XCTAssertEqual(account.state, .authenticated(user))
        await account.signOut()
        XCTAssertEqual(account.state, .signedOut)
        let count = await service.signOutCount()
        XCTAssertEqual(count, 1)
    }

    func testEmailConfirmationAndMacOnlyCallback() async {
        let user = AuthenticatedUser(id: UUID(), email: "mac@example.com", fullName: nil)
        let service = AccountServiceStub(user: user)
        let account = MacAccountController(service: service, localProfileStore: ConfigurationAccountSecrets())
        await account.start()
        await account.signUp(email: "mac@example.com", password: "example", fullName: "")
        XCTAssertEqual(account.state, .confirmationRequired(email: "mac@example.com"))
        await account.handleCallback(URL(string: "aim://auth-callback?code=ios")!)
        XCTAssertEqual(account.state, .confirmationRequired(email: "mac@example.com"))
        await account.handleCallback(URL(string: "aimmac://auth-callback?code=mac")!)
        XCTAssertEqual(account.state, .authenticated(user))
        await account.handleCallback(URL(string: "aimmac://auth-callback?code=mac")!)
        let callbacks = await service.callbackCount()
        XCTAssertEqual(callbacks, 1)
        account.dismissConfirmation()
        XCTAssertEqual(account.state, .authenticated(user))
    }

    func testGoogleUsesMacSystemBrowserCallbackOnce() async {
        let user = AuthenticatedUser(id: UUID(), email: "google@example.com", fullName: nil)
        let service = AccountServiceStub(user: user)
        let browser = WebAuthenticatorStub(callback: URL(string: "aimmac://auth-callback?code=google")!)
        let account = MacAccountController(service: service, webAuthenticator: browser, localProfileStore: ConfigurationAccountSecrets())
        await account.start()
        await account.signInWithGoogle()
        XCTAssertEqual(browser.receivedScheme, "aimmac")
        XCTAssertEqual(browser.receivedURL?.absoluteString, "https://example.com")
        XCTAssertEqual(account.state, .authenticated(user))
        await account.handleCallback(URL(string: "aimmac://auth-callback?code=google")!)
        let callbacks = await service.callbackCount()
        XCTAssertEqual(callbacks, 1)
    }

    func testGoogleRejectsWrongCallbackHost() async {
        let service = AccountServiceStub(user: AuthenticatedUser(id: UUID(), email: nil, fullName: nil))
        let browser = WebAuthenticatorStub(callback: URL(string: "aimmac://untrusted?code=google")!)
        let account = MacAccountController(service: service, webAuthenticator: browser, localProfileStore: ConfigurationAccountSecrets())
        await account.start()
        await account.signInWithGoogle()
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertEqual(account.message, "This sign-in link is invalid or belongs to another device.")
        let callbacks = await service.callbackCount()
        XCTAssertEqual(callbacks, 0)
    }
}

private struct ConfigurationAccountSecrets: SecureStoring {
    func readData(forKey key: String) throws -> Data? { nil }
    func store(_ data: Data, forKey key: String) throws {}
    func removeData(forKey key: String) throws {}
}

@MainActor
private final class WebAuthenticatorStub: MacWebAuthenticating {
    let callback: URL
    private(set) var receivedURL: URL?
    private(set) var receivedScheme: String?
    init(callback: URL) { self.callback = callback }
    func authenticate(at url: URL, callbackScheme: String) async throws -> URL {
        receivedURL = url
        receivedScheme = callbackScheme
        return callback
    }
}

private actor SignOutRecorder {
    private var signOuts = 0
    private var callbacks = 0
    func recordSignOut() { signOuts += 1 }
    func recordCallback() { callbacks += 1 }
    func signOutCount() -> Int { signOuts }
    func callbackCount() -> Int { callbacks }
}

private struct AccountServiceStub: AuthenticationServicing {
    let user: AuthenticatedUser
    let alternateUser: AuthenticatedUser?
    private let recorder = SignOutRecorder()
    init(user: AuthenticatedUser, alternateUser: AuthenticatedUser? = nil) { self.user = user; self.alternateUser = alternateUser }
    func signOutCount() async -> Int { await recorder.signOutCount() }
    func callbackCount() async -> Int { await recorder.callbackCount() }
    func restoreSession() async throws -> AuthenticationState { .signedOut }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser { email.hasPrefix("second@") ? alternateUser ?? user : user }
    func signUp(email: String, password: String, fullName: String) async throws -> AuthenticationSignUpResult { .confirmationRequired(email: email) }
    func requestPasswordReset(email: String) async throws {}
    func handleCallback(_ url: URL) async throws -> AuthenticationState {
        await recorder.recordCallback()
        return .authenticated(user)
    }
    func updatePassword(_ password: String) async throws -> AuthenticationState { .authenticated(user) }
    func signInWithApple(identityToken: String, rawNonce: String, fullName: String?) async throws -> AuthenticatedUser { user }
    func googleAuthorizationURL() throws -> URL { URL(string: "https://example.com")! }
    func signOut() async { await recorder.recordSignOut() }
    func events() -> AsyncStream<AuthenticationEvent> { AsyncStream { _ in } }
}


private final class ProfileSecrets: SecureStoring, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { values[key] }
    func store(_ data: Data, forKey key: String) throws { values[key] = data }
    func removeData(forKey key: String) throws { values[key] = nil }
}
