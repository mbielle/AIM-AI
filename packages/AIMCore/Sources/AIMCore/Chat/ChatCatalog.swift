import Foundation

public enum ChatProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openRouter = "openrouter", openAI = "openai", anthropic, google, deepSeek = "deepseek", xAI = "xai", perplexity
    /// An OpenAI-compatible server on this Mac (oMLX, LM Studio, Ollama, llama.cpp…). No key, no cost.
    case local
    /// OpenAI-compatible cloud providers (see `CompatibleProviders`).
    case mistral, groq, together, fireworks, cerebras, moonshot, zai, qwen, minimax, cohere
    case huggingface, nvidia, sambanova, deepinfra, nebius, novita, venice
    /// The person's ChatGPT plan (official Sign in with ChatGPT): Responses API with an OAuth token.
    case chatgpt
    public var usesResponsesAPI: Bool { self == .openAI || self == .xAI || self == .chatgpt }
    /// Cloud providers need a key; a local server usually does not.
    public var requiresAPIKey: Bool { self != .local }
    /// Requests use the OpenAI chat-completions wire format.
    public var usesChatCompletions: Bool { self == .openRouter || self == .deepSeek || self == .local || isCompatible }
    /// One of the OpenAI-compatible cloud providers of `CompatibleProviders`.
    public var isCompatible: Bool { CompatibleProviders.spec(self) != nil }
    public var id: String { rawValue }
    public var name: String {
        switch self { case .openRouter: "OpenRouter"; case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .google: "Google Gemini"; case .deepSeek: "DeepSeek"; case .xAI: "xAI (Grok)"; case .perplexity: "Perplexity"; case .local: "On this Mac (local)"
        case .chatgpt: "ChatGPT plan"
        default: CompatibleProviders.spec(self)?.name ?? rawValue }
    }
    public var host: String {
        switch self { case .openRouter: "openrouter.ai"; case .openAI: "api.openai.com"; case .anthropic: "api.anthropic.com"; case .google: "generativelanguage.googleapis.com"; case .deepSeek: "api.deepseek.com"; case .xAI: "api.x.ai"; case .perplexity: "api.perplexity.ai"; case .local: LocalModelEndpoint.baseURL.host ?? "127.0.0.1"
        case .chatgpt: "api.openai.com"
        default: CompatibleProviders.spec(self).flatMap { URL(string: $0.baseURL)?.host } ?? "" }
    }
    public var keyURL: URL {
        let address = switch self {
        case .openRouter: "https://openrouter.ai/keys"
        case .openAI: "https://platform.openai.com/api-keys"
        case .anthropic: "https://platform.claude.com/settings/keys"
        case .google: "https://aistudio.google.com/apikey"
        case .deepSeek: "https://platform.deepseek.com/api_keys"
        case .xAI: "https://console.x.ai"
        case .perplexity: "https://console.perplexity.ai/project/keys"
        case .local: "https://huggingface.co/models?library=mlx"
        case .chatgpt: "https://chatgpt.com/settings/usage"
        default: CompatibleProviders.spec(self)?.keyURL ?? "https://openrouter.ai"
        }
        return URL(string: address)!
    }
}

public struct ProviderStreamChunk: Equatable, Sendable {
    public var text: String = ""
    public var isComplete = false
    public var sources: [ConversationSource]?
    public init(text: String = "", isComplete: Bool = false, sources: [ConversationSource]? = nil) { self.text = text; self.isComplete = isComplete; self.sources = sources }
}

/// Protocol-specific decoding stays outside the UI and never exposes raw server errors.
public enum ProviderWireFormat {
    public static func decode(_ payload: String, provider: ChatProvider, allowWebSearch: Bool = false) throws -> ProviderStreamChunk {
        // A local model that reached the response length the person set has finished, not failed.
        if provider == .local, payload.contains("\"length\""),
           let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           let choice = (json["choices"] as? [[String: Any]])?.first, choice["finish_reason"] as? String == "length" {
            return .init(text: (choice["delta"] as? [String: Any])?["content"] as? String ?? "", isComplete: true)
        }
        if provider.usesChatCompletions {
            switch try ChatStreamPayload.decode(payload) {
            case .text(let text): return .init(text: text)
            case .done: return .init(isComplete: true)
            case .ignored: return .init()
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw ChatServiceError.invalidResponse }
        if provider == .chatgpt, ChatGPTIntegration.isPlanLimit(payload) { throw ChatServiceError.planLimitReached }
        if provider == .chatgpt, ChatGPTIntegration.isPlanUnavailable(payload) { throw ChatServiceError.planUsageUnavailable }
        if json["error"] != nil || json["type"] as? String == "error" { throw ChatServiceError.invalidResponse }
        switch provider {
        case .perplexity:
            return try PerplexityAgentWire.decode(json)
        case .openAI, .xAI, .chatgpt:
            switch json["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                guard let text = json["delta"] as? String else { throw ChatServiceError.invalidResponse }
                return .init(text: text)
            case "response.output_item.added", "response.output_item.done":
                guard let item = json["item"] as? [String: Any] else { throw ChatServiceError.invalidResponse }
                try validateTextItem(item, completed: json["type"] as? String == "response.output_item.done", allowWebSearch: allowWebSearch)
                return .init()
            case "response.function_call_arguments.delta", "response.function_call_arguments.done":
                throw ChatServiceError.unsupportedTools
            case "response.completed":
                guard let response = json["response"] as? [String: Any],
                      response["object"] as? String == "response",
                      response["status"] as? String == "completed",
                      response["error"] == nil || response["error"] is NSNull,
                      let items = response["output"] as? [[String: Any]] else {
                    throw ChatServiceError.incompleteResponse
                }
                for item in items { try validateTextItem(item, completed: true, allowWebSearch: allowWebSearch) }
                let hasVisibleOutput = items.contains { item in
                    guard item["type"] as? String == "message", let parts = item["content"] as? [[String: Any]] else { return false }
                    return parts.contains { !(($0["text"] as? String ?? $0["refusal"] as? String ?? "").isEmpty) }
                }
                guard hasVisibleOutput else { throw ChatServiceError.emptyResponse }
                return .init(isComplete: true)
            case "response.failed", "response.incomplete": throw ChatServiceError.incompleteResponse
            default: return .init()
            }
        case .anthropic:
            let delta = json["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String {
                if reason == "tool_use" { throw ChatServiceError.unsupportedTools }
                if reason == "max_tokens" { throw ChatServiceError.incompleteResponse }
            }
            if json["type"] as? String == "message_stop" { return .init(isComplete: true) }
            if delta?["type"] as? String == "text_delta" { return .init(text: delta?["text"] as? String ?? "") }
            return .init()
        case .google:
            if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw ChatServiceError.invalidResponse }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return .init() }
            let content = candidate["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            if parts.contains(where: { $0["functionCall"] != nil }) { throw ChatServiceError.unsupportedTools }
            let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            if let reason = candidate["finishReason"] as? String, reason != "STOP" { throw ChatServiceError.incompleteResponse }
            return .init(text: text, isComplete: candidate["finishReason"] as? String == "STOP")
        default: return .init()
        }
    }

    /// Text-only transport must never silently discard an action and report success.
    /// Reasoning items are allowed but remain opaque; tool-enabled runs use a separate codec.
    private static func validateTextItem(_ item: [String: Any], completed: Bool, allowWebSearch: Bool = false) throws {
        guard let type = item["type"] as? String else { throw ChatServiceError.invalidResponse }
        guard type == "message" || type == "reasoning" || (allowWebSearch && type == "web_search_call") else { throw ChatServiceError.unsupportedTools }
        if completed, let status = item["status"] as? String, status != "completed" {
            throw ChatServiceError.incompleteResponse
        }
        guard type == "message" else { return }
        guard item["role"] as? String == "assistant", let parts = item["content"] as? [[String: Any]] else {
            throw ChatServiceError.invalidResponse
        }
        for part in parts {
            let key: String
            switch part["type"] as? String {
            case "output_text": key = "text"
            case "refusal": key = "refusal"
            default: throw ChatServiceError.invalidResponse
            }
            guard part[key] is String else { throw ChatServiceError.invalidResponse }
        }
    }
}
