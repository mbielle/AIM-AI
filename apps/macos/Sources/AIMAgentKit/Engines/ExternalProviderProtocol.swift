import AIMApplication
import Foundation

/// Raw OpenAI chat-completions data. No endpoint, headers or credentials are
/// accepted from the subprocess. The host binds and meters the physical send.
public struct ExternalProviderRequest: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let grantID: UUID
    public let body: Data
    public let sha256: String
    public init(requestID: UUID, grantID: UUID, body: Data, sha256: String) {
        version = 1; self.requestID = requestID; self.grantID = grantID; self.body = body; self.sha256 = sha256
    }
}
public struct ExternalProviderResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public init(status: Int, contentType: String, body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }
}
public struct ExternalProviderChunk: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let index: Int
    public let final: Bool
    public let status: Int
    public let contentType: String
    public let bytes: Data
    public init(requestID: UUID, index: Int, final: Bool, status: Int, contentType: String, bytes: Data) {
        version = 1; self.requestID = requestID; self.index = index; self.final = final
        self.status = status; self.contentType = contentType; self.bytes = bytes
    }
}
/// Receives a provider's body while it arrives (status and content type with every piece), so
/// the engine streams its answer instead of waiting for the whole response.
public typealias ExternalProviderStreamSink = @Sendable (_ status: Int, _ contentType: String, _ bytes: Data) async throws -> Void

/// Where an engine call comes from and how its answer may be delivered.
public struct ExternalCallContext: Sendable {
    /// The engine's own sub-agent that made the call; nil for the main agent.
    public var origin: String?
    public var stream: ExternalProviderStreamSink?
    public init(origin: String? = nil, stream: ExternalProviderStreamSink? = nil) { self.origin = origin; self.stream = stream }
}

public typealias ExternalProviderHandler = @Sendable (ExternalProviderRequest, AgentRequest, ExternalFinanceGrant, ExternalCallContext) async throws -> ExternalProviderResponse

public typealias ExternalToolHandler = @Sendable (ModelToolCall, AgentRequest, ExternalFinanceGrant, ExternalCallContext) async throws -> Data

/// What an engine reports about its own work that AIM shows: where its answer starts and ends,
/// its built-in tools (delegation), and its sub-agents. Observations only: no authority.
public struct ExternalActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A new message of the main agent starts (the previous one was a working note).
        case segment
        /// The main agent's complete final answer.
        case final
        case toolStarted, toolFinished
        case subagentStarted, subagentText, subagentReasoning, subagentToolStarted, subagentToolFinished, subagentFinished
    }
    public var kind: Kind
    public var childID: String?
    public var callID: String?
    public var name: String?
    public var title: String?
    public var text: String?
    public var isError: Bool?
    public init(kind: Kind, childID: String? = nil, callID: String? = nil, name: String? = nil, title: String? = nil,
                text: String? = nil, isError: Bool? = nil) {
        self.kind = kind; self.childID = childID; self.callID = callID; self.name = name; self.title = title
        self.text = text; self.isError = isError
    }
    /// Bounded and well formed; anything else is refused before it reaches the host.
    public var isValid: Bool {
        func short(_ value: String?) -> Bool { value.map { $0.utf8.count <= 256 && !$0.contains("\0") } ?? true }
        return short(childID) && short(callID) && short(name) && (title.map { $0.utf8.count <= 16_000 } ?? true)
            && (text.map { $0.utf8.count <= 600_000 } ?? true)
    }
}

public typealias ExternalActivityHandler = @Sendable (ExternalActivity, AgentRequest) async -> Void
