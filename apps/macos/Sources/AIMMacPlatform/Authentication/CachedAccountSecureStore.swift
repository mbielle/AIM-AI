import AIMCore
import Foundation

/// Coalesces successful Keychain reads; credentials never go into preferences.
/// A shared opaque revision invalidates other processes after writes/removal.
public final class CachedAccountSecureStore: SecureStoring, @unchecked Sendable {
    public static let shared = CachedAccountSecureStore(service: AIMInstallationContext.keychainService("com.aimai.macos.auth"))
    private let backing: any SecureStoring
    private let condition = NSCondition()
    private let defaults = AIMInstallationContext.sharedPreferences
    private let revisionKey: String
    private var revision: String?
    private var values: [String: Data] = [:]
    private var absent: Set<String> = []
    private var busy = false

    public init(service: String, backing: (any SecureStoring)? = nil) {
        self.backing = backing ?? KeychainSecureStore(service: service)
        revisionKey = "AIMSecureStoreRevision." + service
    }
    private func begin() {
        condition.lock()
        while busy { condition.wait() }
        busy = true
        defaults.synchronize()
        let current = defaults.string(forKey: revisionKey)
        if revision != current { values.removeAll(); absent.removeAll(); revision = current }
        condition.unlock()
    }
    private func end() { condition.lock(); busy = false; condition.broadcast(); condition.unlock() }
    public func readData(forKey key: String) throws -> Data? {
        begin(); defer { end() }
        if let value = values[key] { return value }
        if absent.contains(key) { return nil }
        let value = try backing.readData(forKey: key)
        if let value { values[key] = value } else { absent.insert(key) }
        return value
    }
    public func store(_ data: Data, forKey key: String) throws {
        begin(); defer { end() }
        try backing.store(data, forKey: key)
        values[key] = data; absent.remove(key); changed()
    }
    public func removeData(forKey key: String) throws {
        begin(); defer { end() }
        try backing.removeData(forKey: key)
        values.removeValue(forKey: key); absent.insert(key); changed()
    }
    private func changed() {
        revision = UUID().uuidString
        defaults.set(revision, forKey: revisionKey); defaults.synchronize()
    }
}
