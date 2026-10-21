import CryptoKit
import Foundation

public enum DirectRemoteError: Error, Equatable, Sendable {
    case invalidConfiguration, expiredInvitation, unauthorized, revoked, invalidPacket
    case conflictingCommand, outcomeUnknown, unavailable(String)
}
public enum DirectRemoteRole: String, Codable, Sendable { case mac, phone }
public enum DirectRemotePermission: String, CaseIterable, Codable, Sendable {
    case read, chat, code, agent, control, approve, settings, terminal
}
public struct DirectRemotePublicIdentity: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    /// Local storage owner only. This is never an authenticated AIM account.
    public let localProfileID: UUID
    public let role: DirectRemoteRole
    public let name: String
    public let agreementKey: Data
    public let signingKey: Data
    public var fingerprint: String { SHA256.hash(data: signingKey + agreementKey).map { String(format: "%02x", $0) }.joined() }
}
public struct DirectRemoteIdentity: Codable, Sendable {
    public let publicIdentity: DirectRemotePublicIdentity
    private let agreement: Data
    private let signing: Data
    public init(profile: LocalProfile, role: DirectRemoteRole, name: String) {
        let agreement = P256.KeyAgreement.PrivateKey(), signing = P256.Signing.PrivateKey()
        self.agreement = agreement.rawRepresentation; self.signing = signing.rawRepresentation
        publicIdentity = .init(version: 1, id: UUID(), localProfileID: profile.id, role: role,
            name: String(name.prefix(80)), agreementKey: agreement.publicKey.x963Representation, signingKey: signing.publicKey.x963Representation)
    }
    public static func loadOrCreate(profile: LocalProfile, role: DirectRemoteRole, name: String, store: any SecureStoring) throws -> Self {
        let key = "remote-direct.identity.v1." + profile.id.uuidString + "." + role.rawValue
        if let bytes = try store.readData(forKey: key) {
            let identity = try DirectRemoteCoding.decode(Self.self, bytes)
            guard identity.publicIdentity.version == 1, identity.publicIdentity.localProfileID == profile.id,
                  identity.publicIdentity.role == role,
                  try P256.KeyAgreement.PrivateKey(rawRepresentation: identity.agreement).publicKey.x963Representation == identity.publicIdentity.agreementKey,
                  try P256.Signing.PrivateKey(rawRepresentation: identity.signing).publicKey.x963Representation == identity.publicIdentity.signingKey else { throw DirectRemoteError.invalidConfiguration }
            return identity
        }
        let identity = Self(profile: profile, role: role, name: name)
        try store.store(DirectRemoteCoding.encode(identity), forKey: key); return identity
    }
    public func sign(_ bytes: Data) throws -> Data { try P256.Signing.PrivateKey(rawRepresentation: signing).signature(for: bytes).derRepresentation }
    public static func verify(_ signature: Data, bytes: Data, signer: DirectRemotePublicIdentity) throws {
        guard signer.version == 1,
              try P256.Signing.PublicKey(x963Representation: signer.signingKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: bytes) else { throw DirectRemoteError.unauthorized }
    }
    public func sessionKey(pair: DirectRemotePair) throws -> Data {
        let other = try pair.other(than: publicIdentity)
        let shared = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement)
            .sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: other.agreementKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(("aim-direct/v1/" + pair.id.uuidString).utf8),
            sharedInfo: try DirectRemoteCoding.encode([pair.host, pair.client]), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
public struct DirectRemoteInvite: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let host: DirectRemotePublicIdentity
    public let token: Data
    public let expiresAt: Date
    public let coordinatorURL: URL?
    public let lanService: String
    public func validate(now: Date = .now) throws {
        guard version == 1, host.version == 1, host.role == .mac, token.count == 32,
              host.agreementKey.count == 65, host.signingKey.count == 65,
              expiresAt > now, expiresAt.timeIntervalSince(now) <= 180, !lanService.isEmpty,
              coordinatorURL.map({ $0.user == nil && $0.password == nil && $0.fragment == nil && $0.host != nil && ($0.scheme == "wss" || ($0.scheme == "ws" && ["127.0.0.1", "::1", "localhost"].contains($0.host ?? ""))) }) ?? true else { throw DirectRemoteError.expiredInvitation }
    }
    public func qrURL() throws -> URL {
        let payload = try DirectRemoteCoding.encode(self).base64EncodedString()
        var value = URLComponents(); value.scheme = "aim"; value.host = "direct"; value.queryItems = [.init(name: "v", value: "1"), .init(name: "ticket", value: payload)]
        guard let url = value.url else { throw DirectRemoteError.invalidConfiguration }; return url
    }
    public static func decodeQR(_ url: URL, now: Date = .now) throws -> Self {
        guard url.scheme == "aim", url.host == "direct", url.absoluteString.utf8.count <= 8192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.count == 2, parts.queryItems?.first(where: { $0.name == "v" })?.value == "1",
              let encoded = parts.queryItems?.first(where: { $0.name == "ticket" })?.value,
              let bytes = Data(base64Encoded: encoded) else { throw DirectRemoteError.invalidConfiguration }
        let invite = try DirectRemoteCoding.decode(Self.self, bytes); try invite.validate(now: now); return invite
    }
}
public struct DirectRemoteClaim: Codable, Equatable, Sendable {
    public let inviteID: UUID
    public let client: DirectRemotePublicIdentity
    public let proof: Data
    public init(invite: DirectRemoteInvite, client: DirectRemotePublicIdentity, now: Date = .now) throws {
        try invite.validate(now: now)
        guard client.role == .phone, client.id != invite.host.id else { throw DirectRemoteError.unauthorized }
        inviteID = invite.id; self.client = client
        proof = Data(HMAC<SHA256>.authenticationCode(for: try Self.proofBytes(invite: invite, client: client), using: SymmetricKey(data: invite.token)))
    }
    static func proofBytes(invite: DirectRemoteInvite, client: DirectRemotePublicIdentity) throws -> Data {
        Data(("aim-direct-claim/v1/" + invite.id.uuidString + "/" + invite.host.fingerprint + "/").utf8) + (try DirectRemoteCoding.encode(client))
    }
    func validate(invite: DirectRemoteInvite, now: Date) throws {
        try invite.validate(now: now)
        guard inviteID == invite.id, client.version == 1, client.role == .phone,
              client.agreementKey.count == 65, client.signingKey.count == 65,
              HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: try Self.proofBytes(invite: invite, client: client), using: SymmetricKey(data: invite.token)) else { throw DirectRemoteError.unauthorized }
    }
}
public struct DirectRemotePair: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let host: DirectRemotePublicIdentity
    public let client: DirectRemotePublicIdentity
    public let permissions: Set<DirectRemotePermission>
    public var revision: UInt64
    public var revoked: Bool
    public let confirmedAt: Date
    public func other(than identity: DirectRemotePublicIdentity) throws -> DirectRemotePublicIdentity {
        guard version == 1, !revoked, host.id != client.id else { throw DirectRemoteError.revoked }
        if identity == host { return client }; if identity == client { return host }; throw DirectRemoteError.unauthorized
    }
}
public struct DirectRemotePairConfirmation: Codable, Sendable {
    public let pairBytes: Data
    public let hostSignature: Data
    /// Refresh a grant against the already pinned devices, never an expired QR.
    /// Equal revisions are idempotent only when every grant field is identical.
    public func acceptUpdate(current: DirectRemotePair, client: DirectRemoteIdentity) throws -> DirectRemotePair {
        let pair = try DirectRemoteCoding.decode(DirectRemotePair.self, pairBytes)
        guard !current.revoked, current.client == client.publicIdentity,
              pair.version == current.version, pair.id == current.id,
              pair.host == current.host, pair.client == current.client,
              pair.confirmedAt == current.confirmedAt, !pair.revoked,
              pair.permissions.contains(.read), pair.revision >= current.revision,
              pair.revision > current.revision || pair == current else { throw DirectRemoteError.unauthorized }
        try DirectRemoteIdentity.verify(hostSignature, bytes: pairBytes, signer: current.host)
        return pair
    }
    public func accept(invite: DirectRemoteInvite, client: DirectRemoteIdentity, now: Date = .now) throws -> DirectRemotePair {
        try invite.validate(now: now)
        let pair = try DirectRemoteCoding.decode(DirectRemotePair.self, pairBytes)
        guard pair.id == invite.id, pair.host == invite.host, pair.client == client.publicIdentity,
              pair.confirmedAt <= now.addingTimeInterval(5), pair.confirmedAt < invite.expiresAt,
              pair.revision == 1, !pair.revoked else { throw DirectRemoteError.unauthorized }
        try DirectRemoteIdentity.verify(hostSignature, bytes: pairBytes, signer: invite.host)
        _ = try client.sessionKey(pair: pair); return pair
    }
}
/// Only confirmDevice consumes an invitation. Receiving a QR claim grants no access.
public actor DirectRemotePairingHost {
    public let identity: DirectRemoteIdentity
    private let store: any SecureStoring
    private var invitation: DirectRemoteInvite?
    private var pending: [UUID: DirectRemoteClaim] = [:]
    public init(identity: DirectRemoteIdentity, store: any SecureStoring) throws {
        guard identity.publicIdentity.role == .mac else { throw DirectRemoteError.unauthorized }
        self.identity = identity; self.store = store
    }
    private var key: String { "remote-direct.pairing.v1." + identity.publicIdentity.localProfileID.uuidString }
    public func createInvite(coordinatorURL: URL? = nil, now: Date = .now) throws -> DirectRemoteInvite {
        var generator = SystemRandomNumberGenerator()
        let invite = DirectRemoteInvite(version: 1, id: UUID(), host: identity.publicIdentity,
            token: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }),
            expiresAt: now.addingTimeInterval(120), coordinatorURL: coordinatorURL,
            lanService: "AIM-" + identity.publicIdentity.id.uuidString.lowercased())
        try invite.validate(now: now); try store.store(DirectRemoteCoding.encode(invite), forKey: key + ".pending")
        invitation = invite; pending = [:]; return invite
    }
    public func cancelInvitation() throws {
        invitation = nil; pending = [:]
        try store.removeData(forKey: key + ".pending")
    }
    public func propose(_ claim: DirectRemoteClaim, now: Date = .now) throws -> DirectRemotePublicIdentity {
        guard let invitation else { throw DirectRemoteError.expiredInvitation }
        try claim.validate(invite: invitation, now: now)
        guard pending.count < 8 || pending[claim.client.id] != nil else { throw DirectRemoteError.unauthorized }
        pending[claim.client.id] = claim; return claim.client
    }
    public func confirmDevice(_ deviceID: UUID, permissions: Set<DirectRemotePermission>, now: Date = .now) throws -> DirectRemotePairConfirmation {
        guard let invitation, let claim = pending[deviceID], !permissions.isEmpty else { throw DirectRemoteError.unauthorized }
        try claim.validate(invite: invitation, now: now)
        let pair = DirectRemotePair(version: 1, id: invitation.id, host: identity.publicIdentity, client: claim.client,
            permissions: permissions, revision: 1, revoked: false, confirmedAt: now)
        let vault = DirectRemotePairStore(profile: .init(id: identity.publicIdentity.localProfileID), store: store)
        guard try !vault.pairs().contains(where: { $0.pair.id == pair.id }) else { throw DirectRemoteError.unauthorized }
        let bytes = try DirectRemoteCoding.encode(pair), signature = try identity.sign(bytes)
        // Durable consumption precedes sending a confirmation; a failed send never
        // creates another grant. The saved pair can be re-read after reconnect.
        try vault.save(.init(pair: pair, location: .init(invite: invitation)))
        try store.removeData(forKey: key + ".pending"); self.invitation = nil; pending = [:]
        return .init(pairBytes: bytes, hostSignature: signature)
    }
    public func pair(_ id: UUID) throws -> DirectRemotePair {
        let vault = DirectRemotePairStore(profile: .init(id: identity.publicIdentity.localProfileID), store: store)
        guard let pair = try vault.pairs().first(where: { $0.pair.id == id })?.pair,
              pair.host == identity.publicIdentity, !pair.revoked else { throw DirectRemoteError.revoked }
        return pair
    }
    public func signedGrant(_ id: UUID) throws -> DirectRemotePairConfirmation {
        let value = try pair(id), bytes = try DirectRemoteCoding.encode(value)
        return .init(pairBytes: bytes, hostSignature: try identity.sign(bytes))
    }
    /// The host is the sole grant authority. Keep the paired keys, location and
    /// command IDs; a revision fences every old session after a permission edit.
    public func updatePermissions(_ id: UUID, permissions: Set<DirectRemotePermission>) throws -> DirectRemoteSavedPair {
        let vault = DirectRemotePairStore(profile: .init(id: identity.publicIdentity.localProfileID), store: store)
        guard let saved = try vault.pairs().first(where: { $0.pair.id == id }),
              saved.pair.host == identity.publicIdentity, !saved.pair.revoked,
              permissions.contains(.read) else { throw DirectRemoteError.unauthorized }
        let value = saved.pair
        if value.permissions == permissions { return saved }
        guard value.revision < UInt64.max else { throw DirectRemoteError.invalidPacket }
        let updated = DirectRemotePair(version: value.version, id: value.id, host: value.host, client: value.client,
            permissions: permissions, revision: value.revision + 1, revoked: false, confirmedAt: value.confirmedAt)
        let record = DirectRemoteSavedPair(pair: updated, location: saved.location)
        try vault.save(record)
        return record
    }
    public func revoke(_ id: UUID) throws {
        let vault = DirectRemotePairStore(profile: .init(id: identity.publicIdentity.localProfileID), store: store)
        guard let saved = try vault.pairs().first(where: { $0.pair.id == id }), saved.pair.host == identity.publicIdentity else { throw DirectRemoteError.unauthorized }
        var value = saved.pair
        if value.revoked { return }
        guard value.revision < UInt64.max else { throw DirectRemoteError.invalidPacket }
        value.revoked = true; value.revision += 1
        try vault.save(.init(pair: value, location: saved.location))
    }

}
public enum DirectRemoteCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        guard bytes.count <= 4194304 else { throw DirectRemoteError.invalidPacket }; return try JSONDecoder().decode(type, from: bytes)
    }
}
