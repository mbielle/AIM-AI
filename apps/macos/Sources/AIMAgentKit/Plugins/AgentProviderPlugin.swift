import AIMCore
import AIMApplication
import Foundation

/// Version one keeps AIM's chosen native provider contract. A plugin cannot
/// silently relabel a different transport or switch to another paid provider.
public struct AgentProviderPluginConfiguration: Sendable {
    public let apiVersion = 1
    public let provider: ChatProvider
    public let modelID: String
    public let messages: [ConversationMessage]
    public let tools: [ModelToolDefinition]
    public let availableTools: [ModelToolDefinition]?
    public let credentials: @Sendable () async throws -> String
    public let meter: BillableRequestMeter
    public let retryPolicy: ProviderRetryPolicy
    public let activeCompaction: ActiveRunCompaction?
    public let billingFeature: String
    public let planOnly: Bool
    public let titleRequested: Bool
    public let anthropicOutputTokens: Int?
    public let reasoningEffort: OpenAIReasoningEffort?
    public let modelSupportsImages: Bool?
    public init(provider: ChatProvider, modelID: String, messages: [ConversationMessage], tools: [ModelToolDefinition],
                credentials: @escaping @Sendable () async throws -> String, meter: BillableRequestMeter,
                retryPolicy: ProviderRetryPolicy = .persistent, activeCompaction: ActiveRunCompaction? = nil,
                billingFeature: String = "agent", planOnly: Bool = false, titleRequested: Bool = false,
                availableTools: [ModelToolDefinition]? = nil, anthropicOutputTokens: Int? = nil,
                reasoningEffort: OpenAIReasoningEffort? = nil, modelSupportsImages: Bool? = nil) {
        self.provider = provider; self.modelID = modelID; self.messages = messages; self.tools = tools
        self.credentials = credentials; self.meter = meter; self.retryPolicy = retryPolicy
        self.activeCompaction = activeCompaction; self.billingFeature = billingFeature
        self.planOnly = planOnly; self.titleRequested = titleRequested; self.availableTools = availableTools
        self.anthropicOutputTokens = anthropicOutputTokens; self.reasoningEffort = reasoningEffort
        self.modelSupportsImages = modelSupportsImages
    }
}
public protocol NativeAgentProviderPlugin: NativeAgentPlugin {
    /// Exactly the ChatProvider contracts this factory implements.
    var supportedProviders: Set<ChatProvider> { get }
    func makeConversation(configuration: AgentProviderPluginConfiguration) async throws -> any SteerableModelToolConversation & DurableModelConversation
}
public enum AgentProviderPluginError: LocalizedError {
    case missing, disabled, incompatibleVersion, unsupportedContract, incompatibleCheckpoint
    public var errorDescription: String? {
        switch self {
        case .missing: "The selected native provider plugin is unavailable. Restore it or explicitly choose another provider."
        case .disabled: "The selected native provider plugin was disabled. Enable it explicitly before resuming."
        case .incompatibleVersion: "The selected native provider plugin changed version. Inspect its checkpoint before resuming."
        case .unsupportedContract: "The selected plugin does not implement this native provider/model contract. No fallback request was sent."
        case .incompatibleCheckpoint: "This checkpoint belongs to a different provider plugin or native contract."
        }
    }
}
public struct AgentProviderPluginPin: Codable, Equatable, Sendable {
    public static let extensionKey = "aim.provider-plugin.v1"
    public let identifier: String
    public let version: String
    public let apiVersion: Int
    public let provider: ChatProvider
    public let modelID: String
    public init(manifest: AgentPluginManifest, provider: ChatProvider, modelID: String) {
        identifier = manifest.identifier; version = manifest.version; apiVersion = manifest.apiVersion
        self.provider = provider; self.modelID = modelID
    }
    public static func read(_ checkpoint: ModelConversationCheckpoint) throws -> Self? {
        guard let bytes = checkpoint.extensions?[extensionKey] else { return nil }
        guard bytes.count <= 4096, let pin = try? JSONDecoder().decode(Self.self, from: bytes),
              pin.apiVersion == 1, pin.provider == checkpoint.provider, pin.modelID == checkpoint.modelID else {
            throw AgentProviderPluginError.incompatibleCheckpoint
        }
        return pin
    }
}
/// Concrete native adapter for linked plugins that reuse AIM's native wire
/// implementation. Registration and enablement remain explicit host actions.
public struct NativeAgentProviderAdapterPlugin: NativeAgentProviderPlugin {
    public let manifest: AgentPluginManifest
    public let supportedProviders: Set<ChatProvider>
    public init(identifier: String, version: String, providers: Set<ChatProvider>) {
        manifest = AgentPluginManifest(identifier: identifier, version: version, capabilities: [.provider])
        supportedProviders = providers
    }
    public func makeConversation(configuration c: AgentProviderPluginConfiguration) async throws -> any SteerableModelToolConversation & DurableModelConversation {
        guard c.apiVersion == 1, supportedProviders.contains(c.provider),
              c.tools.isEmpty || c.provider.supportsWorkspaceTools else { throw AgentProviderPluginError.unsupportedContract }
        return try ProviderToolConversation(provider: c.provider, modelID: c.modelID, messages: c.messages,
            apiKey: try await c.credentials(), tools: c.tools, anthropicOutputTokens: c.anthropicOutputTokens,
            openAIReasoningEffort: c.reasoningEffort, planOnly: c.planOnly, modelSupportsImages: c.modelSupportsImages,
            meter: c.meter, billingFeature: c.billingFeature, retryPolicy: c.retryPolicy,
            activeCompaction: c.activeCompaction, credentialProvider: c.credentials,
            titleRequested: c.titleRequested, availableTools: c.availableTools)
    }
}
actor PinnedProviderPluginConversation: SteerableModelToolConversation, DurableModelConversation {
    let inner: any SteerableModelToolConversation & DurableModelConversation
    let registry: AgentPluginRegistry
    let pin: AgentProviderPluginPin
    let allowedNames: Set<String>
    let generation: UInt64
    init(inner: any SteerableModelToolConversation & DurableModelConversation, registry: AgentPluginRegistry,
         pin: AgentProviderPluginPin, configuration: AgentProviderPluginConfiguration, generation: UInt64) {
        self.inner = inner; self.registry = registry; self.pin = pin; self.generation = generation
        allowedNames = Set((configuration.availableTools ?? configuration.tools).map(\.name))
    }
    func usageSoFar() async -> TokenUsage { await inner.usageSoFar() }
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn { try await next(outputs: outputs, userMessages: []) }
    func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        _ = try await registry.validateProvider(identifier: pin.identifier, provider: pin.provider, expectedPin: pin, sessionGeneration: generation)
        let turn = try await inner.next(outputs: outputs, userMessages: userMessages)
        _ = try await registry.validateProvider(identifier: pin.identifier, provider: pin.provider, expectedPin: pin, sessionGeneration: generation)
        guard turn.calls.allSatisfy({ allowedNames.contains($0.name) }) else { throw AgentProviderPluginError.unsupportedContract }
        return turn
    }
    func exportCheckpoint() async throws -> ModelConversationCheckpoint {
        _ = try await registry.validateProvider(identifier: pin.identifier, provider: pin.provider, expectedPin: pin, sessionGeneration: generation)
        var checkpoint = try await inner.exportCheckpoint()
        guard checkpoint.provider == pin.provider, checkpoint.modelID == pin.modelID else {
            throw AgentProviderPluginError.unsupportedContract
        }
        checkpoint.extensions = checkpoint.extensions ?? [:]
        checkpoint.extensions?[AgentProviderPluginPin.extensionKey] = try JSONEncoder().encode(pin)
        return checkpoint
    }
    func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) async throws {
        guard try AgentProviderPluginPin.read(checkpoint) == pin else { throw AgentProviderPluginError.incompatibleCheckpoint }
        _ = try await registry.validateProvider(identifier: pin.identifier, provider: pin.provider, expectedPin: pin, sessionGeneration: generation)
        var source = checkpoint; source.extensions?.removeValue(forKey: AgentProviderPluginPin.extensionKey)
        try await inner.restoreCheckpoint(source)
    }
}
