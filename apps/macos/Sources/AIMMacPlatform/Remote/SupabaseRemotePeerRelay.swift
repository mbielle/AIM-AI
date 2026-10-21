import AIMCore
import AIMApplication
import Foundation
import Supabase

/// Transport only. Authentication and the existing Remote machine secret are both
/// required by the additive RPC. Missing deployment is a hard unavailable result.
public final class SupabaseRemotePeerRelay: RemotePeerRelaying, @unchecked Sendable {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }
    public func call(_ operation: RemotePeerRelayOperation, machineID: UUID, secret: String, payload: Data) async throws -> Data {
        try RuntimePrivacyPolicy.requireNetwork()
        guard payload.count <= 524288, let text = String(data: payload, encoding: .utf8) else {
            throw RemotePeerError.invalidEnvelope
        }
        _ = try await client.auth.session
        struct Parameters: Encodable { let p_operation: String; let p_machine_id: UUID; let p_secret: String; let p_payload: String }
        struct Response: Decodable { let ok: Bool; let error: String?; let payload_text: String? }
        let response: Response = try await client.rpc("remote_peer_v1", params: Parameters(p_operation: operation.rawValue,
            p_machine_id: machineID, p_secret: secret, p_payload: text)).execute().value
        try RuntimePrivacyPolicy.requireNetwork()
        guard response.ok else { throw RemotePeerError.rejected(response.error ?? "relay_refused") }
        guard let result = response.payload_text, result.utf8.count <= 4 * 1024 * 1024 else {
            throw RemotePeerError.invalidEnvelope
        }
        return Data(result.utf8)
    }
}
