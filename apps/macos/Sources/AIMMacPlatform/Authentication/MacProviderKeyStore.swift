import AIMApplication
import AIMCore
import Foundation
import LocalAuthentication
import Security

/// Inventory means existence of provider credentials, not decrypted credential data.
public protocol ProviderCredentialInventory: Sendable {
    func configuredProviders() throws -> Set<ChatProvider>
}

/// Each provider is decrypted only on demand, once per process after successful
/// authorization. Concurrent readers share that result instead of opening dialogs.
public final class MacProviderKeyStore: SecureStoring, ProviderCredentialInventory, ScopedProviderCredentialInventory, LegacyCredentialBacking, @unchecked Sendable {
    public static let service = AIMInstallationContext.keychainService("com.aimai.macos.providers")
    private let backing: any SecureStoring
    private let inventory: @Sendable () throws -> Set<String>
    private let insertOnly: (@Sendable (Data, String) throws -> Bool)?
    private let condition = NSCondition()
    private var cached: [String: Data] = [:]
    private var reading: Set<String> = []
    private final class ReadAttempt {
        var result: Result<Data?, Error>?
    }
    private var attempts: [String: ReadAttempt] = [:]

    public convenience init() {
        self.init(backing: KeychainSecureStore(service: Self.service), inventoryKeys: Self.readInventory, insertOnly: Self.insertKeychainItem)
    }

    init(backing: any SecureStoring, inventory: @escaping @Sendable () throws -> Set<ChatProvider>) {
        self.backing = backing; self.inventory = { try Set(inventory().map(\.rawValue)) }; insertOnly = nil
    }
    init(backing: any SecureStoring, inventoryKeys: @escaping @Sendable () throws -> Set<String>, insertOnly: (@Sendable (Data, String) throws -> Bool)? = nil) {
        self.backing = backing; self.inventory = inventoryKeys; self.insertOnly = insertOnly
    }

    public func credentialKeyNames() throws -> Set<String> { try inventory() }

    public func insertCredentialIfAbsent(_ data: Data, forKey key: String) throws -> Bool {
        guard let insertOnly else { throw LegacyCredentialAdoptionError.unavailable }
        // Do not wait for an existing destination read/authorization prompt
        // while the caller holds its identity commit lock. Atomic add cannot
        // change an item that such a read could observe.
        let inserted = try insertOnly(data, key)
        // A duplicate may have been created by another process. Do not retain
        // an older cached value in either outcome.
        condition.lock(); cached.removeValue(forKey: key); condition.unlock()
        return inserted
    }

    public func configuredProviders() throws -> Set<ChatProvider> { try Set(inventory().compactMap(ChatProvider.init(rawValue:))) }
    public func configuredProviders(storageOwnerID: UUID) throws -> Set<ChatProvider> {
        let prefix = ProfileScopedCredentialStore.prefix(storageOwnerID)
        return try Set(inventory().filter { $0.hasPrefix(prefix) }.compactMap { ChatProvider(rawValue: String($0.dropFirst(prefix.count))) })
    }

    public func readData(forKey key: String) throws -> Data? {
        condition.lock()
        if let attempt = attempts[key] {
            while attempt.result == nil { condition.wait() }
            let result = attempt.result!
            condition.unlock()
            return try result.get()
        }
        while reading.contains(key) { condition.wait() }
        if let value = cached[key] { condition.unlock(); return value }
        let attempt = ReadAttempt()
        attempts[key] = attempt
        reading.insert(key)
        condition.unlock()
        let result = Result { try backing.readData(forKey: key) }
        condition.lock()
        if case let .success(value?) = result { cached[key] = value }
        attempt.result = result
        attempts.removeValue(forKey: key)
        reading.remove(key)
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }

    public func store(_ data: Data, forKey key: String) throws {
        // Serialize updates with an outstanding read of the same item so its
        // older value cannot repopulate the cache after a replacement/removal.
        condition.lock()
        while reading.contains(key) { condition.wait() }
        reading.insert(key)
        condition.unlock()
        defer { condition.lock(); reading.remove(key); condition.broadcast(); condition.unlock() }
        try backing.store(data, forKey: key)
        condition.lock(); cached[key] = data; condition.unlock()
    }

    public func removeData(forKey key: String) throws {
        condition.lock()
        while reading.contains(key) { condition.wait() }
        reading.insert(key)
        condition.unlock()
        defer { condition.lock(); reading.remove(key); condition.broadcast(); condition.unlock() }
        try backing.removeData(forKey: key)
        condition.lock(); cached.removeValue(forKey: key); condition.unlock()
    }

    private static func readInventory() throws -> Set<String> {
        // Never request kSecReturnData here. Authentication UI is forbidden for
        // startup inventory; an unavailable inventory must not summon a dialog.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        let rows = result as? [[String: Any]] ?? []
        return Set(rows.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    private static func insertKeychainItem(_ data: Data, key: String) throws -> Bool {
        // SecItemAdd is the cross-process no-overwrite primitive. Never fall
        // back to SecureStoring.store, which may update an existing item.
        let context = LAContext()
        context.interactionNotAllowed = true
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        return true
    }
}
