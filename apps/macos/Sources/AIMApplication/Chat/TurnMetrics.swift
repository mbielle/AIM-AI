import Foundation
import AIMCore

public typealias TokenUsage = AIMCore.TokenUsage
public typealias TokenUsageParser = AIMCore.TokenUsageParser

/// What AIM measured for one answer: shown under the message and summed in the profile.
public struct TurnMetrics: Codable, Equatable, Sendable {
    public var provider: String
    public var modelID: String
    public var mode: String
    public var effort: String?
    public var startedAt: Date
    public var usage: TokenUsage
    /// From sending to the first visible words.
    public var firstTokenSeconds: Double?
    /// From the first visible words to the end of the answer (wall clock).
    public var streamSeconds: Double?
    public var totalSeconds: Double
    /// Visible characters, for an estimate when the provider reports no token count.
    public var characters: Int
    public var costUSD: Double?
    public var routeAttempts: [ConversationRouteAttempt]?
    public var sources: [ConversationSource]?
    public var webSearchUsage: NativeWebSearchUsage?
    public var webSearchActivities: [NativeWebSearchActivity]?

    public init(provider: String, modelID: String, mode: String, effort: String? = nil, startedAt: Date, usage: TokenUsage = .init(),
                firstTokenSeconds: Double? = nil, streamSeconds: Double? = nil, totalSeconds: Double, characters: Int = 0, costUSD: Double? = nil,
                webSearchUsage: NativeWebSearchUsage? = nil, webSearchActivities: [NativeWebSearchActivity]? = nil, sources: [ConversationSource]? = nil, routeAttempts: [ConversationRouteAttempt]? = nil) {
        self.routeAttempts = routeAttempts
        self.sources = sources
        self.provider = provider; self.modelID = modelID; self.mode = mode; self.effort = effort; self.startedAt = startedAt
        self.usage = usage; self.firstTokenSeconds = firstTokenSeconds; self.streamSeconds = streamSeconds
        self.totalSeconds = totalSeconds; self.characters = characters; self.costUSD = costUSD
        self.webSearchUsage = webSearchUsage; self.webSearchActivities = webSearchActivities
    }

    public var isLocal: Bool { provider == "local" }
    /// True when the output count is AIM's estimate (about 4 characters per token).
    public var outputIsEstimated: Bool { usage.outputTokens == nil }
    public var outputTokens: Int { usage.outputTokens ?? max(characters / 4, 0) }
    public var totalTokens: Int { (usage.inputTokens ?? 0) + outputTokens }

    /// The engine's own generation speed when it reports it, else output over streaming time.
    public var outputTokensPerSecond: Double? {
        if let seconds = usage.generationSeconds, seconds > 0, let tokens = usage.outputTokens { return Double(tokens) / seconds }
        guard let seconds = streamSeconds, seconds > 0.05, outputTokens > 0 else { return nil }
        return Double(outputTokens) / seconds
    }

    public var promptTokensPerSecond: Double? {
        guard let seconds = usage.promptSeconds, seconds > 0,
              let tokens = usage.processedPromptTokens ?? usage.inputTokens, tokens > 0 else { return nil }
        return Double(tokens) / seconds
    }
}
