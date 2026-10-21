import AIMApplication
import Foundation

/// AIM's adapter protocol, not an upstream Hermes/OpenClaw protocol.
public struct ExternalEngineConfiguration: Codable, Sendable {
    public var version: Int
    public var enabled: Bool
    /// nil preserves v1 decoding. Paid model turns require stdio v2 / finance v1.
    public var financeProtocolVersion: Int?
    public var identity: String
    public var engineVersion: String
    public var executable: URL
    public var executableSHA256: String
    public var arguments: [String]
    public var environment: [String: String]
    public var secretEnvironmentKeys: [String: String]
    public var allowModelCalls: Bool
    public var allowExternalEffects: Bool
    public var allowedApprovalActions: Set<String>
    /// The operator's actual isolation receipt, never supplied by stdout.
    public var isolationReceipt: String?
    public init(identity: String, engineVersion: String, executable: URL, executableSHA256: String,
        arguments: [String] = [], environment: [String: String] = [:], secretEnvironmentKeys: [String: String] = [:],
        enabled: Bool = false, allowModelCalls: Bool = false, allowExternalEffects: Bool = false,
        allowedApprovalActions: Set<String> = [], isolationReceipt: String? = nil, version: Int = 1, financeProtocolVersion: Int? = nil) {
        self.version = version; self.financeProtocolVersion = financeProtocolVersion; self.enabled = enabled; self.identity = identity; self.engineVersion = engineVersion
        self.executable = executable; self.executableSHA256 = executableSHA256; self.arguments = arguments
        self.environment = environment; self.secretEnvironmentKeys = secretEnvironmentKeys
        self.allowModelCalls = allowModelCalls; self.allowExternalEffects = allowExternalEffects
        self.allowedApprovalActions = allowedApprovalActions; self.isolationReceipt = isolationReceipt
    }
}
public struct ExternalEngineApproval: Codable, Sendable {
    public var id: String
    public var action: String
    public var arguments: [String: String]
    public var digest: String
    public init(id: String, action: String, arguments: [String: String], digest: String) {
        self.id = id; self.action = action; self.arguments = arguments; self.digest = digest
    }
}
public struct ExternalEngineFrame: Codable, Sendable {
    public var version = 1
    public var kind: String
    public var nonce: UUID
    public var identity: String
    public var engineVersion: String?
    public var id: UUID?
    public var sequence: Int?
    public var conversationID: UUID?
    public var request: AgentRequest?
    public var event: EngineEvent?
    public var approval: ExternalEngineApproval?
    public var decision: ApprovalDecision?
    public var readOnly: Bool?
    public var financeProtocolVersion: Int?
    public var financeGrant: ExternalFinanceGrant?
    public var financeRequest: ExternalFinanceRequest?
    public var financeResponse: ExternalFinanceResponse?
    public var providerProtocolVersion: Int?
    public var providerRequest: ExternalProviderRequest?
    public var providerChunk: ExternalProviderChunk?
    public var toolCall: ModelToolCall?
    public var toolSchemas: Data?
    public var activity: ExternalActivity?
    /// The engine's sub-agent behind a tool or provider request (nil: the main agent).
    public var origin: String?
    public init(kind: String, nonce: UUID, identity: String, id: UUID? = nil) {
        self.kind = kind; self.nonce = nonce; self.identity = identity; self.id = id
    }
}
