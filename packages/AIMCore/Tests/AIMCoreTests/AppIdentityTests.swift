import Foundation
import Testing
@testable import AIMCore

@Suite("Local identity is not cloud authentication")
struct AppIdentityTests {
    @Test func persistedProfileSurvivesRestart() throws {
        let store = IdentityTestStore()
        let first = try LocalProfile.loadOrCreate(store: store)
        let restarted = try LocalProfile.loadOrCreate(store: store)
        #expect(first == restarted)
        #expect(AppIdentity.local(first).authenticatedUser == nil)
        #expect(AppIdentity.local(first).storageID == first.id)
    }

    @Test func invalidIdentityDoesNotOverwriteExistingData() throws {
        let store = IdentityTestStore()
        let original = Data("invalid identity".utf8)
        try store.store(original, forKey: "local-profile.v1")
        #expect(throws: (any Error).self) { try LocalProfile.loadOrCreate(store: store) }
        #expect(try store.readData(forKey: "local-profile.v1") == original)
    }

    @Test func localAndCloudOwnersStaySeparate() throws {
        let local = try LocalProfile.loadOrCreate(store: IdentityTestStore())
        let user = AuthenticatedUser(id: UUID(), email: nil, fullName: nil)
        #expect(AppIdentity.account(user).storageID != local.id)
        #expect(AppIdentity.account(user).authenticatedUser == user)
        #expect(!AppIdentity.account(user).isLocal)
    }

    @Test func secureStorageFailureIsPropagated() {
        #expect(throws: (any Error).self) { try LocalProfile.loadOrCreate(store: FailingIdentityStore()) }
    }
}

private final class IdentityTestStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func readData(forKey key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}

private struct FailingIdentityStore: SecureStoring {
    func store(_ data: Data, forKey key: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func readData(forKey key: String) throws -> Data? { throw CocoaError(.fileReadNoPermission) }
    func removeData(forKey key: String) throws { throw CocoaError(.fileWriteNoPermission) }
}
