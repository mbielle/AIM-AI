import Foundation

/// Token counts and engine timings reported by a provider for one request. Every field is
/// optional: providers report different subsets, and some report them across several events.
public struct TokenUsage: Codable, Equatable, Sendable {
    /// Whole prompt, cached part included.
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    /// Visible answer plus reasoning.
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    /// Local engines only: prompt tokens actually processed (not served from the KV cache).
    public var processedPromptTokens: Int?
    public var promptSeconds: Double?
    public var generationSeconds: Double?
    /// "mlx" or "llama.cpp" when a local engine reported its timings.
    public var engine: String?

    public init(inputTokens: Int? = nil, cachedInputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
                processedPromptTokens: Int? = nil, promptSeconds: Double? = nil, generationSeconds: Double? = nil, engine: String? = nil) {
        self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens
        self.processedPromptTokens = processedPromptTokens; self.promptSeconds = promptSeconds
        self.generationSeconds = generationSeconds; self.engine = engine
    }

    public var isEmpty: Bool { self == TokenUsage() }

    /// Later events win field by field (Anthropic sends input first, output at the end).
    public mutating func merge(_ other: TokenUsage) {
        inputTokens = other.inputTokens ?? inputTokens
        cachedInputTokens = other.cachedInputTokens ?? cachedInputTokens
        outputTokens = other.outputTokens ?? outputTokens
        reasoningTokens = other.reasoningTokens ?? reasoningTokens
        processedPromptTokens = other.processedPromptTokens ?? processedPromptTokens
        promptSeconds = other.promptSeconds ?? promptSeconds
        generationSeconds = other.generationSeconds ?? generationSeconds
        engine = other.engine ?? engine
    }

    /// Several requests of one turn (an Agent's tool steps) add up.
    public mutating func add(_ other: TokenUsage) {
        func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? { a.map { $0 + (b ?? .zero) } ?? b }
        inputTokens = sum(inputTokens, other.inputTokens)
        cachedInputTokens = sum(cachedInputTokens, other.cachedInputTokens)
        outputTokens = sum(outputTokens, other.outputTokens)
        reasoningTokens = sum(reasoningTokens, other.reasoningTokens)
        processedPromptTokens = sum(processedPromptTokens, other.processedPromptTokens)
        promptSeconds = sum(promptSeconds, other.promptSeconds)
        generationSeconds = sum(generationSeconds, other.generationSeconds)
        engine = other.engine ?? engine
    }
}

/// Reads usage from any provider's JSON event or response: OpenAI-style chat completions
/// (`usage.prompt_tokens`), llama.cpp/AIM MLX `timings`, OpenAI/xAI Responses
/// (`response.usage.input_tokens`), Anthropic (`message.usage`, `usage`), Gemini (`usageMetadata`).
public enum TokenUsageParser {
    public static func parse(_ payload: String) -> TokenUsage? {
        guard payload.contains("usage") || payload.contains("timings") || payload.contains("Usage"),
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        return parse(json)
    }

    public static func parse(_ data: Data) -> TokenUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json)
    }

    public static func parse(_ json: [String: Any]) -> TokenUsage? {
        var usage = TokenUsage()
        let container = json["usage"] as? [String: Any]
            ?? (json["response"] as? [String: Any])?["usage"] as? [String: Any]
            ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any]
        if let container { usage.merge(standard(container)) }
        if let gemini = json["usageMetadata"] as? [String: Any] {
            let thoughts = int(gemini["thoughtsTokenCount"])
            let candidates = int(gemini["candidatesTokenCount"])
            usage.merge(TokenUsage(inputTokens: int(gemini["promptTokenCount"]), cachedInputTokens: int(gemini["cachedContentTokenCount"]),
                                   outputTokens: candidates.map { $0 + (thoughts ?? 0) } ?? thoughts, reasoningTokens: thoughts))
        }
        if let timings = json["timings"] as? [String: Any] {
            let predictedMS = double(timings["predicted_ms"])
            let promptMS = double(timings["prompt_ms"])
            usage.merge(TokenUsage(outputTokens: int(timings["predicted_n"]) ?? usage.outputTokens,
                                   processedPromptTokens: int(timings["prompt_n"]),
                                   promptSeconds: promptMS.map { $0 / 1000 }, generationSeconds: predictedMS.map { $0 / 1000 },
                                   engine: timings["engine"] as? String ?? "llama.cpp"))
            if usage.cachedInputTokens == nil, let cached = int(timings["cache_n"]), cached > 0 { usage.cachedInputTokens = cached }
        }
        return usage.isEmpty ? nil : usage
    }

    private static func standard(_ usage: [String: Any]) -> TokenUsage {
        var result = TokenUsage()
        // Anthropic counts cache reads and writes outside input_tokens.
        let cacheRead = int(usage["cache_read_input_tokens"])
        let cacheWrite = int(usage["cache_creation_input_tokens"])
        if let input = int(usage["prompt_tokens"]) ?? int(usage["input_tokens"]) {
            result.inputTokens = input + (usage["prompt_tokens"] == nil ? (cacheRead ?? 0) + (cacheWrite ?? 0) : 0)
        }
        result.outputTokens = int(usage["completion_tokens"]) ?? int(usage["output_tokens"])
        let inputDetails = usage["prompt_tokens_details"] as? [String: Any] ?? usage["input_tokens_details"] as? [String: Any]
        let outputDetails = usage["completion_tokens_details"] as? [String: Any] ?? usage["output_tokens_details"] as? [String: Any]
        result.cachedInputTokens = int(inputDetails?["cached_tokens"]) ?? cacheRead
        result.reasoningTokens = int(outputDetails?["reasoning_tokens"])
        return result
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
