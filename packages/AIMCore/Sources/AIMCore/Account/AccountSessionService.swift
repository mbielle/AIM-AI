import Foundation
import Supabase

public struct AccountSession: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let device: String
    public let platform: String
    public let lastActiveAt: Date?
    public let isCurrent: Bool
    public let revokedAt: Date?
    public let stopState: String?
    public init(id: UUID, device: String, platform: String, lastActiveAt: Date?, isCurrent: Bool, revokedAt: Date? = nil, stopState: String? = nil) {
        self.id = id; self.device = device; self.platform = platform; self.lastActiveAt = lastActiveAt
        self.isCurrent = isCurrent; self.revokedAt = revokedAt; self.stopState = stopState
    }
    enum CodingKeys: String, CodingKey { case id, device, platform; case lastActiveAt = "last_active_at", isCurrent = "is_current", revokedAt = "revoked_at", stopState = "stop_state" }
}
public enum SessionRevocationScope: Sendable { case session(UUID), others, all }
public struct SessionRevocationReceipt: Codable, Sendable {
    public let revokedIDs: [UUID]
    public let stopRequested: Bool
    public let currentRevoked: Bool
    enum CodingKeys: String, CodingKey { case revokedIDs = "revoked_ids", stopRequested = "stop_requested", currentRevoked = "current_revoked" }
}
public protocol AccountSessionServicing: Sendable {
    func register(device: String, platform: String) async throws
    func sessions() async throws -> [AccountSession]
    func acknowledgeLocalStop() async throws
    func revoke(_ scope: SessionRevocationScope) async throws -> SessionRevocationReceipt
}
public extension AccountSessionServicing {
    func acknowledgeLocalStop() async throws { throw AccountServiceError.unavailable }
}
public enum AccountServiceError: LocalizedError {
    case updateRequired, revoked, unavailable, conflict
    public var errorDescription: String? {
        switch self {
        case .updateRequired: "This feature requires the prepared server update."
        case .revoked: "This account session has been disconnected. Sign in again."
        case .unavailable: "The account service is unavailable. Try again."
        case .conflict: "These settings changed on another device. Refresh before saving."
        }
    }
}
public actor AccountSessionService: AccountSessionServicing {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }
    public func register(device: String, platform: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { try await client.rpc("aim_register_account_session", params: Registration(device: String(device.prefix(120)), platform: String(platform.prefix(80)))).execute() }
        catch { throw Self.failure(error) }
    }
    public func acknowledgeLocalStop() async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { try await client.rpc("aim_ack_local_session_stop").execute() }
        catch { throw Self.failure(error) }
    }
    public func sessions() async throws -> [AccountSession] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { return try await client.rpc("aim_account_sessions").execute().value }
        catch { throw Self.failure(error) }
    }
    public func revoke(_ scope: SessionRevocationScope) async throws -> SessionRevocationReceipt {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let request: Revocation
        switch scope {
        case .session(let id): request = .init(scope: "session", sessionID: id)
        case .others: request = .init(scope: "others", sessionID: nil)
        case .all: request = .init(scope: "all", sessionID: nil)
        }
        do { return try await client.rpc("aim_revoke_account_sessions", params: request).execute().value }
        catch { throw Self.failure(error) }
    }
    #if DEBUG
    /// Qualification only: the last server error behind a mapped account failure.
    nonisolated(unsafe) public static var lastFailureDescription: String?
    #endif
    static func failure(_ error: Error) -> AccountServiceError {
        #if DEBUG
        lastFailureDescription = String(describing: error)
        #endif
        if let pg = error as? PostgrestError {
            if pg.code == "PGRST202" { return .updateRequired }
            if pg.message.contains("session_revoked") { return .revoked }
            if pg.message.contains("revision_conflict") { return .conflict }
        }
        return .unavailable
    }
    private struct Registration: Encodable { let device: String; let platform: String; enum CodingKeys: String, CodingKey { case device = "p_device", platform = "p_platform" } }
    private struct Revocation: Encodable { let scope: String; let sessionID: UUID?; enum CodingKeys: String, CodingKey { case scope = "p_scope", sessionID = "p_session_id" } }
}

public struct AccountDocument: Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var payload: String
    public var revision: Int
    public var deleted: Bool
    public init(id: UUID, kind: String, payload: String, revision: Int = 0, deleted: Bool = false) {
        self.id = id; self.kind = kind; self.payload = payload; self.revision = revision; self.deleted = deleted
    }
}
public protocol AccountContentSyncing: Sendable {
    func documents(accountID: UUID) async throws -> [AccountDocument]
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument
}
public actor AccountContentSyncService: AccountContentSyncing {
    public nonisolated var media: AccountMediaService { AccountMediaService(client: client) }
    private let client: SupabaseClient
    public nonisolated let notifications: AccountNotificationService
    public init(client: SupabaseClient) { self.client = client; notifications = AccountNotificationService(client: client) }
    public func documents(accountID: UUID) async throws -> [AccountDocument] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { return try await client.rpc("aim_account_documents", params: Read(accountID: accountID)).execute().value }
        catch { throw AccountSessionService.failure(error) }
    }
    public func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { return try await client.rpc("aim_put_account_document", params: Write(accountID: accountID, document: document)).execute().value }
        catch { throw AccountSessionService.failure(error) }
    }
    private struct Read: Encodable { let accountID: UUID; enum CodingKeys: String, CodingKey { case accountID = "p_account_id" } }
    private struct Write: Encodable {
        let accountID: UUID
        let document: AccountDocument
        enum CodingKeys: String, CodingKey { case document = "p_document"; case accountID = "p_account_id" }
    }
}
