@testable import AIMMacPlatform
import AIMCore
import XCTest

final class ProfileScopedCredentialStoreTests: XCTestCase {
    func testLocalAndTwoAccountsNeverReadOrInventoryEachOthersCredentialsOrLegacyKeys() throws {
        let backing = ScopedCredentialSecrets(), local = UUID(), first = UUID(), second = UUID()
        let scope = CredentialStorageScope(ownerID: local)
        let store = ProfileScopedCredentialStore(backing: backing, scope: scope)
        try backing.store(Data("legacy-preserved".utf8), forKey: ChatProvider.openAI.rawValue)
        XCTAssertNil(try store.readData(forKey: ChatProvider.openAI.rawValue))
        XCTAssertTrue(try store.configuredProviders().isEmpty)
        for (owner, provider, value) in [(local, ChatProvider.openAI, "local-value"), (first, .anthropic, "first-value"), (second, .openRouter, "second-value")] {
            scope.activate(owner)
            try store.store(Data(value.utf8), forKey: provider.rawValue)
            try store.store(Data(value.utf8), forKey: "oauth-session")
        }
        for (owner, provider, value) in [(first, ChatProvider.anthropic, "first-value"), (second, .openRouter, "second-value"), (local, .openAI, "local-value")] {
            scope.activate(owner)
            XCTAssertEqual(try store.configuredProviders(), [provider])
            XCTAssertEqual(try store.readData(forKey: provider.rawValue), Data(value.utf8))
            XCTAssertEqual(try store.readData(forKey: "oauth-session"), Data(value.utf8))
            for other in [ChatProvider.openAI, .anthropic, .openRouter] where other != provider {
                XCTAssertNil(try store.readData(forKey: other.rawValue))
            }
        }
        XCTAssertEqual(try backing.readData(forKey: ChatProvider.openAI.rawValue), Data("legacy-preserved".utf8))
    }

    func testBlockedReadCannotReturnPreviousOwnersKeyAfterSwitchIncludingCachedRead() async throws {
        let backing = ScopedCredentialSecrets(), first = UUID(), second = UUID()
        let scope = CredentialStorageScope(ownerID: first)
        let rawCache = MacProviderKeyStore(backing: backing, inventoryKeys: { backing.keys })
        let store = ProfileScopedCredentialStore(backing: rawCache, scope: scope)
        try store.store(Data("first-value".utf8), forKey: "openai")
        let firstBound = store.boundToCurrentScope()
        XCTAssertEqual(try firstBound.readData(forKey: "openai"), Data("first-value".utf8))
        scope.activate(second)
        XCTAssertNil(try store.readData(forKey: "openai"))
        XCTAssertThrowsError(try firstBound.readData(forKey: "openai"))
        try store.store(Data("second-value".utf8), forKey: "openai")
        XCTAssertEqual(try store.readData(forKey: "openai"), Data("second-value".utf8))
        scope.activate(first)
        XCTAssertThrowsError(try firstBound.readData(forKey: "openai"), "An old operation remains invalid after returning to the same account")

        let gate = BlockingCredentialSecrets()
        let delayed = ProfileScopedCredentialStore(backing: gate, scope: scope)
        let started = expectation(description: "credential read waiting")
        gate.started = { started.fulfill() }
        let task = Task.detached { try delayed.readData(forKey: "openai") }
        await fulfillment(of: [started], timeout: 2)
        scope.activate(second)
        gate.release()
        do { _ = try await task.value; XCTFail("The old read must not escape its storage scope") }
        catch CredentialScopeError.changed {}
    }

    func testExecutionOwnerContextRejectsNewProfilesCredentials() throws {
        let scope = CredentialStorageScope(ownerID: UUID()), store = ProfileScopedCredentialStore(backing: ScopedCredentialSecrets(), scope: scope)
        try store.store(Data("current".utf8), forKey: "openai")
        let bound = try ProfileScopedCredentialStore.$requiredOwnerID.withValue(UUID()) {
            XCTAssertThrowsError(try store.readData(forKey: "openai"))
            return store.boundToCurrentScope()
        }
        XCTAssertThrowsError(try bound.readData(forKey: "openai"), "A detached callback retains the execution's owner restriction")
    }
}

private final class ScopedCredentialSecrets: SecureStoring, ScopedProviderCredentialInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var keys: Set<String> { lock.withLock { Set(values.keys) } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
    func configuredProviders(storageOwnerID: UUID) throws -> Set<ChatProvider> {
        let prefix = ProfileScopedCredentialStore.prefix(storageOwnerID)
        return Set(keys.filter { $0.hasPrefix(prefix) }.compactMap { ChatProvider(rawValue: String($0.dropFirst(prefix.count))) })
    }
}
private final class BlockingCredentialSecrets: SecureStoring, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    var started: (@Sendable () -> Void)?
    func release() { gate.signal() }
    func readData(forKey key: String) throws -> Data? { started?(); gate.wait(); return Data("old-value".utf8) }
    func store(_ data: Data, forKey key: String) throws {}
    func removeData(forKey key: String) throws {}
}
