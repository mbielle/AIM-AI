import AIMCore
import Foundation

/// Claude prompt caching for tool loops. Every Agent request resends the same
/// instructions and tool schemas plus a growing transcript; two breakpoints
/// (end of the system prompt, end of the latest message) let the provider
/// read that prefix from cache at a tenth of the input price.
enum ProviderPromptCache {
    static var marker: [String: Any] { ["type": "ephemeral"] }
    private static let cacheableBlocks: Set<String> = ["text", "image", "image_url", "tool_result", "tool_use", "document"]

    static func applies(provider: ChatProvider, modelID: String) -> Bool {
        if provider == .anthropic { return true }
        let model = modelID.lowercased()
        return provider == .openRouter && (model.hasPrefix("anthropic/") || model.hasPrefix("~anthropic/"))
    }

    /// Anthropic Messages `system` as a cached text block.
    static func anthropicSystem(_ instructions: String) -> [[String: Any]] {
        [["type": "text", "text": instructions, "cache_control": marker]]
    }

    /// OpenAI-style chat history: cache the leading system message.
    static func markingSystemMessage(_ history: [[String: Any]]) -> [[String: Any]] {
        guard var first = history.first, first["role"] as? String == "system",
              let marked = marking(first["content"]) else { return history }
        first["content"] = marked
        return [first] + history.dropFirst()
    }

    /// Adds a breakpoint to the last cacheable block of the latest message.
    static func markingLastMessage(_ history: [[String: Any]]) -> [[String: Any]] {
        history.isEmpty ? history : markingMessage(at: history.count - 1, in: history)
    }

    /// Adds a breakpoint to one message (e.g. the end of the stable history,
    /// before this turn's request-only context), so the next turn reuses it.
    static func markingMessage(at index: Int, in history: [[String: Any]]) -> [[String: Any]] {
        guard history.indices.contains(index), let marked = marking(history[index]["content"]) else { return history }
        var copy = history
        copy[index]["content"] = marked
        return copy
    }

    private static func marking(_ content: Any?) -> [[String: Any]]? {
        if let text = content as? String {
            guard !text.isEmpty else { return nil }
            return [["type": "text", "text": text, "cache_control": marker]]
        }
        guard var blocks = content as? [[String: Any]],
              let index = blocks.lastIndex(where: { cacheableBlocks.contains($0["type"] as? String ?? "") &&
                  ($0["type"] as? String != "text" || !(($0["text"] as? String) ?? "").isEmpty) }) else { return nil }
        blocks[index]["cache_control"] = marker
        return blocks
    }
}
