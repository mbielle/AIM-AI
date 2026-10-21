import AIMCore
import Foundation

package struct RuntimePeerControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case status, preview, importConfiguration, register, identities, pairs, propose, accept, revoke }
    package var version = 1
    package var action: Action
    package var configuration: Data?
    package var pairID: UUID?
    package var identity: RemotePeerPublicIdentity?
    package var confirmedFingerprint: String?
    package var expiresAt: Date?
    package var pair: RemotePeerPair?
    package init(action: Action, configuration: Data? = nil, pairID: UUID? = nil, identity: RemotePeerPublicIdentity? = nil,
        confirmedFingerprint: String? = nil, expiresAt: Date? = nil, pair: RemotePeerPair? = nil) {
        self.action = action; self.configuration = configuration; self.pairID = pairID; self.identity = identity
        self.confirmedFingerprint = confirmedFingerprint; self.expiresAt = expiresAt; self.pair = pair
    }
}
extension RuntimePeerRouter {
    package func handleControl(_ data: Data) async throws -> Data {
        guard data.count <= 98304 else { throw RemotePeerError.invalidEnvelope }
        let command = try RemotePeerCoding.decode(RuntimePeerControl.self, data)
        guard command.version == 1 else { throw RemotePeerError.invalidEnvelope }
        switch command.action {
        case .status: return try RemotePeerCoding.encode(await status())
        case .preview:
            guard let data = command.configuration else { throw RemotePeerError.invalidConfiguration }
            return try RemotePeerCoding.encode(await previewConfiguration(data))
        case .importConfiguration:
            guard let data = command.configuration else { throw RemotePeerError.invalidConfiguration }
            try await importConfiguration(data)
        case .register: try await registerIdentity()
        case .identities: return try RemotePeerCoding.encode(await identities())
        case .pairs: return try RemotePeerCoding.encode(await listedPairs())
        case .propose:
            guard let id = command.pairID, let identity = command.identity, let fingerprint = command.confirmedFingerprint,
                  let expiresAt = command.expiresAt else { throw RemotePeerError.invalidConfiguration }
            return try RemotePeerCoding.encode(await propose(pairID: id, peer: identity, confirmedFingerprint: fingerprint, expiresAt: expiresAt))
        case .accept:
            guard let pair = command.pair, let fingerprint = command.confirmedFingerprint else { throw RemotePeerError.invalidConfiguration }
            try await accept(pair, confirmedFingerprint: fingerprint)
        case .revoke:
            guard let id = command.pairID else { throw RemotePeerError.invalidConfiguration }; try await revoke(pairID: id)
        }
        return try RemotePeerCoding.encode(await status())
    }
}
