import AIMApplication
import AIMCore
import Foundation

public enum LegacyCredentialAdoptionError: Error { case unavailable, invalidSelection, destinationExists, missingSource, invalidKey }

/// Attribute inventory and a genuine atomic add are required. There is no
/// read-then-overwriting-write fallback for stores without this capability.
public protocol LegacyCredentialBacking: SecureStoring {
    func credentialKeyNames() throws -> Set<String>
    func insertCredentialIfAbsent(_ data: Data, forKey key: String) throws -> Bool
}

public enum LegacyProviderCredential: Hashable, Identifiable, Sendable {
    case provider(ChatProvider)
    case flux
    public var id: String { logicalKey }
    public var name: String {
        switch self { case .provider(let provider): provider.name; case .flux: "Black Forest Labs (FLUX)" }
    }
    var logicalKey: String {
        switch self { case .provider(let provider): provider.rawValue; case .flux: BlackForestLabsImageService.keyName }
    }
    static var allowed: Set<Self> {
        Set(ChatProvider.allCases.filter { $0 != .local && $0 != .chatgpt }.map(Self.provider)).union([.flux])
    }
}

public struct LegacyCredentialReview: Sendable {
    public let scope: CredentialStorageScope.Snapshot
    public let available: Set<LegacyProviderCredential>
    public let existingDestination: Set<LegacyProviderCredential>
}

extension ProfileScopedCredentialStore {
    /// Attributes only: the person selects providers before any legacy secret
    /// is decrypted. OAuth sessions, channel/plugin tokens and unknown keys
    /// have no allowed representation and cannot be selected.
    public func reviewLegacyProviderCredentials() throws -> LegacyCredentialReview {
        let captured = scope.snapshot()
        _ = try key("legacy-review", snapshot: captured)
        guard let legacy = backing as? any LegacyCredentialBacking, let owner = captured.ownerID else {
            throw LegacyCredentialAdoptionError.unavailable
        }
        let names = try legacy.credentialKeyNames()
        _ = try key("legacy-review", snapshot: captured)
        let found = LegacyProviderCredential.allowed.filter { names.contains($0.logicalKey) }
        let existing = found.filter { names.contains(Self.prefix(owner) + $0.logicalKey) }
        return .init(scope: captured, available: found.subtracting(existing), existingDestination: existing)
    }

    /// Explicit copy, never move. Each insert is atomic and identity-fenced.
    /// A failure can leave earlier selected copies; those are retained rather
    /// than deleting credentials that a concurrently running app may now use.
    public func copyLegacyProviderCredentials(_ selected: Set<LegacyProviderCredential>, reviewed: LegacyCredentialReview) throws -> Int {
        _ = try key("legacy-copy", snapshot: reviewed.scope)
        guard !selected.isEmpty, selected.isSubset(of: reviewed.available), selected.isSubset(of: LegacyProviderCredential.allowed) else {
            throw LegacyCredentialAdoptionError.invalidSelection
        }
        guard let legacy = backing as? any LegacyCredentialBacking else { throw LegacyCredentialAdoptionError.unavailable }
        let names = try legacy.credentialKeyNames()
        _ = try key("legacy-copy", snapshot: reviewed.scope)
        for item in selected {
            let destination = try key(item.logicalKey, snapshot: reviewed.scope)
            guard !names.contains(destination) else { throw LegacyCredentialAdoptionError.destinationExists }
        }
        var count = 0
        for item in selected.sorted(by: { $0.id < $1.id }) {
            let destination = try key(item.logicalKey, snapshot: reviewed.scope)
            guard let data = try legacy.readData(forKey: item.logicalKey) else { throw LegacyCredentialAdoptionError.missingSource }
            _ = try key(item.logicalKey, snapshot: reviewed.scope)
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty, value.count <= 32_768,
                  !value.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw LegacyCredentialAdoptionError.invalidKey
            }
            let inserted = try scope.withCurrent(reviewed.scope) {
                try legacy.insertCredentialIfAbsent(data, forKey: destination)
            }
            _ = try key(item.logicalKey, snapshot: reviewed.scope)
            guard inserted else { throw LegacyCredentialAdoptionError.destinationExists }
            count += 1
        }
        return count
    }
}
