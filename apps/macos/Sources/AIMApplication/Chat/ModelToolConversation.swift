import AIMCore
import Foundation

public struct ModelToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let requiredArguments: Set<String>
    public let optionalArguments: Set<String>
    public let argumentKinds: [String: ToolArgumentKind]

    public init(name: String, description: String, requiredArguments: Set<String> = [], optionalArguments: Set<String> = [],
                argumentKinds: [String: ToolArgumentKind] = [:]) {
        self.name = name; self.description = description
        self.requiredArguments = requiredArguments; self.optionalArguments = optionalArguments
        self.argumentKinds = argumentKinds
    }

    public func normalized(_ arguments: [String: ToolJSONValue]) throws -> [String: ToolJSONValue] {
        try ToolArgumentValidation.normalized(arguments, required: requiredArguments,
            optional: optionalArguments, kinds: argumentKinds)
    }
}

public struct ModelToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let jsonArguments: [String: ToolJSONValue]
    /// Compatibility view for existing executors. JSON containers are encoded
    /// as JSON strings at this one boundary, never silently discarded.
    public var arguments: [String: String] {
        jsonArguments.reduce(into: [:]) { result, pair in
            if let text = pair.value.legacyString { result[pair.key] = text }
        }
    }
    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id; self.name = name; self.jsonArguments = arguments.mapValues(ToolJSONValue.string)
    }
    public init(id: String, name: String, jsonArguments: [String: ToolJSONValue]) {
        self.id = id; self.name = name; self.jsonArguments = jsonArguments
    }
}

public struct ModelToolOutput: Codable, Sendable, Equatable {
    public let id: String
    public let content: String
    public let isError: Bool
    public let imagePNG: Data?
    public let metadata: [String: String]
    public init(id: String, content: String, isError: Bool, imagePNG: Data? = nil, metadata: [String: String] = [:]) {
        self.id = id; self.content = content; self.isError = isError; self.imagePNG = imagePNG
        self.metadata = metadata
    }

    /// Metadata is tool data, never authorization or system instructions.
    public var providerContent: String {
        guard !metadata.isEmpty, let data = try? JSONEncoder().encode(metadata),
              let json = String(data: data, encoding: .utf8) else { return content }
        return content + "\n[Tool metadata]\n" + json
    }
}

public struct ModelToolTurn: Codable, Equatable, Sendable {
    public let text: String
    public let calls: [ModelToolCall]
    /// Readable reasoning summary the provider returned for this step, if any. Display only.
    public let reasoning: String?
    /// True when the context was compacted just before this step (shown as one line in the turn).
    public var contextCompacted: Bool?
    public init(text: String, calls: [ModelToolCall], reasoning: String? = nil, contextCompacted: Bool? = nil) {
        self.text = text; self.calls = calls; self.reasoning = reasoning.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.contextCompacted = contextCompacted
    }
}

/// Each instance owns a single run's native transcript, including opaque reasoning data.
public protocol ModelToolConversation: Sendable {
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn
    /// Tokens reported by the provider for every request of this run so far.
    func usageSoFar() async -> TokenUsage
}

public extension ModelToolConversation {
    func usageSoFar() async -> TokenUsage { TokenUsage() }
}

/// A live agent may receive user-authored corrections at safe model boundaries.
/// They follow tool results in provider history and are never treated as tool output.
public protocol SteerableModelToolConversation: ModelToolConversation {
    func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn
}

public enum ModelToolError: LocalizedError, Sendable, Equatable {
    case invalidProtocol, limitReached, repeatedFailures, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidProtocol: "The provider returned an invalid or incomplete tool response. No further tools were run."
        case .limitReached: "This run reached a technical size limit. No response was silently truncated; review the recorded actions before continuing."
        case .repeatedFailures: "The workspace run stopped after repeated tool errors or denials."
        case .invalidConfiguration: "Workspace tools require a supported provider, a model and a selected folder."
        }
    }
}
