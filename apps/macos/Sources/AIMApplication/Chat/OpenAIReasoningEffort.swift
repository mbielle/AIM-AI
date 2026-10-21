import AIMCore
import Foundation

/// A user-selected Responses API parameter, not a claim that every model accepts it.
/// Nil means the provider/model default and omits the field entirely.
public enum OpenAIReasoningEffort: String, Codable, CaseIterable, Sendable, Hashable {
    case none, minimal, low, medium, high, xhigh, max

    public var title: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra"
        case .max: "Max"
        }
    }

    /// The name shown to the user: local models only switch thinking on or off.
    public func label(provider: ChatProvider) -> String {
        guard provider == .local else { return title }
        return self == .none ? "Off" : "Thinking"
    }

    /// One short line shown under the effort selector.
    public var explanation: String {
        switch self {
        case .none: "No reasoning: fastest and cheapest answers."
        case .minimal: "A very short think before answering."
        case .low: "Quick reasoning for simple requests."
        case .medium: "Balanced depth and speed."
        case .high: "Thinks carefully; slower and uses more tokens."
        case .xhigh: "Very deep reasoning for hard problems."
        case .max: "The model's full reasoning budget; slowest and most expensive."
        }
    }
}

/// One effort setting, translated per provider: OpenAI/OpenRouter `reasoning.effort`,
/// Anthropic extended thinking with a token budget, xAI's low/high effort.
public extension OpenAIReasoningEffort {
    static let providers: Set<ChatProvider> = [.openAI, .chatgpt, .openRouter, .anthropic, .xAI, .local]

    static func applies(to provider: ChatProvider) -> Bool { providers.contains(provider) }

    /// Whether to offer the setting for a model (OpenRouter answers from its catalog).
    static func offered(provider: ChatProvider, modelID: String, openRouterParameters: [String]? = nil) -> Bool {
        let id = modelID.lowercased()
        switch provider {
        case .openAI, .chatgpt: return true
        case .openRouter: return openRouterParameters?.contains("reasoning") == true || openRouterParameters?.contains("include_reasoning") == true
        case .anthropic:
            // Extended thinking: Claude 3.7 Sonnet and every Claude 4+ model.
            return id.contains("claude-3-7") || id.range(of: #"claude-(opus|sonnet|haiku)-[4-9]"#, options: .regularExpression) != nil
                || id.range(of: #"claude-[4-9]"#, options: .regularExpression) != nil
        case .xAI: return id.contains("mini")
        case .local: return LocalModelTuning.supportsThinking(modelID: modelID)
        default: return false
        }
    }

    /// Anthropic thinking budget in tokens; nil turns thinking off.
    var anthropicThinkingBudget: Int? {
        switch self {
        case .none: nil
        case .minimal: 1_024
        case .low: 2_048
        case .medium: 8_192
        case .high: 16_384
        case .xhigh, .max: 32_000
        }
    }

    /// The levels a model really accepts, in increasing order. The catalog (OpenRouter's
    /// `reasoning.supported_efforts`, also matched for direct providers) is authoritative;
    /// "None" is offered only when reasoning is explicitly optional.
    static func levels(provider: ChatProvider, modelID: String, info: ChatModel.ReasoningInfo?) -> [OpenAIReasoningEffort] {
        if let supported = info?.supportedEfforts, !supported.isEmpty {
            var result = allCases.filter { supported.contains($0.rawValue) && $0 != .none }
            if info?.mandatory == false { result.insert(.none, at: 0) }
            return result
        }
        let id = modelID.lowercased()
        switch provider {
        case .local: return [.none, .high]
        case .xAI: return [.low, .high]
        case .anthropic:
            // Claude 5 thinks by default with effort levels; older models have optional thinking.
            if id.range(of: #"claude-(opus|sonnet|haiku)-[5-9]|claude-[5-9]"#, options: .regularExpression) != nil {
                return [.low, .medium, .high, .xhigh, .max]
            }
            return [.none, .low, .medium, .high]
        case .openAI, .chatgpt: return [.low, .medium, .high]
        default: return [.low, .medium, .high]
        }
    }

    /// The model's own default level, when the catalog states it.
    static func defaultLevel(info: ChatModel.ReasoningInfo?) -> OpenAIReasoningEffort? {
        info?.defaultEffort.flatMap(OpenAIReasoningEffort.init(rawValue:))
    }

    /// A saved choice the model no longer accepts falls back to the model default (nil),
    /// so a request never carries an unsupported effort.
    static func effective(_ saved: OpenAIReasoningEffort?, provider: ChatProvider, modelID: String,
                          info: ChatModel.ReasoningInfo?) -> OpenAIReasoningEffort? {
        guard let saved, applies(to: provider) else { return nil }
        return levels(provider: provider, modelID: modelID, info: info).contains(saved) ? saved : nil
    }

    var xAIEffort: String { [.none, .minimal, .low].contains(self) ? "low" : "high" }
}
