import Foundation

public struct ChatModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let created: Double?
    public let maxOutputTokens: Int?
    public let contextLength: Int?
    public var architecture: Architecture?
    public let inputModalities: [String]?
    public var supportedParameters: [String]?
    /// Catalog facts shown in the model picker (OpenRouter publishes them; nil elsewhere).
    public var summary: String?
    public var pricing: Pricing?
    public var knowledgeCutoff: String?
    public var topProvider: TopProvider?
    public var reasoning: ReasoningInfo?

    /// What the catalog says about a model's reasoning settings.
    public struct ReasoningInfo: Codable, Hashable, Sendable {
        public let mandatory: Bool?
        public let defaultEnabled: Bool?
        public let supportedEfforts: [String]?
        public let defaultEffort: String?
        enum CodingKeys: String, CodingKey {
            case mandatory
            case defaultEnabled = "default_enabled"
            case supportedEfforts = "supported_efforts"
            case defaultEffort = "default_effort"
        }
        public init(mandatory: Bool?, defaultEnabled: Bool? = nil, supportedEfforts: [String]?, defaultEffort: String?) {
            self.mandatory = mandatory; self.defaultEnabled = defaultEnabled
            self.supportedEfforts = supportedEfforts; self.defaultEffort = defaultEffort
        }
    }

    public struct Pricing: Codable, Hashable, Sendable {
        public let prompt: String?
        public let completion: String?
        public let inputCacheRead: String?
        enum CodingKeys: String, CodingKey {
            case prompt, completion
            case inputCacheRead = "input_cache_read"
        }
        public init(prompt: String?, completion: String?, inputCacheRead: String? = nil) {
            self.prompt = prompt; self.completion = completion; self.inputCacheRead = inputCacheRead
        }
        /// US dollars per million tokens; nil when unknown or negative (OpenRouter's "variable").
        public static func perMillion(_ value: String?) -> Double? {
            guard let value, let perToken = Double(value), perToken >= 0 else { return nil }
            return perToken * 1_000_000
        }
        public var inputPerMillion: Double? { Self.perMillion(prompt) }
        public var outputPerMillion: Double? { Self.perMillion(completion) }
        public var cacheReadPerMillion: Double? { Self.perMillion(inputCacheRead) }
    }

    public struct TopProvider: Codable, Hashable, Sendable {
        public let contextLength: Int?
        public let maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    public init(id: String, name: String, contextLength: Int? = nil, inputModalities: [String]? = nil, created: Double? = nil, maxOutputTokens: Int? = nil) {
        self.maxOutputTokens = maxOutputTokens
        self.created = created
        self.id = id; self.name = name; self.contextLength = contextLength
        self.architecture = nil; self.inputModalities = inputModalities
    }

    public struct Architecture: Codable, Hashable, Sendable {
        public let inputModalities: [String]?
        public let outputModalities: [String]?
        public init(inputModalities: [String]?, outputModalities: [String]?) {
            self.inputModalities = inputModalities; self.outputModalities = outputModalities
        }
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, name, architecture, created
        case inputModalities = "input_modalities"
        case maxOutputTokens = "max_tokens"
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
        case summary = "description"
        case pricing
        case knowledgeCutoff = "knowledge_cutoff"
        case topProvider = "top_provider"
        case reasoning
    }

    /// Image, video, speech, embedding or rerank models do not answer in text, so they cannot
    /// run a chat; nil modalities (direct catalogs) are treated as chat models.
    public var isChatModel: Bool {
        guard let outputs = architecture?.outputModalities, !outputs.isEmpty else { return true }
        return outputs.contains("text")
    }

    /// A short label for non-chat models ("Image generation", "Speech"…).
    public var kindLabel: String? {
        guard !isChatModel, let output = architecture?.outputModalities?.first else { return nil }
        switch output {
        case "image": return "Image generation"
        case "video": return "Video generation"
        case "speech", "audio": return "Speech"
        case "transcription": return "Transcription"
        case "embeddings": return "Embeddings"
        case "rerank": return "Reranking"
        default: return output.capitalized
        }
    }

    public enum Capability: String, CaseIterable, Sendable {
        case vision, tools, reasoning, files, audio, imageOutput
    }

    /// What the catalog says the model can do (an empty set means "not disclosed").
    public var capabilities: Set<Capability> {
        var result: Set<Capability> = []
        let inputs = architecture?.inputModalities ?? inputModalities ?? []
        if inputs.contains("image") { result.insert(.vision) }
        if inputs.contains("file") { result.insert(.files) }
        if inputs.contains("audio") { result.insert(.audio) }
        if architecture?.outputModalities?.contains("image") == true { result.insert(.imageOutput) }
        let parameters = supportedParameters ?? []
        if parameters.contains("tools") { result.insert(.tools) }
        if parameters.contains("reasoning") || parameters.contains("include_reasoning") { result.insert(.reasoning) }
        return result
    }
    /// Nil means the catalog does not disclose image input support, not that it is unsupported.
    public var supportsImageInput: Bool? {
        guard let modalities = architecture?.inputModalities ?? inputModalities else { return nil }
        return modalities.contains("image")
    }
    public var provider: String { String(id.split(separator: "/").first ?? "") }
}

public enum ChatServiceError: LocalizedError, Sendable {
    case missingKey, invalidResponse, emptyResponse, incompleteResponse, unsupportedTools, http(Int)
    /// The ChatGPT plan's included usage is used up (it resets on its own).
    case planLimitReached
    /// ChatGPT reports plan usage as temporarily unavailable for this account.
    case planUsageUnavailable
    case unsupportedWebSearch, webSearchBudgetUnavailable, webSearchFailed
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Connect the selected provider in Settings to send a message."
        case .invalidResponse: "The model returned an unreadable response. Please try again."
        case .emptyResponse: "The model finished without a text response. Try another model."
        case .incompleteResponse: "The connection ended before the response finished. The partial response has been kept."
        case .unsupportedTools: "This response requires tools that are not connected yet."
        case .unsupportedWebSearch: "Automatic web search is unavailable for the selected provider or model. Choose a compatible model or turn it off in Configuration."
        case .webSearchBudgetUnavailable: "Web search has no verified maximum cost for this request. Turn it off in Configuration to keep this device’s budget protection."
        case .webSearchFailed: "The provider could not finish its web search. Your partial response is kept. No provider was changed."
        case .http(401): "The provider rejected the API key. Update it in Settings."
        case .http(403): "This account is not permitted to use this resource. Check provider access."
        case .http(402): "Your provider account needs credits."
        case .http(429): "The provider is rate limiting requests. Please try again shortly."
        case .http(let code): "The model service returned HTTP \(code). Please try again."
        case .planUsageUnavailable: "ChatGPT plan usage is unavailable right now for this account. Try again later, or choose another provider meanwhile."
        case .planLimitReached: "You have reached your ChatGPT plan's usage limit. It resets on its own; see Manage usage at chatgpt.com/settings/usage, or choose another provider meanwhile."
        }
    }
}

/// Decodes complete SSE data payloads. Invalid events fail once instead of
/// reinserting the same malformed line into an unbounded retry buffer.
public enum ChatStreamPayload: Equatable, Sendable {
    case text(String), ignored, done

    public static func decode(_ payload: String) throws -> Self {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatServiceError.invalidResponse
        }
        if json["error"] != nil { throw ChatServiceError.invalidResponse }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return .ignored }
        if choice["finish_reason"] as? String == "tool_calls" { throw ChatServiceError.unsupportedTools }
        if let reason = choice["finish_reason"] as? String, reason != "stop" { throw ChatServiceError.incompleteResponse }
        let delta = choice["delta"] as? [String: Any]
        if delta?["tool_calls"] != nil || delta?["function_call"] != nil { throw ChatServiceError.unsupportedTools }
        if let text = delta?["content"] as? String, !text.isEmpty { return .text(text) }
        return .ignored
    }
}
