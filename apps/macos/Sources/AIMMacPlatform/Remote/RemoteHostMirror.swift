import AIMCore
import Foundation

/// One AIM conversation as the phone sees it (protocol v2 §2).
public struct RemoteHostSessionSnapshot: Equatable, Sendable {
    public var id: String
    public var mode: String
    public var title: String
    public var workspace: String?
    public var modelID: String?
    public var approvalMode: String?
    public var agentSystem: String?
    public var status: String
    public var phase: String?
    public var pendingApproval: RemoteJSONValue?
    public var interrupted: Bool
    public var silence: Bool
    public var runStartedAt: Date?
    public var updatedAt: Date
    public var archivedAt: Date?
    public var messages: [RemoteHostMessageSnapshot]
    public var executionDeviceIDs: [String]?
    public var latestResponseVersion: ConversationResponseVersion?

    public init(id: String, mode: String, title: String, workspace: String? = nil, modelID: String? = nil,
                approvalMode: String? = nil, agentSystem: String? = nil, status: String = "idle", phase: String? = nil,
                pendingApproval: RemoteJSONValue? = nil, interrupted: Bool = false, silence: Bool = false,
                runStartedAt: Date? = nil, updatedAt: Date, messages: [RemoteHostMessageSnapshot], archivedAt: Date? = nil, executionDeviceIDs: [String]? = nil, latestResponseVersion: ConversationResponseVersion? = nil) {
        self.id = id; self.mode = mode; self.title = title; self.workspace = workspace; self.modelID = modelID
        self.approvalMode = approvalMode; self.agentSystem = agentSystem; self.status = status; self.phase = phase
        self.pendingApproval = pendingApproval; self.interrupted = interrupted; self.silence = silence
        self.runStartedAt = runStartedAt; self.updatedAt = updatedAt; self.messages = messages; self.archivedAt = archivedAt
        self.executionDeviceIDs = executionDeviceIDs; self.latestResponseVersion = latestResponseVersion
    }
}

public struct RemoteHostMessageSnapshot: Equatable, Sendable {
    public var id: String
    public var sequence: Int
    public var role: String
    public var content: String
    public var model: String?
    public var reasoning: String?
    public var toolCalls: RemoteJSONValue?
    public var timeline: RemoteJSONValue?
    public var runStats: RemoteJSONValue?
    public var createdAt: Date

    public init(id: String, sequence: Int, role: String, content: String, model: String? = nil, reasoning: String? = nil,
                toolCalls: RemoteJSONValue? = nil, timeline: RemoteJSONValue? = nil, runStats: RemoteJSONValue? = nil, createdAt: Date) {
        self.id = id; self.sequence = sequence; self.role = role; self.content = content; self.model = model
        self.reasoning = reasoning; self.toolCalls = toolCalls; self.timeline = timeline; self.runStats = runStats
        self.createdAt = createdAt
    }
}

/// Rows written to the relay. Encrypted columns hold `e1.<kv>.<b64>` strings
/// (jsonb columns store that string as a JSON string, §6.2).
public struct RemoteSessionRow: Encodable, Equatable, Sendable {
    let id: String
    let machine_id: String
    let mode: String
    let title: String
    let workspace: String?
    let model_id: String?
    let approval_mode: String?
    let agent_system: String?
    let status: String
    let pending_approval: String?
    let phase: String?
    let silence: Bool
    let interrupted: Bool
    let run_started_at: Date?
    let message_count: Int
    let updated_at: Date
    let last_synced_at: Date
    let archived_at: Date?
    enum CodingKeys: String, CodingKey {
        case id, machine_id, mode, title, workspace, model_id, approval_mode, agent_system, status,
             pending_approval, phase, silence, interrupted, run_started_at, message_count, updated_at, last_synced_at, archived_at
    }
    public func encode(to encoder: any Encoder) throws {
        try encode(to: encoder, includingArchive: true)
    }
    public func encode(to encoder: any Encoder, includingArchive: Bool = true) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(machine_id, forKey: .machine_id)
        try values.encode(mode, forKey: .mode); try values.encode(title, forKey: .title)
        try values.encodeIfPresent(workspace, forKey: .workspace); try values.encodeIfPresent(model_id, forKey: .model_id)
        try values.encodeIfPresent(approval_mode, forKey: .approval_mode); try values.encodeIfPresent(agent_system, forKey: .agent_system)
        try values.encode(status, forKey: .status)
        // An omitted key is excluded from PostgREST upsert columns and preserves stale pending state.
        try values.encode(pending_approval, forKey: .pending_approval)
        try values.encode(phase, forKey: .phase); try values.encode(silence, forKey: .silence)
        try values.encode(interrupted, forKey: .interrupted); try values.encodeIfPresent(run_started_at, forKey: .run_started_at)
        try values.encode(message_count, forKey: .message_count); try values.encode(updated_at, forKey: .updated_at)
        try values.encode(last_synced_at, forKey: .last_synced_at)
        if includingArchive { try values.encode(archived_at, forKey: .archived_at) }
    }
}

public struct RemoteMessageRow: Encodable, Equatable, Sendable {
    let id: String
    let session_id: String
    let seq: Int
    let role: String
    let content: String
    let tool_calls: String?
    let model: String?
    let reasoning: String?
    let run_stats: RemoteJSONValue?
    let timeline: String?
    let created_at: Date
}

public enum RemoteHostMirror {
    /// Messages kept per conversation, and conversations mirrored per mode
    /// (30 Agent + 30 Chat, §2 and §6.13).
    public static let messageWindow = 25
    public static let sessionLimit = 30
    public static let totalSessionLimit = 60

    public static func sessionRow(_ session: RemoteHostSessionSnapshot, machineID: String, key: Data, version: Int,
                                  now: Date = .now) throws -> RemoteSessionRow {
        func seal(_ column: String, _ value: String?) throws -> String? {
            try value.map { try RemoteCrypto.encryptField($0, key: key, version: version,
                context: RemoteFieldContext(table: "remote_sessions", column: column, rowID: session.id)) }
        }
        return RemoteSessionRow(id: session.id, machine_id: machineID, mode: session.mode,
            title: try seal("title", session.title.isEmpty ? "Conversation" : session.title)!,
            workspace: try seal("workspace", session.workspace), model_id: session.modelID,
            approval_mode: session.approvalMode, agent_system: session.agentSystem, status: session.status,
            pending_approval: try seal("pending_approval", session.pendingApproval.map(json)),
            phase: try seal("phase", RemoteConversationAnnouncement(phase: session.phase, executionDeviceIDs: session.executionDeviceIDs, latestResponseVersion: session.latestResponseVersion).encodedPhase()), silence: session.silence, interrupted: session.interrupted,
            run_started_at: session.runStartedAt, message_count: session.messages.count,
            updated_at: session.updatedAt, last_synced_at: now, archived_at: session.archivedAt)
    }

    public static func messageRows(_ session: RemoteHostSessionSnapshot, key: Data, version: Int) throws -> [RemoteMessageRow] {
        try session.messages.suffix(messageWindow).map { message in
            func seal(_ column: String, _ value: String?) throws -> String? {
                try value.map { try RemoteCrypto.encryptField($0, key: key, version: version,
                    context: RemoteFieldContext(table: "remote_messages", column: column, rowID: message.id)) }
            }
            return RemoteMessageRow(id: message.id, session_id: session.id, seq: message.sequence, role: message.role,
                content: try seal("content", message.content)!, tool_calls: try seal("tool_calls", message.toolCalls.map(json)),
                model: message.model, reasoning: try seal("reasoning", message.reasoning), run_stats: message.runStats,
                timeline: try seal("timeline", message.timeline.map(json)), created_at: message.createdAt)
        }
    }

    public static func capabilities(_ capabilities: RemoteCapabilities, machineID: String, key: Data, version: Int) throws -> String {
        let data = try JSONEncoder().encode(capabilities)
        return try RemoteCrypto.encryptField(String(decoding: data, as: UTF8.self), key: key, version: version,
            context: RemoteFieldContext(table: "remote_machines", column: "capabilities", rowID: machineID))
    }

    static func json(_ value: RemoteJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: Commands

    public enum CommandError: String, Error, Sendable {
        case unencryptedPayload = "charge_non_chiffree"
        case unreadablePayload = "charge_illisible"
    }

    /// The clear payload of a command (§6.4.6): `{"e": …}` sealed for this exact
    /// command id, type, session and machine; only `request_keys` may be clear.
    public static func payload(_ raw: RemoteJSONValue?, command: RemoteCommandIdentity, keys: [Int: Data]) throws -> RemoteJSONValue {
        guard let sealed = raw?.objectValue?["e"]?.stringValue else {
            if command.type == "request_keys" { return raw ?? .object([:]) }
            throw CommandError.unencryptedPayload
        }
        do {
            let clear = try RemoteCrypto.decryptField(sealed, keys: keys, context: command.context(for: .payload))
            return try JSONDecoder().decode(RemoteJSONValue.self, from: Data(clear.utf8))
        } catch {
            throw CommandError.unreadablePayload
        }
    }

    public static func result(_ value: RemoteJSONValue, command: RemoteCommandIdentity, key: Data, version: Int) throws -> RemoteJSONValue {
        .object(["e": .string(try RemoteCrypto.encryptField(json(value), key: key, version: version,
                                                            context: command.context(for: .result)))])
    }
}
