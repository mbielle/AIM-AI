import AIMCore
import Foundation

/// Continue only explicit provider truncation and only while new text is made.
/// There is no iteration quota. Network errors and incomplete calls never
/// become a successful answer or an executable tool request.
struct ProviderResponseContinuation {
    private(set) var text = ""
    private var segments: Set<String> = []
    mutating func appendTruncated(_ segment: String) throws {
        let normalized = segment.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, segments.insert(normalized).inserted else { throw ChatServiceError.incompleteResponse }
        let normalizedExisting = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalizedExisting.isEmpty || !normalizedExisting.contains(normalized) else { throw ChatServiceError.incompleteResponse }
        text += segment
    }
    func completed(with segment: String, hasCompleteCalls: Bool = false) throws -> String {
        let normalized = segment.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard hasCompleteCalls || segments.isEmpty || (!normalized.isEmpty && !segments.contains(normalized)) else { throw ChatServiceError.incompleteResponse }
        return text + segment
    }
}

struct ProviderChatAttempt: Sendable {
    var text = ""
    var truncated = false
    var usage = TokenUsage()
    var receiptUSD: String?
    var firstText: Date?
    var characters = 0
    var sources: [ConversationSource]?
    var webSearchUsage: NativeWebSearchUsage?
    var webSearchActivities: [NativeWebSearchActivity]?
}

enum ProviderStreamTruncation {
    static func isOutputLimit(_ payload: String, provider: ChatProvider) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], root["error"] == nil else { return false }
        if provider.usesChatCompletions { return (root["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "length" }
        if provider == .anthropic { return (root["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" }
        if provider == .google { return (root["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String == "MAX_TOKENS" }
        return root["type"] as? String == "response.incomplete"
            && ((root["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens"
    }
    static func isTerminal(_ payload: String, provider: ChatProvider) -> Bool { provider == .google || provider.usesResponsesAPI || provider == .perplexity }
    static func text(_ payload: String, provider: ChatProvider) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw ChatServiceError.invalidResponse }
        if provider.usesChatCompletions {
            let delta = (root["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] ?? [:]
            guard delta["tool_calls"] == nil || delta["tool_calls"] is NSNull else { throw ChatServiceError.unsupportedTools }
            return delta["content"] as? String ?? ""
        }
        if provider == .google {
            let parts = ((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            guard !parts.contains(where: { $0["functionCall"] != nil }) else { throw ChatServiceError.unsupportedTools }
            return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
        if provider.usesResponsesAPI || provider == .perplexity {
            let items = (root["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            guard items.allSatisfy({ ["message", "reasoning", "web_search_call"].contains($0["type"] as? String ?? "") }) else { throw ChatServiceError.unsupportedTools }
        }
        return ""
    }
}
