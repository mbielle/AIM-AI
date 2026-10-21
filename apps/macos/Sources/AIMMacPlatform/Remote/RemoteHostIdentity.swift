import AIMCore
import CryptoKit
import Foundation

/// This Mac as a Remote host (protocol v2 §3, §6.3): a machine id, a 256-bit
/// machine secret (only its SHA-256 is on the server; it proves physical access
/// for pairing, keys and command transitions) and the numbered mirror keys.
/// Everything lives in the Keychain, never in plain files.
public struct RemoteHostIdentity: Codable, Equatable, Sendable {
    public let machineID: String
    public let secret: String
    /// Mirror keys by version (current and the previous one during a rotation).
    public private(set) var keys: [Int: Data]
    public private(set) var keyVersion: Int
    /// Devices that received the current key: revoking one of them forces a rotation.
    public var keyedDevices: Set<String>
    /// Public-key fingerprints acknowledged by the relay for the current key.
    /// Device IDs survive re-pairing, while their public keys can change.
    public var keyedDeviceFingerprints: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case machineID, secret, keys, keyVersion, keyedDevices, keyedDeviceFingerprints
    }

    public var currentKey: Data { keys[keyVersion]! }

    public static func fresh() -> RemoteHostIdentity {
        RemoteHostIdentity(machineID: UUID().uuidString.lowercased(), secret: randomHex(32),
                           keys: [1: randomBytes(32)], keyVersion: 1, keyedDevices: [])
    }

    /// A new mirror key; the previous one is kept for the transition only.
    public mutating func rotate() {
        let previous = keyVersion
        keyVersion += 1
        keys = [previous: keys[previous] ?? Self.randomBytes(32), keyVersion: Self.randomBytes(32)]
        keyedDevices = []
        keyedDeviceFingerprints = [:]
    }

    static func publicKeyFingerprint(_ publicKey: String) -> String {
        SHA256.hash(data: Data(publicKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func randomHex(_ count: Int) -> String {
        randomBytes(count).map { String(format: "%02x", $0) }.joined()
    }
}

public extension RemoteHostIdentity {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try values.decode(String.self, forKey: .machineID)
        secret = try values.decode(String.self, forKey: .secret)
        keys = try values.decode([Int: Data].self, forKey: .keys)
        keyVersion = try values.decode(Int.self, forKey: .keyVersion)
        keyedDevices = try values.decode(Set<String>.self, forKey: .keyedDevices)
        keyedDeviceFingerprints = try values.decodeIfPresent([String: String].self, forKey: .keyedDeviceFingerprints) ?? [:]
    }
}

/// Keychain persistence of the host identity.
public struct RemoteHostIdentityStore: Sendable {
    private let store: any SecureStoring
    private static let legacyKey = "remote-host-identity"
    public let accountID: UUID?
    private var key: String { accountID.map { "remote-host-identity.v2." + $0.uuidString.lowercased() } ?? Self.legacyKey }

    public init(accountID: UUID? = nil, store: any SecureStoring = KeychainSecureStore(service: AIMInstallationContext.keychainService("com.aimai.macos.remote"))) {
        self.accountID = accountID; self.store = store
    }

    public func load() throws -> RemoteHostIdentity? {
        guard let data = try store.readData(forKey: key) else { return nil }
        return try JSONDecoder().decode(RemoteHostIdentity.self, from: data)
    }

    public func loadOrCreate() throws -> RemoteHostIdentity {
        if let existing = try load() { return existing }
        let fresh = RemoteHostIdentity.fresh()
        try save(fresh)
        return fresh
    }

    public func save(_ identity: RemoteHostIdentity) throws {
        try store.store(try JSONEncoder().encode(identity), forKey: key)
    }

    /// Only successful server registration confirms legacy ownership. No legacy
    /// material is overwritten or removed, including on a foreign-account conflict.
    public func resolveForRegistration(
        isCurrent: @escaping @Sendable () async throws -> Void,
        register: @escaping @Sendable (RemoteHostIdentity) async throws -> Void
    ) async throws -> RemoteHostIdentity {
        try await isCurrent()
        if let existing = try load() {
            try await isCurrent(); try await register(existing); try await isCurrent()
            return existing // A scoped conflict is never repaired by creating another ID.
        }
        if accountID != nil, let legacyData = try store.readData(forKey: Self.legacyKey) {
            let legacy = try JSONDecoder().decode(RemoteHostIdentity.self, from: legacyData)
            try await isCurrent()
            do {
                try await register(legacy)
            } catch RemoteHostError.server("machine_conflict") {
                try await isCurrent()
                let fresh = RemoteHostIdentity.fresh()
                try save(fresh) // Persist stable ID before the one new registration.
                try await isCurrent(); try await register(fresh); try await isCurrent()
                return fresh
            }
            try await isCurrent()
            try save(legacy) // Exact identity/key versions/devices preserved after ACK only.
            return legacy
        }
        let fresh = RemoteHostIdentity.fresh()
        try await isCurrent(); try save(fresh)
        try await isCurrent(); try await register(fresh); try await isCurrent()
        return fresh
    }

    /// Forgets this host entirely (a new machine on next enable).
    public func reset() throws { try store.removeData(forKey: key) }
}
