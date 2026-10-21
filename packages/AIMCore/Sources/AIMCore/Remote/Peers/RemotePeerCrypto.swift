import CryptoKit
import Foundation

/// Purpose-separated keys anchored by the existing Remote machine UUID/secret RPC proof.
/// Does not distribute the mirror key or machine secret to another Mac.
public struct RemotePeerPrivateIdentity: Codable, Sendable {
    public let machineID: UUID
    private let agreement: Data
    private let signing: Data
    public init(machineID: UUID) {
        self.machineID = machineID; agreement = P256.KeyAgreement.PrivateKey().rawRepresentation
        signing = P256.Signing.PrivateKey().rawRepresentation
    }
    public var publicIdentity: RemotePeerPublicIdentity {
        get throws {
            RemotePeerPublicIdentity(machineID: machineID,
                agreementKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement).publicKey.x963Representation,
                signingKey: try P256.Signing.PrivateKey(rawRepresentation: signing).publicKey.x963Representation)
        }
    }
    public static func loadOrCreate(machineID: UUID, store: any SecureStoring) throws -> Self {
        let key = "remote-peer-identity-v1-\(machineID.uuidString.lowercased())"
        if let data = try store.readData(forKey: key) {
            let value = try RemotePeerCoding.decode(Self.self, data)
            guard value.machineID == machineID else { throw RemotePeerError.invalidConfiguration }
            _ = try value.publicIdentity; return value
        }
        let value = Self(machineID: machineID); try store.store(RemotePeerCoding.encode(value), forKey: key); return value
    }
    public func sign(_ grant: RemotePeerGrant) throws -> RemotePeerSignedGrant {
        guard grant.originMachineID == machineID else { throw RemotePeerError.unauthorized }
        return RemotePeerSignedGrant(grant: grant, signature: try signingKey().signature(for: RemotePeerCoding.encode(grant)).derRepresentation)
    }
    public func seal<T: Encodable>(_ value: T, pair: RemotePeerPair, to: UUID, commandID: UUID,
                                  kind: RemotePeerPacket.Kind) throws -> RemotePeerPacket {
        guard to != machineID else { throw RemotePeerError.unauthorized }
        let template = RemotePeerPacket(pairID: pair.id, accountID: pair.accountID, from: machineID, to: to,
            commandID: commandID, kind: kind, ciphertext: Data(), signature: Data())
        let plaintext = try RemotePeerCoding.encode(value)
        guard plaintext.count <= 262144 else { throw RemotePeerError.invalidEnvelope }
        let ciphertext = try AES.GCM.seal(plaintext, using: sessionKey(pair), authenticating: template.associatedData).combined!
        let signature = try signingKey().signature(for: template.associatedData + ciphertext).derRepresentation
        return RemotePeerPacket(pairID: pair.id, accountID: pair.accountID, from: machineID, to: to,
            commandID: commandID, kind: kind, ciphertext: ciphertext, signature: signature)
    }
    public func open<T: Decodable>(_ type: T.Type, packet: RemotePeerPacket, pair: RemotePeerPair) throws -> T {
        guard packet.version == 1, packet.pairID == pair.id, packet.accountID == pair.accountID,
              packet.to == machineID, packet.from != machineID, packet.ciphertext.count <= 262172 else {
            throw RemotePeerError.invalidEnvelope
        }
        let sender = try pair.identity(for: packet.from)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: packet.signature)
        guard try P256.Signing.PublicKey(x963Representation: sender.signingKey)
            .isValidSignature(signature, for: packet.associatedData + packet.ciphertext) else { throw RemotePeerError.invalidEnvelope }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.ciphertext),
                                        using: sessionKey(pair), authenticating: packet.associatedData)
        return try RemotePeerCoding.decode(type, plaintext)
    }
    public static func verify(_ value: RemotePeerSignedGrant, origin: RemotePeerPublicIdentity) throws {
        guard value.grant.originMachineID == origin.machineID else { throw RemotePeerError.unauthorized }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: value.signature)
        guard try P256.Signing.PublicKey(x963Representation: origin.signingKey)
            .isValidSignature(signature, for: RemotePeerCoding.encode(value.grant)) else { throw RemotePeerError.unauthorized }
    }
    public static func fingerprint(_ identity: RemotePeerPublicIdentity) throws -> String {
        SHA256.hash(data: try RemotePeerCoding.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }
    private func signingKey() throws -> P256.Signing.PrivateKey { try .init(rawRepresentation: signing) }
    private func sessionKey(_ pair: RemotePeerPair) throws -> SymmetricKey {
        guard try pair.identity(for: machineID) == publicIdentity else { throw RemotePeerError.unauthorized }
        let other = machineID == pair.origin.machineID ? pair.worker : pair.origin
        let secret = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement)
            .sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: other.agreementKey))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data("aim-peer/v1|\(pair.accountID)|\(pair.id)".utf8),
            sharedInfo: try RemotePeerCoding.encode([pair.origin, pair.worker]), outputByteCount: 32)
    }
}
