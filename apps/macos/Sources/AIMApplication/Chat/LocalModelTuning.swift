import Foundation

/// What AIM sends to a local model so small open models answer well: real instructions,
/// the sampling settings their makers recommend, and "thinking" only when asked.
public enum LocalModelTuning {
    public static func systemPrompt(mode: AIMMode, now: Date = .now) -> String {
        let date = now.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "en_US")))
        var prompt = """
        You are AIM, a helpful assistant running privately on the person's Mac. Today is \(date).
        Reply in the same language as the person's last message, with natural, correct grammar and spelling.
        Match the depth of your answer to the request: a short, direct answer to a simple question; when the person asks \
        for an explanation, details or precision, give a complete, well-structured answer (headings, lists, examples, \
        steps) and cover the subject fully. Never stop in the middle of an explanation. If you are not sure, say so instead of guessing.
        """
        if mode != .chat { prompt += "\nYou cannot run tools or change files in this conversation; describe what to do instead." }
        return prompt
    }

    /// Models whose chat template supports a thinking switch.
    public static func supportsThinking(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return ["qwen3", "qwq", "deepseek-r1", "gpt-oss", "magistral", "reasoning", "thinking"].contains { id.contains($0) }
    }

    /// Thinking is off unless the person picks a level above "None" (faster answers by default).
    public static func thinks(modelID: String, effort: OpenAIReasoningEffort?) -> Bool {
        guard supportsThinking(modelID: modelID) else { return false }
        guard let effort else { return false }
        return effort != .none
    }

    /// Request fields for llama.cpp's OpenAI-compatible server.
    public static func sampling(modelID: String, thinking: Bool) -> [String: Any] {
        let id = modelID.lowercased()
        var fields: [String: Any]
        if id.contains("qwen3") || id.contains("qwq") {
            // Qwen's published settings for thinking / non-thinking use.
            fields = thinking ? ["temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0]
                              : ["temperature": 0.7, "top_p": 0.8, "top_k": 20, "min_p": 0]
        } else if id.contains("gemma") {
            fields = ["temperature": 1.0, "top_p": 0.95, "top_k": 64]
        } else {
            fields = ["temperature": 0.7, "top_p": 0.9]
        }
        if supportsThinking(modelID: modelID) {
            fields["chat_template_kwargs"] = ["enable_thinking": thinking]
        }
        return fields
    }
}
