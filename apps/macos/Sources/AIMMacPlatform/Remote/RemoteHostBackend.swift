import AIMCore
import Foundation
import Supabase

/// A device paired with this account (phone or browser).
public struct RemoteHostDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let paired_at: Date?
    public let last_used_at: Date?
    public let expires_at: Date?
    public let revoked_at: Date?
    public let public_key: String?

    public func isActive(at date: Date = .now) -> Bool {
        revoked_at == nil && (expires_at.map { $0 > date } ?? true)
    }
}

/// A pending phone command addressed to this Mac.
public struct RemoteHostCommand: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let machine_id: String
    public let session_id: String?
    public let type: String
    public let payload: RemoteJSONValue?
    public let status: String
    public let created_at: Date?

    public var identity: RemoteCommandIdentity {
        RemoteCommandIdentity(id: id, type: type, sessionID: session_id, machineID: machine_id)
    }
}

public struct RemoteAccountStopRequest: Codable, Sendable {
    public let id: String
    public let command_ids: [String]
    public let conversation_ids: [String]
}

/// A file the phone uploaded for a message (§6.9): the row is only an index; the
/// encrypted manifest is authoritative.
public struct RemoteHostTransfer: Decodable, Equatable, Sendable {
    public let id: String
    public let machine_id: String
    public let session_id: String
    public let kind: String
    public let key_version: Int
    public let manifest: String
    public let chunk_count: Int
    public let status: String
}

public struct RemotePairingCode: Codable, Equatable, Sendable {
    public let code: String
    public let expiresAt: Date
}

public enum RemoteHostError: LocalizedError, Equatable {
    case server(String), notSignedIn, accountChanged
    public var errorDescription: String? {
        switch self {
        case .accountChanged: "The AIM account changed. This Remote host is stopped; reopen Remote for the current account."
        case .notSignedIn: "Sign in to your AIM account (Settings → Account) to use Remote."
        case .server(let code): "The AIM relay refused the request (\(code))."
        }
    }
}

/// Everything the host needs from the relay; implemented over Supabase, and by fakes in tests.
public protocol RemoteHostBackend: Sendable {
    func register(machineID: String, secret: String, name: String, appVersion: String, capabilities: String?) async throws
    func createPairingCode(machineID: String, secret: String) async throws -> RemotePairingCode
    func devices() async throws -> [RemoteHostDevice]
    func revoke(deviceID: String) async throws
    func putKeys(machineID: String, secret: String, version: Int, envelopes: [(deviceID: String, envelope: RemoteKeyEnvelope)]) async throws
    func pendingCommands(machineID: String) async throws -> [RemoteHostCommand]
    func authorizeCommand(machineID: String, secret: String, commandID: String, conversationID: String?) async throws -> Bool
    func stopRequests(machineID: String, secret: String) async throws -> [RemoteAccountStopRequest]
    func acknowledgeStop(machineID: String, secret: String, requestID: String) async throws
    func commandStatus(commandID: String, machineID: String) async throws -> String?
    func updateCommand(machineID: String, secret: String, commandID: String, status: String, error: String?, result: RemoteJSONValue?) async throws
    func upsert(sessions: [RemoteSessionRow], messages: [RemoteMessageRow]) async throws
    func deleteMessages(sessionID: String, beforeSequence: Int) async throws
    func deleteSessions(machineID: String, keeping ids: Set<String>) async throws
    /// Fires when a command row for this machine is inserted (best effort; the host also polls).
    func commandSignals(machineID: String) async -> AsyncStream<Void>
    func userID() async throws -> String
    func diagnosticRelayIdentifier() async -> String?
    func transfer(id: String) async throws -> RemoteHostTransfer?
    func downloadBlock(path: String) async throws -> Data
    func publishResultTransfer(_ transfer: RemoteEncryptedTransfer, key: Data) async throws
    func deleteTransfer(id: String, paths: [String]) async throws
}

public extension RemoteHostBackend {
    func authorizeCommand(machineID: String, secret: String, commandID: String, conversationID: String?) async throws -> Bool { false }
    func stopRequests(machineID: String, secret: String) async throws -> [RemoteAccountStopRequest] { [] }
    func acknowledgeStop(machineID: String, secret: String, requestID: String) async throws { throw RemoteHostError.server("stop_confirmation_unsupported") }
    func diagnosticRelayIdentifier() async -> String? { nil }
    func publishResultTransfer(_ transfer: RemoteEncryptedTransfer, key: Data) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        throw RemoteHostError.server("result_transfer_unavailable")
    }
    func commandStatus(commandID: String, machineID: String) async throws -> String? { nil }
}

/// An ok flag alone does not prove that any envelope was stored. The relay
/// skips rejected device/version entries and reports their accepted count.
struct RemoteKeyPublicationReceipt: Decodable {
    let ok: Bool
    let error: String?
    let stored: Int?

    func requireComplete(expected: Int) throws {
        guard ok else { throw RemoteHostError.server(error ?? "key_publication_refused") }
        guard let stored else { throw RemoteHostError.server("key_publication_receipt_missing") }
        guard stored == expected else { throw RemoteHostError.server("key_publication_incomplete") }
    }
}

public final class SupabaseRemoteHostBackend: RemoteHostBackend, @unchecked Sendable {
    private let client: SupabaseClient
    private let relayIdentifier: String?

    public init(client: SupabaseClient, relayURL: URL? = nil) {
        self.client = client
        let configured = HostBundleResources.applicationBundle.object(forInfoDictionaryKey: "AIMSupabaseURL") as? String
        let url = relayURL ?? configured.flatMap { URL(string: $0) }
        relayIdentifier = url?.host.map(RemoteDiagnosticPrivacy.identifier)
    }

    private struct Response: Decodable { let ok: Bool; let error: String?; let code: String?; let expires_at: Date? }

    private func check(_ response: Response) throws -> Response {
        guard response.ok else { throw RemoteHostError.server(response.error ?? "unknown") }
        return response
    }

    private func ensureSession() async throws {
        do { _ = try await client.auth.session } catch { throw RemoteHostError.notSignedIn }
    }

    public func authorizeCommand(machineID: String, secret: String, commandID: String, conversationID: String?) async throws -> Bool {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Params: Encodable { let p_machine_id: String; let p_secret: String; let p_command_id: String; let p_conversation_id: String? }
        return try await client.rpc("aim_remote_command_authorized", params: Params(p_machine_id: machineID, p_secret: secret, p_command_id: commandID, p_conversation_id: conversationID)).execute().value
    }
    public func stopRequests(machineID: String, secret: String) async throws -> [RemoteAccountStopRequest] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Params: Encodable { let p_machine_id: String; let p_secret: String }
        return try await client.rpc("aim_remote_stop_requests", params: Params(p_machine_id: machineID, p_secret: secret)).execute().value
    }
    public func acknowledgeStop(machineID: String, secret: String, requestID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Params: Encodable { let p_machine_id: String; let p_secret: String; let p_request_id: String }
        try await client.rpc("aim_ack_remote_stop", params: Params(p_machine_id: machineID, p_secret: secret, p_request_id: requestID)).execute()
    }

    public func register(machineID: String, secret: String, name: String, appVersion: String, capabilities: String?) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await ensureSession()
        struct Params: Encodable {
            let p_machine_id: String, p_name: String, p_platform: String, p_app_version: String, p_secret: String
            let p_capabilities: String?
        }
        let response: Response = try await client.rpc("remote_register_machine", params: Params(
            p_machine_id: machineID, p_name: name, p_platform: "macos", p_app_version: appVersion, p_secret: secret,
            p_capabilities: capabilities)).execute().value
        _ = try check(response)
        struct HostAuthorization: Encodable { let p_machine_id: String; let p_secret: String }
        try await client.rpc("aim_register_remote_host", params: HostAuthorization(p_machine_id: machineID, p_secret: secret)).execute()
    }

    public func createPairingCode(machineID: String, secret: String) async throws -> RemotePairingCode {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await ensureSession()
        struct Params: Encodable { let p_machine_id: String, p_secret: String }
        let response = try check(try await client.rpc("remote_create_pairing_code",
            params: Params(p_machine_id: machineID, p_secret: secret)).execute().value)
        guard let code = response.code else { throw RemoteHostError.server("no_code") }
        return RemotePairingCode(code: code, expiresAt: response.expires_at ?? .now.addingTimeInterval(300))
    }

    public func devices() async throws -> [RemoteHostDevice] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await ensureSession()
        return try await client.from("remote_devices")
            .select("id,name,paired_at,last_used_at,expires_at,revoked_at,public_key")
            .order("paired_at", ascending: false).execute().value
    }

    public func revoke(deviceID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Update: Encodable { let revoked_at: Date }
        try await client.from("remote_devices").update(Update(revoked_at: .now)).eq("id", value: deviceID).execute()
    }

    public func diagnosticRelayIdentifier() async -> String? {
        relayIdentifier
    }

    public func putKeys(machineID: String, secret: String, version: Int,
                        envelopes: [(deviceID: String, envelope: RemoteKeyEnvelope)]) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await ensureSession()
        struct Item: Encodable { let device_id: String; let envelope: RemoteKeyEnvelope }
        struct Params: Encodable { let p_machine_id: String, p_secret: String, p_key_version: Int, p_envelopes: [Item] }
        for batch in Self.keyPublicationBatches(envelopes) {
            try AIMNetworkPrivacyPolicy.requireNetwork()
            let receipt: RemoteKeyPublicationReceipt = try await client.rpc("remote_put_device_keys", params: Params(
                p_machine_id: machineID, p_secret: secret, p_key_version: version,
                p_envelopes: batch.map { Item(device_id: $0.deviceID, envelope: $0.envelope) })).execute().value
            try receipt.requireComplete(expected: batch.count)
        }
    }

    static func keyPublicationBatches(_ envelopes: [(deviceID: String, envelope: RemoteKeyEnvelope)]) -> [[(deviceID: String, envelope: RemoteKeyEnvelope)]] {
        stride(from: 0, to: envelopes.count, by: 10).map { Array(envelopes[$0..<min($0 + 10, envelopes.count)]) }
    }

    public func pendingCommands(machineID: String) async throws -> [RemoteHostCommand] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await client.from("remote_commands")
            .select("id,machine_id,session_id,type,payload,status,created_at")
            .eq("machine_id", value: machineID).eq("status", value: "pending")
            .order("created_at", ascending: true).limit(20).execute().value
    }

    public func updateCommand(machineID: String, secret: String, commandID: String, status: String,
                              error: String?, result: RemoteJSONValue?) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Params: Encodable {
            let p_machine_id: String, p_secret: String, p_command_id: String, p_status: String
            let p_error: String?, p_result: RemoteJSONValue?
        }
        _ = try check(try await client.rpc("remote_update_command", params: Params(
            p_machine_id: machineID, p_secret: secret, p_command_id: commandID, p_status: status,
            p_error: error.map { String($0.prefix(200)) }, p_result: result)).execute().value)
    }

    public func commandStatus(commandID: String, machineID: String) async throws -> String? {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await ensureSession()
        struct Row: Decodable { let status: String }
        let rows: [Row] = try await client.from("remote_commands").select("status")
            .eq("id", value: commandID).eq("machine_id", value: machineID).limit(1).execute().value
        return rows.first?.status
    }

    public func upsert(sessions: [RemoteSessionRow], messages: [RemoteMessageRow]) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        if !sessions.isEmpty {
            do { try await client.from("remote_sessions").upsert(sessions, onConflict: "id").execute() }
            catch {
                // PGRST204 schema validation rejects this entire statement before
                // effects. Only this exact absent column permits one legacy retry.
                guard Self.isMissingArchiveColumn(error) else { throw error }
                let legacy = try Self.legacySessions(sessions)
                try AIMNetworkPrivacyPolicy.requireNetwork()
                try await client.from("remote_sessions").upsert(legacy, onConflict: "id").execute()
            }
        }
        if !messages.isEmpty { try await client.from("remote_messages").upsert(messages, onConflict: "id").execute() }
    }

    static func isMissingArchiveColumn(_ error: any Error) -> Bool {
        guard let error = error as? PostgrestError else { return false }
        return error.code == "PGRST204" && error.message == "Could not find the 'archived_at' column of 'remote_sessions' in the schema cache"
    }
    static func legacySessions(_ rows: [RemoteSessionRow]) throws -> [RemoteLegacySessionPayload] {
        guard rows.allSatisfy({ $0.archived_at == nil }) else { throw RemoteHostError.server("archive_schema_unavailable") }
        return rows.map { RemoteLegacySessionPayload(row: $0) }
    }

    public func deleteMessages(sessionID: String, beforeSequence: Int) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await client.from("remote_messages").delete().eq("session_id", value: sessionID)
            .lt("seq", value: beforeSequence).execute()
    }

    public func deleteSessions(machineID: String, keeping ids: Set<String>) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        var query = client.from("remote_sessions").delete().eq("machine_id", value: machineID)
        if !ids.isEmpty { query = query.not("id", operator: .in, value: "(\(ids.sorted().joined(separator: ",")))") }
        try await query.execute()
    }

    public func userID() async throws -> String {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { return try await client.auth.session.user.id.uuidString.lowercased() } catch { throw RemoteHostError.notSignedIn }
    }

    public func publishResultTransfer(_ transfer: RemoteEncryptedTransfer, key: Data) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        struct Row: Encodable {
            let id: String, user_id: String, machine_id: String, session_id: String, kind: String
            let key_version: Int, manifest: String, chunk_count: Int, expires_at: String, status: String
        }
        struct Ready: Encodable { let status = "ready" }
        let owner = try await userID()
        let manifest = transfer.manifest
        if let existing = try await self.transfer(id: manifest.transferID), existing.status == "ready",
           let saved = try? RemoteTransferCrypto.openManifest(existing.manifest, transferID: manifest.transferID,
                keys: [manifest.keyVersion: key]), saved.machineID == manifest.machineID, saved.sessionID == manifest.sessionID,
           saved.kind == .detail, saved.sha256 == manifest.sha256, saved.clearSize == manifest.clearSize {
            return // A delivery retry never replaces blocks while the phone reads them.
        }
        let row = Row(id: manifest.transferID, user_id: owner, machine_id: manifest.machineID,
            session_id: manifest.sessionID, kind: manifest.kind.rawValue, key_version: manifest.keyVersion,
            manifest: try RemoteTransferCrypto.sealManifest(manifest, key: key), chunk_count: manifest.chunkCount,
            expires_at: manifest.expiresAt, status: "uploading")
        try await client.from("remote_transfers").upsert(row).execute()
        for block in transfer.blocks {
            try Task.checkCancellation()
            guard try await userID() == owner else { throw RemoteHostError.notSignedIn }
            let path = try RemoteTransferCrypto.storagePath(userID: owner, manifest: manifest, index: block.index)
            try await client.storage.from("remote-transfers").upload(path, data: block.encrypted,
                options: FileOptions(contentType: "application/octet-stream", upsert: true))
        }
        try await client.from("remote_transfers").update(Ready()).eq("id", value: manifest.transferID).execute()
    }

    public func transfer(id: String) async throws -> RemoteHostTransfer? {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let rows: [RemoteHostTransfer] = try await client.from("remote_transfers")
            .select("id,machine_id,session_id,kind,key_version,manifest,chunk_count,status")
            .eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    public func downloadBlock(path: String) async throws -> Data {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await client.storage.from("remote-transfers").download(path: path)
    }

    public func deleteTransfer(id: String, paths: [String]) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        if !paths.isEmpty { _ = try? await client.storage.from("remote-transfers").remove(paths: paths) }
        try await client.from("remote_transfers").delete().eq("id", value: id).execute()
    }

    public func commandSignals(machineID: String) async -> AsyncStream<Void> {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { return AsyncStream { $0.finish() } }
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await _ in AIMNativeRealtime.changes(client: client, subscriptions: [
                        AIMRealtimeSubscription(table: "remote_commands", event: "INSERT", filter: "machine_id=eq." + machineID)]) {
                        continuation.yield()
                    }
                } catch { }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Used only after the exact archived_at schema refusal; never silently drops an archive date.
struct RemoteLegacySessionPayload: Encodable {
    let row: RemoteSessionRow
    func encode(to encoder: any Encoder) throws { try row.encode(to: encoder, includingArchive: false) }
}
