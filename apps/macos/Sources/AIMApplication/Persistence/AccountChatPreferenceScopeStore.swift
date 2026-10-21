import AIMCore
import Foundation

/// The global settings file is only a display mirror. This archive owns the
/// account attribution and keeps unclaimed settings without uploading them.
public struct AccountChatPreferenceScopeStore: Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var favorites: [FavoriteModel]
        public var addedModels: [String]?
        public var preferences: AccountChatPreferences
        public var personalization: Personalization?
        public init(favorites: [FavoriteModel] = [], preferences: AccountChatPreferences = .init(), personalization: Personalization? = nil, addedModels: [String]? = nil) {
            self.addedModels = addedModels; self.favorites = favorites; self.preferences = preferences; self.personalization = personalization
        }
    }
    private struct Archive: Codable {
        var activeAccountID: UUID?
        var accounts: [UUID: Snapshot] = [:]
        var unclaimed: Snapshot
    }
    private struct PriorSync: Decodable {
        var lastFavorites: Set<String>?
        var lastAddedModels: Set<String>?
        var lastPreferences: AccountChatPreferences?
    }
    private let secureStore: any SecureStoring
    private let key = "account-chat-preference-scopes.v1"
    public init(secureStore: any SecureStoring) { self.secureStore = secureStore }

    /// `captureCurrent` is false at startup: a crash may have left the global
    /// mirror with another account's values, so only this archive is trusted.
    public func activate(accountID: UUID?, current: Snapshot, currentAccountID: UUID?, captureCurrent: Bool) throws -> Snapshot {
        var archive = try load() ?? Archive(unclaimed: current)
        if captureCurrent {
            guard archive.activeAccountID == currentAccountID else { throw AccountServiceError.conflict }
            if let currentAccountID { archive.accounts[currentAccountID] = current }
            else { archive.unclaimed = current }
        }
        var selected: Snapshot
        if let accountID {
            selected = try archive.accounts[accountID] ?? priorSync(accountID: accountID) ?? Snapshot()
            // One-time upgrade only for the account that already owns this active
            // archive. New accounts never inherit the installation's old additions.
            if selected.addedModels == nil, archive.activeAccountID == accountID { selected.addedModels = current.addedModels }
            archive.accounts[accountID] = selected
        } else { selected = archive.unclaimed }
        archive.activeAccountID = accountID
        try store(archive)
        return selected
    }
    public func save(_ snapshot: Snapshot, accountID: UUID?) throws {
        guard var archive = try load(), archive.activeAccountID == accountID else { throw AccountServiceError.conflict }
        if let accountID { archive.accounts[accountID] = snapshot }
        else { archive.unclaimed = snapshot }
        try store(archive)
    }
    public func unclaimedSettings() throws -> Snapshot? { try load()?.unclaimed }
    private func load() throws -> Archive? {
        try secureStore.readData(forKey: key).map { try JSONDecoder().decode(Archive.self, from: $0) }
    }
    private func store(_ archive: Archive) throws { try secureStore.store(JSONEncoder().encode(archive), forKey: key) }
    private func priorSync(accountID: UUID) throws -> Snapshot? {
        guard let data = try secureStore.readData(forKey: "account-chat-sync.v1." + accountID.uuidString) else { return nil }
        let prior = try JSONDecoder().decode(PriorSync.self, from: data)
        guard prior.lastFavorites != nil || prior.lastAddedModels != nil || prior.lastPreferences != nil else { return nil }
        let preferences = prior.lastPreferences ?? .init()
        let favorites = (prior.lastFavorites ?? []).sorted().compactMap { entry -> FavoriteModel? in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let provider = ChatProvider(rawValue: String(parts[0])) else { return nil }
            return try? FavoriteModel(provider: provider, modelID: String(parts[1]), name: String(parts[1]))
        }
        return Snapshot(favorites: favorites, preferences: preferences,
            personalization: .init(isEnabled: preferences.customInstructions?.isEmpty == false, instructions: preferences.customInstructions ?? ""), addedModels: prior.lastAddedModels?.sorted())
    }
}
