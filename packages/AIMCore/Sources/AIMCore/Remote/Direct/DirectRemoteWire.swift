import CryptoKit
import Foundation

public struct DirectRemotePacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case signal, request, reply, event }
    public let version: Int
    public let pairID: UUID
    public let revision: UInt64
    public let sender: UUID
    public let recipient: UUID
    public let id: UUID
    public let sequence: UInt64
    public let kind: Kind
    public let ciphertext: String
    fileprivate var context: RemoteFieldContext {
        .init(table: "remote_direct_v1", column: kind.rawValue,
            rowID: "\(pairID)|\(revision)|\(sender)|\(recipient)|\(id)|\(sequence)")
    }
}
public enum DirectRemoteCipher {
    public static func seal(_ bytes: Data, identity: DirectRemoteIdentity, pair: DirectRemotePair,
                            id: UUID, sequence: UInt64, kind: DirectRemotePacket.Kind) throws -> DirectRemotePacket {
        guard bytes.count <= 65536, sequence > 0 else { throw DirectRemoteError.invalidPacket }
        let other = try pair.other(than: identity.publicIdentity)
        let header = DirectRemotePacket(version: 1, pairID: pair.id, revision: pair.revision,
            sender: identity.publicIdentity.id, recipient: other.id, id: id, sequence: sequence, kind: kind, ciphertext: "")
        let ciphertext = try RemoteCrypto.encryptField(bytes.base64EncodedString(), key: identity.sessionKey(pair: pair), version: 1, context: header.context)
        return .init(version: 1, pairID: pair.id, revision: pair.revision, sender: header.sender,
            recipient: header.recipient, id: id, sequence: sequence, kind: kind, ciphertext: ciphertext)
    }
    public static func open(_ packet: DirectRemotePacket, identity: DirectRemoteIdentity, pair: DirectRemotePair) throws -> Data {
        let other = try pair.other(than: identity.publicIdentity)
        guard packet.version == 1, packet.pairID == pair.id, packet.revision == pair.revision,
              packet.sender == other.id, packet.recipient == identity.publicIdentity.id,
              packet.sequence > 0, packet.ciphertext.utf8.count <= 120000 else { throw DirectRemoteError.invalidPacket }
        let encoded = try RemoteCrypto.decryptField(packet.ciphertext, keys: [1: identity.sessionKey(pair: pair)], context: packet.context)
        guard let bytes = Data(base64Encoded: encoded), bytes.count <= 65536 else { throw DirectRemoteError.invalidPacket }
        return bytes
    }
}
public struct DirectRemoteLocation: Codable, Equatable, Sendable {
    public let coordinatorURL: URL?
    public let lanService: String
    public init(invite: DirectRemoteInvite) { coordinatorURL = invite.coordinatorURL; lanService = invite.lanService }
}
public struct DirectRemoteSavedPair: Codable, Equatable, Sendable {
    public let pair: DirectRemotePair
    public let location: DirectRemoteLocation
    public init(pair: DirectRemotePair, location: DirectRemoteLocation) { self.pair = pair; self.location = location }
}
public struct DirectRemotePairStore: Sendable {
    private let profile: LocalProfile
    private let store: any SecureStoring
    public init(profile: LocalProfile, store: any SecureStoring) { self.profile = profile; self.store = store }
    private var key: String { "remote-direct.saved-pairs.v1." + profile.id.uuidString }
    public func pairs() throws -> [DirectRemoteSavedPair] {
        guard let bytes = try store.readData(forKey: key) else { return [] }
        let values = try DirectRemoteCoding.decode([DirectRemoteSavedPair].self, bytes)
        guard values.count <= 16, values.allSatisfy({ $0.pair.host.localProfileID == profile.id || $0.pair.client.localProfileID == profile.id }) else { throw DirectRemoteError.invalidConfiguration }
        return values
    }
    public func save(_ value: DirectRemoteSavedPair) throws {
        guard value.pair.host.localProfileID == profile.id || value.pair.client.localProfileID == profile.id else { throw DirectRemoteError.unauthorized }
        var current = try pairs()
        if let index = current.firstIndex(where: { $0.pair.id == value.pair.id }) {
            let prior = current[index].pair
            guard value.pair.revision >= prior.revision,
                  value.pair.host == prior.host, value.pair.client == prior.client,
                  value.pair.version == prior.version, value.pair.confirmedAt == prior.confirmedAt,
                  !prior.revoked || value.pair == prior,
                  value.pair.revision > prior.revision || value.pair == prior else { throw DirectRemoteError.unauthorized }
            current[index] = value
        } else { guard current.count < 16 else { throw DirectRemoteError.invalidConfiguration }; current.append(value) }
        try store.store(DirectRemoteCoding.encode(current), forKey: key)
    }
}
public enum DirectRemoteTransportPath: String, Codable, Sendable { case lan, peerToPeer, turn }
public enum DirectRemoteConnectionState: Equatable, Sendable {
    case disconnected, signalling, gatheringICE, checkingICE
    case connected(DirectRemoteTransportPath)
    case reconnecting, revoked, failed(String)
}
public struct DirectRemoteICEServer: Codable, Equatable, Sendable {
    public let url: String
    public let username: String?
    public let credential: String?
    public let expiresAt: Date?
    public init(url: String, username: String? = nil, credential: String? = nil, expiresAt: Date? = nil) {
        self.url = url; self.username = username; self.credential = credential; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case url, username, credential, expiresAt, expiresAtUnix }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        credential = try values.decodeIfPresent(String.self, forKey: .credential)
        if let unix = try values.decodeIfPresent(Double.self, forKey: .expiresAtUnix) { expiresAt = Date(timeIntervalSince1970: unix) }
        else { expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt) }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url); try values.encodeIfPresent(username, forKey: .username)
        try values.encodeIfPresent(credential, forKey: .credential)
        try values.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAtUnix)
    }
    public func nativeURL(now: Date = .now) throws -> String {
        guard url.utf8.count <= 512, ["stun:","turn:","turns:"].contains(where: url.hasPrefix),
              expiresAt.map({ $0 > now }) ?? true else { throw DirectRemoteError.invalidConfiguration }
        guard let username, let credential else { return url }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard username.utf8.count <= 256, credential.utf8.count <= 256,
              let user = username.addingPercentEncoding(withAllowedCharacters: allowed),
              let password = credential.addingPercentEncoding(withAllowedCharacters: allowed), let colon = url.firstIndex(of: ":") else { throw DirectRemoteError.invalidConfiguration }
        return String(url[...colon]) + user + ":" + password + "@" + url[url.index(after: colon)...]
    }
}
public enum DirectRemoteNativeEvent: Sendable {
    case description(sdp: String, type: String)
    case candidate(value: String, mid: String)
    case state(DirectRemoteConnectionState)
    case data(Data)
}
/// Concrete libdatachannel implementation lives in AIMDirectNative. Core never
/// claims connectivity based on a WebSocket connection or an injected factory.
public protocol DirectRemoteDataChannel: Sendable {
    var events: AsyncStream<DirectRemoteNativeEvent> { get }
    func createOffer() throws
    func acceptDescription(sdp: String, type: String) throws
    func acceptCandidate(value: String, mid: String) throws
    func send(_ bytes: Data) throws
    func close()
}
public actor DirectRemoteSequenceStore {
    private let store: any SecureStoring
    private let namespace: String
    public init(profile: LocalProfile, deviceID: UUID, store: any SecureStoring) {
        self.store = store; namespace = "remote-direct.sequence.v1." + profile.id.uuidString + "." + deviceID.uuidString
    }
    public func next(pairID: UUID) throws -> UInt64 {
        let key = namespace + "." + pairID.uuidString
        let old = try store.readData(forKey: key).map { try DirectRemoteCoding.decode(UInt64.self, $0) } ?? 0
        guard old < UInt64.max else { throw DirectRemoteError.invalidPacket }
        let value = old + 1; try store.store(DirectRemoteCoding.encode(value), forKey: key); return value
    }
}
