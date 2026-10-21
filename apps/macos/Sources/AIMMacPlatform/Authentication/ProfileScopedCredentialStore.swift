import AIMCore
import Foundation

public enum CredentialScopeError: Error { case unavailable, changed }

/// Storage ownership is independent of cloud authentication. The epoch also
/// invalidates operations that outlive a sign-out and return to the same owner.
public final class CredentialStorageScope: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable { public let ownerID: UUID?; fileprivate let epoch: UInt64 }
    private let lock = NSLock()
    private var ownerID: UUID?
    private var epoch: UInt64 = 0
    public init(ownerID: UUID? = nil) { self.ownerID = ownerID }
    public func activate(_ owner: UUID?) { lock.withLock { if ownerID != owner { ownerID = owner; epoch &+= 1 } } }
    public func snapshot() -> Snapshot { lock.withLock { .init(ownerID: ownerID, epoch: epoch) } }
    /// Keep identity activation outside the insert-only commit. Reads that may
    /// display Keychain authorization run before this short critical section.
    func withCurrent<T>(_ captured: Snapshot, _ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard captured == Snapshot(ownerID: ownerID, epoch: epoch), ownerID != nil else { throw CredentialScopeError.changed }
            return try operation()
        }
    }
}

public protocol CredentialScopeValidating: Sendable { func validateCredentialScope() throws }

public protocol ScopedProviderCredentialInventory: Sendable {
    func configuredProviders(storageOwnerID: UUID) throws -> Set<ChatProvider>
}

/// All logical credential keys, including OAuth sessions, provider plugins,
/// media keys and channel tokens, receive the same owner prefix. Unscoped keys
/// remain quarantined; neither inventory nor reads adopt them.
public final class ProfileScopedCredentialStore: SecureStoring, ProviderCredentialInventory, CredentialScopeValidating, @unchecked Sendable {
    @TaskLocal public static var requiredOwnerID: UUID?
    let backing: any SecureStoring
    public let scope: CredentialStorageScope
    public init(backing: any SecureStoring, scope: CredentialStorageScope) { self.backing = backing; self.scope = scope }
    public static func prefix(_ owner: UUID) -> String { "profile.v1." + owner.uuidString.lowercased() + "." }
    func key(_ logical: String, snapshot: CredentialStorageScope.Snapshot) throws -> String {
        guard let owner = snapshot.ownerID else { throw CredentialScopeError.unavailable }
        guard snapshot == scope.snapshot(), Self.requiredOwnerID.map({ $0 == owner }) ?? true else { throw CredentialScopeError.changed }
        return Self.prefix(owner) + logical
    }
    public func readData(forKey logical: String) throws -> Data? {
        try readData(forKey: logical, expectedScope: scope.snapshot())
    }
    public func readData(forKey logical: String, expectedScope: CredentialStorageScope.Snapshot) throws -> Data? {
        let scoped = try key(logical, snapshot: expectedScope)
        let data = try backing.readData(forKey: scoped)
        _ = try key(logical, snapshot: expectedScope)
        return data
    }
    public func store(_ data: Data, forKey logical: String) throws {
        let captured = scope.snapshot(), scoped = try key(logical, snapshot: captured)
        try backing.store(data, forKey: scoped)
        _ = try key(logical, snapshot: captured)
    }
    public func removeData(forKey logical: String) throws {
        let captured = scope.snapshot(), scoped = try key(logical, snapshot: captured)
        try backing.removeData(forKey: scoped)
        _ = try key(logical, snapshot: captured)
    }
    public func configuredProviders() throws -> Set<ChatProvider> {
        let captured = scope.snapshot()
        _ = try key("inventory", snapshot: captured)
        let result: Set<ChatProvider>
        if let inventory = backing as? any ScopedProviderCredentialInventory, let owner = captured.ownerID {
            result = try inventory.configuredProviders(storageOwnerID: owner)
        } else {
            result = try Set(ChatProvider.allCases.filter { try readData(forKey: $0.rawValue, expectedScope: captured) != nil })
        }
        _ = try key("inventory", snapshot: captured)
        return result
    }
    public func validateCredentialScope() throws { _ = try key("scope", snapshot: scope.snapshot()) }
    public func boundToCurrentScope() -> any SecureStoring { Bound(store: self, snapshot: scope.snapshot(), requiredOwnerID: Self.requiredOwnerID) }
    private struct Bound: SecureStoring, CredentialScopeValidating {
        let store: ProfileScopedCredentialStore
        let snapshot: CredentialStorageScope.Snapshot
        let requiredOwnerID: UUID?
        func validateCredentialScope() throws {
            guard requiredOwnerID.map({ $0 == snapshot.ownerID }) ?? true else { throw CredentialScopeError.changed }
            _ = try store.key("scope", snapshot: snapshot)
        }
        func readData(forKey key: String) throws -> Data? {
            try validateCredentialScope()
            return try store.readData(forKey: key, expectedScope: snapshot)
        }
        func store(_ data: Data, forKey key: String) throws {
            try validateCredentialScope()
            _ = try store.key(key, snapshot: snapshot)
            try store.backing.store(data, forKey: try store.key(key, snapshot: snapshot))
            _ = try store.key(key, snapshot: snapshot)
        }
        func removeData(forKey key: String) throws {
            try validateCredentialScope()
            _ = try store.key(key, snapshot: snapshot)
            try store.backing.removeData(forKey: try store.key(key, snapshot: snapshot))
            _ = try store.key(key, snapshot: snapshot)
        }
    }
}
