@testable import AIMAgentRuntime
import AIMCore
@testable import AIMMac
import Foundation
import XCTest

@MainActor
final class AccountAccessTests: XCTestCase {
    private let user = AuthenticatedUser(id: UUID(), email: "mac@example.com", fullName: "Mac User")

    func testLocalProfileUnlocksTheAppWithoutBackendOrFakeAccount() throws {
        let profile = try LocalProfile.loadOrCreate(store: MemoryStore())
        XCTAssertEqual(AccountAccessPolicy.access(identity: .local(profile), offline: false), .granted(nil, offline: false))
        XCTAssertEqual(AccountAccessPolicy.access(identity: .account(user), offline: false), .granted(user, offline: false))
        XCTAssertEqual(AccountAccessPolicy.access(identity: nil, offline: false), .notConfigured)
    }

    func testOfflineGraceLastsSevenDays() {
        let verified = Date(timeIntervalSince1970: 1_000_000)
        let record = VerifiedAccount(id: user.id, email: user.email, fullName: user.fullName, verifiedAt: verified)
        XCTAssertEqual(AccountAccessPolicy.offlineUser(record, now: verified.addingTimeInterval(6 * 86_400)), user)
        XCTAssertNil(AccountAccessPolicy.offlineUser(record, now: verified.addingTimeInterval(7 * 86_400 + 1)))
        XCTAssertNil(AccountAccessPolicy.offlineUser(record, now: verified.addingTimeInterval(-60)), "a clock set backwards does not extend it")
        XCTAssertNil(AccountAccessPolicy.offlineUser(nil, now: verified))
        XCTAssertEqual(AccountAccessPolicy.access(identity: .account(user), offline: true),
                       .granted(user, offline: true))
    }

    func testOfflineRestoreUsesRecentlyVerifiedAccountAndSignOutForgetsIt() async {
        let store = MemoryStore()
        var now = Date(timeIntervalSince1970: 2_000_000)
        let service = OfflineServiceStub(user: user)
        let account = MacAccountController(service: service, verifiedStore: store, now: { now }, localProfileStore: store)
        var published: [UUID?] = []
        account.onAccessChange = { published.append($0?.id) }

        await account.signIn(email: "mac@example.com", password: "secret")
        XCTAssertEqual(account.accessUser, user)
        XCTAssertNotNil(VerifiedAccount.read(from: store))

        now = now.addingTimeInterval(3 * 86_400)
        let offline = MacAccountController(service: service, verifiedStore: store, now: { now }, localProfileStore: store)
        await offline.start()
        XCTAssertEqual(offline.state, .signedOut)
        XCTAssertEqual(offline.offlineUser, user)
        XCTAssertEqual(AccountAccessPolicy.access(identity: offline.identity, offline: offline.offlineUser != nil),
                       .granted(user, offline: true))

        await offline.signOut()
        XCTAssertNil(offline.accessUser)
        XCTAssertNil(VerifiedAccount.read(from: store))
        XCTAssertEqual(published, [user.id])
    }

    func testOfflineRestoreAfterGraceRequiresSignIn() async {
        let store = MemoryStore()
        VerifiedAccount.write(user, at: Date(timeIntervalSince1970: 0), to: store)
        let account = MacAccountController(service: OfflineServiceStub(user: user), verifiedStore: store,
                                           now: { Date(timeIntervalSince1970: 8 * 86_400) }, localProfileStore: store)
        await account.start()
        XCTAssertNil(account.accessUser)
        XCTAssertNotNil(account.message)
    }
}

private final class MemoryStore: SecureStoring, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { values[key] = data }
    func readData(forKey key: String) throws -> Data? { values[key] }
    func removeData(forKey key: String) throws { values[key] = nil }
}

/// Restoring fails as it does with no network and an expired token.
private struct OfflineServiceStub: AuthenticationServicing {
    let user: AuthenticatedUser
    func restoreSession() async throws -> AuthenticationState { throw AuthenticationError.networkUnavailable }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser { user }
    func signUp(email: String, password: String, fullName: String) async throws -> AuthenticationSignUpResult { .authenticated(user) }
    func requestPasswordReset(email: String) async throws {}
    func handleCallback(_ url: URL) async throws -> AuthenticationState { .authenticated(user) }
    func updatePassword(_ password: String) async throws -> AuthenticationState { .authenticated(user) }
    func signInWithApple(identityToken: String, rawNonce: String, fullName: String?) async throws -> AuthenticatedUser { user }
    func googleAuthorizationURL() throws -> URL { URL(string: "https://example.com")! }
    func signOut() async {}
    func events() -> AsyncStream<AuthenticationEvent> { AsyncStream { _ in } }
}
