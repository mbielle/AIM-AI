#if DEBUG
import CryptoKit
import Foundation

/// Disposable synthetic identities only; never reads or exports the Keychain.
public final class AIMQAFileStore: SecureStoring, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DirectRemoteError.invalidConfiguration
        }
    }
    private func path(_ key: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    public func store(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let file = path(key)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func readData(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let file = path(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }
    public func removeData(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let file = path(key)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
#endif
