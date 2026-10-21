import AIMApplication
import AIMCore
import Foundation
import XCTest

private final class PreferenceScopeSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private actor PreferenceScopeCloud: AccountContentSyncing {
    private var accounts: [UUID: [UUID: AccountDocument]] = [:]
    func documents(accountID: UUID) async throws -> [AccountDocument] { Array((accounts[accountID] ?? [:]).values) }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard document.revision == (accounts[accountID]?[document.id]?.revision ?? 0) else { throw AccountServiceError.conflict }
        var saved = document; saved.revision += 1; accounts[accountID, default: [:]][saved.id] = saved; return saved
    }
}

final class AccountChatPreferenceScopeTests: XCTestCase {
    func testLegacyAdditionsUpgradeOnlyTheirExistingActiveAccount() throws {
        let secrets = PreferenceScopeSecrets(), store = AccountChatPreferenceScopeStore(secureStore: secrets)
        let a = UUID(), b = UUID()
        _ = try store.activate(accountID: a, current: .init(), currentAccountID: nil, captureCurrent: false)
        let upgraded = try store.activate(accountID: a, current: .init(addedModels: ["openrouter:existing-mac-model"]), currentAccountID: nil, captureCurrent: false)
        XCTAssertEqual(upgraded.addedModels, ["openrouter:existing-mac-model"])
        let emptyB = try store.activate(accountID: b, current: upgraded, currentAccountID: a, captureCurrent: true)
        XCTAssertNil(emptyB.addedModels)
        let restored = try store.activate(accountID: a, current: emptyB, currentAccountID: b, captureCurrent: true)
        XCTAssertEqual(restored.addedModels, upgraded.addedModels)
    }

    private func snapshot(_ text: String) throws -> AccountChatPreferenceScopeStore.Snapshot {
        var preferences = AccountChatPreferences(); preferences.customInstructions = text; preferences.responseStyle = .detailed
        return .init(favorites: [try FavoriteModel(provider: .openAI, modelID: "fixture", name: "Favorite \(text)")],
            preferences: preferences, personalization: .init(isEnabled: true, instructions: text))
    }
    func testAccountAToEmptyBDoesNotUploadAsPreferencesAndRestoresAWithoutLosingLegacySettings() async throws {
        let secrets = PreferenceScopeSecrets(), store = AccountChatPreferenceScopeStore(secureStore: secrets)
        let accountA = UUID(), accountB = UUID(), legacy = try snapshot("Unclaimed old Mac settings"), a = try snapshot("Private account A")
        let emptyA = try store.activate(accountID: accountA, current: legacy, currentAccountID: nil, captureCurrent: false)
        XCTAssertEqual(emptyA, .init(), "Unclaimed installation settings require explicit adoption")
        XCTAssertEqual(try store.unclaimedSettings(), legacy)
        try store.save(a, accountID: accountA)
        let b = try store.activate(accountID: accountB, current: a, currentAccountID: accountA, captureCurrent: true)
        XCTAssertEqual(b, .init())
        let db = try AIMDatabase(inMemory: true), cloud = PreferenceScopeCloud()
        let sync = AccountChatSync(repository: SQLiteConversationRepository(database: db), projects: SQLiteProjectRepository(database: db),
            metrics: SQLiteMessageMetricsRepository(database: db), secureStore: secrets)
        _ = try await sync.synchronize(accountID: accountB, service: cloud, favorites: Set(b.favorites.map(\.id)), preferences: b.preferences, currentAccount: { accountB })
        let published = try await cloud.documents(accountID: accountB)
        let preferencesDoc = try XCTUnwrap(published.first { $0.kind == "preferences" })
        let preferences = try JSONDecoder().decode(AccountChatPreferences.self, from: Data(preferencesDoc.payload.utf8))
        XCTAssertNil(preferences.customInstructions); XCTAssertEqual(preferences.responseStyle, .balanced)
        let favoritesDoc = try XCTUnwrap(published.first { $0.kind == "favorites" })
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(favoritesDoc.payload.utf8)), [])
        let restoredA = try store.activate(accountID: accountA, current: b, currentAccountID: accountB, captureCurrent: true)
        XCTAssertEqual(restoredA, a); XCTAssertEqual(try store.unclaimedSettings(), legacy)
    }

    func testStartupDoesNotTrustAnotherAccountsStaleGlobalMirrorAfterACrash() throws {
        let secrets = PreferenceScopeSecrets(), store = AccountChatPreferenceScopeStore(secureStore: secrets)
        let accountA = UUID(), accountB = UUID(), a = try snapshot("A"), b = try snapshot("B")
        _ = try store.activate(accountID: accountA, current: .init(), currentAccountID: nil, captureCurrent: false)
        try store.save(a, accountID: accountA)
        _ = try store.activate(accountID: accountB, current: a, currentAccountID: accountA, captureCurrent: true)
        try store.save(b, accountID: accountB)
        let restarted = AccountChatPreferenceScopeStore(secureStore: secrets)
        XCTAssertEqual(try restarted.activate(accountID: accountB, current: a, currentAccountID: nil, captureCurrent: false), b)
        XCTAssertThrowsError(try restarted.save(a, accountID: accountA))
        XCTAssertEqual(try restarted.activate(accountID: accountA, current: b, currentAccountID: accountB, captureCurrent: true), a)
    }

    func testOnlyExplicitlyAccountScopedPriorSyncCanSeedAnExistingAccount() throws {
        let secrets = PreferenceScopeSecrets(), accountA = UUID(), accountB = UUID(), legacy = try snapshot("Legacy")
        struct Prior: Encodable { let lastFavorites: Set<String>; let lastPreferences: AccountChatPreferences }
        let prior = try snapshot("Previously synced A")
        try secrets.store(JSONEncoder().encode(Prior(lastFavorites: Set(prior.favorites.map(\.id)), lastPreferences: prior.preferences)), forKey: "account-chat-sync.v1." + accountA.uuidString)
        let store = AccountChatPreferenceScopeStore(secureStore: secrets)
        let loaded = try store.activate(accountID: accountA, current: legacy, currentAccountID: nil, captureCurrent: false)
        XCTAssertEqual(loaded.preferences, prior.preferences)
        XCTAssertEqual(loaded.favorites.map(\.id), prior.favorites.map(\.id))
        XCTAssertEqual(try store.unclaimedSettings(), legacy)
        let fresh = try store.activate(accountID: accountB, current: loaded, currentAccountID: accountA, captureCurrent: true)
        XCTAssertEqual(fresh, .init())
    }
}
