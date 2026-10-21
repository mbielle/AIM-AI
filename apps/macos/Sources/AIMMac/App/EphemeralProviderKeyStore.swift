import AIMCore
import Foundation

/// Test/in-memory app instances must never inspect or prompt for real API keys.
final class EphemeralProviderKeyStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
