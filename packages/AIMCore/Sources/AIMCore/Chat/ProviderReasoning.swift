import Foundation

/// Anthropic thinking parameters for one exact model. Claude 4.6 and later reject
/// `budget_tokens` (400) and, from 4.7, return empty thinking text unless a summary is
/// requested; earlier models only accept the fixed budget form.
public enum AnthropicThinkingPolicy {
    public enum Generation: Equatable, Sendable { case budget, adaptive46, adaptive, alwaysOn }

    public static func generation(modelID: String) -> Generation {
        let id = modelID.lowercased()
        if id.contains("claude-3") || id.contains("claude-2") || id.contains("claude-instant") { return .budget }
        if id.contains("fable") || id.contains("mythos") { return .alwaysOn }
        guard let match = id.range(of: #"(opus|sonnet|haiku)-(\d{1,2})(?:-(\d{1,2}))?(?=-|$|@|:)"#, options: .regularExpression) else { return .adaptive }
        let parts = id[match].split(separator: "-")
        let family = String(parts[0]), major = Int(parts[1]) ?? 0, minor = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        let version = Double(major) + Double(minor) / 10
        if version < 4.6 { return .budget }
        if version < 4.7 { return .adaptive46 }
        switch family {
        case "opus": return version >= 5 ? .alwaysOn : .adaptive
        case "sonnet", "haiku": return version >= 5.5 ? .alwaysOn : .adaptive
        default: return .adaptive
        }
    }

    /// Fields merged into the request body. `effort` is AIM's raw level (none, minimal,
    /// low, medium, high, xhigh, max); `budget` is the legacy token budget for that level.
    public static func fields(modelID: String, effort: String?, budget: Int?) -> [String: Any] {
        let level = effort.flatMap { $0 == "none" ? nil : $0 }
        switch generation(modelID: modelID) {
        case .budget:
            guard let budget else { return [:] }
            return ["thinking": ["type": "enabled", "budget_tokens": budget]]
        case .adaptive46:
            guard let level else { return [:] }
            return ["thinking": ["type": "adaptive"], "output_config": ["effort": mapped(level, xhigh: false)]]
        case .adaptive, .alwaysOn:
            let always = generation(modelID: modelID) == .alwaysOn
            guard level != nil || always else { return [:] }
            var result: [String: Any] = ["thinking": ["type": "adaptive", "display": "summarized"]]
            if let level { result["output_config"] = ["effort": mapped(level, xhigh: true)] }
            return result
        }
    }

    /// True when the request sends a fixed thinking budget that the output limit must exceed.
    public static func usesBudget(modelID: String) -> Bool { generation(modelID: modelID) == .budget }

    private static func mapped(_ level: String, xhigh: Bool) -> String {
        switch level {
        case "minimal", "low": "low"
        case "medium": "medium"
        case "xhigh": xhigh ? "xhigh" : "high"
        case "max": "max"
        default: "high"
        }
    }
}

/// Provider-supplied reasoning text carried by a streamed payload, if available.
/// Its form varies by provider/model. Presentation keeps it in a separate folded detail
/// and never treats this prose as proof of a tool call or visited page.
public enum ProviderReasoningStream {
    public static func delta(_ payload: String, provider: ChatProvider) -> String? {
        guard payload.contains("reason") || payload.contains("think") || payload.contains("thought"),
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        let text: String?
        switch provider {
        case .openAI, .chatgpt, .xAI:
            switch json["type"] as? String {
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta": text = json["delta"] as? String
            case "response.reasoning_summary_part.added": text = (json["summary_index"] as? Int ?? 0) > 0 ? "\n\n" : nil
            default: text = nil
            }
        case .anthropic:
            let delta = json["delta"] as? [String: Any]
            text = delta?["type"] as? String == "thinking_delta" ? delta?["thinking"] as? String : nil
        case .google:
            let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let thoughts = parts.filter { $0["thought"] as? Bool == true }.compactMap { $0["text"] as? String }.joined()
            text = thoughts.isEmpty ? nil : thoughts
        default:
            let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
            text = delta?["reasoning"] as? String ?? delta?["reasoning_content"] as? String
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
