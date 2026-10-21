import Foundation

/// How full a conversation's context window is, and what fills it (the context popover).
/// Parts are AIM's estimates (about 4 bytes per token); when the provider reported the
/// prompt size, the total is the provider's and the parts are scaled to it.
public struct ContextUsage: Codable, Equatable, Sendable {
    public enum Part: String, Codable, CaseIterable, Sendable {
        case messages, summary, systemPrompt, systemTools, mcpTools, skills, memory, projectContext, attachments

        public var title: String {
            switch self {
            case .messages: "Messages"
            case .summary: "Conversation summary"
            case .systemPrompt: "System prompt"
            case .systemTools: "System tools"
            case .mcpTools: "Connector tools"
            case .skills: "Skills"
            case .memory: "Memory"
            case .projectContext: "Project & instructions"
            case .attachments: "Attachments"
            }
        }
    }

    /// Estimated tokens per part.
    public var parts: [String: Int]
    /// The model's context window, when known.
    public var limit: Int?
    /// Prompt + answer tokens the provider reported for the last turn.
    public var reportedTotal: Int?
    /// Where automatic compaction starts, in tokens.
    public var autoCompactAt: Int?
    public var measuredAt: Date

    public init(parts: [Part: Int] = [:], limit: Int? = nil, reportedTotal: Int? = nil, autoCompactAt: Int? = nil, measuredAt: Date = .now) {
        self.parts = Dictionary(uniqueKeysWithValues: parts.map { ($0.key.rawValue, $0.value) })
        self.limit = limit; self.reportedTotal = reportedTotal; self.autoCompactAt = autoCompactAt; self.measuredAt = measuredAt
    }

    public var estimatedTotal: Int { parts.values.reduce(0, +) }
    public var total: Int { reportedTotal ?? estimatedTotal }

    /// A part's share of the real total (estimates scaled to what the provider counted).
    public func tokens(_ part: Part) -> Int {
        let estimate = parts[part.rawValue] ?? 0
        guard let reportedTotal, estimatedTotal > 0 else { return estimate }
        return Int((Double(estimate) / Double(estimatedTotal) * Double(reportedTotal)).rounded())
    }

    public var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(1, Double(total) / Double(limit))
    }

    static func tokens(bytes: Int) -> Int { (bytes + 3) / 4 }

    /// Sorts a request's pieces into parts. Auxiliary context is recognised by the reserved
    /// negative sequences AIM gives it (project −1, personalization −2, memory or summary −3,
    /// skills −4, environment −5/−6/−9, project instructions −7/−8).
    public static func estimate(messages: [ConversationMessage], systemPrompt: String = "",
                                tools: [ModelToolDefinition] = [], limit: Int?, autoCompactBytes: Int? = nil) -> ContextUsage {
        var parts: [Part: Int] = [:]
        for message in messages {
            let attachmentBytes = (message.attachments ?? []).reduce(0) { $0 + $1.content.utf8.count }
                + (message.images ?? []).reduce(0) { $0 + min($1.data.count, 6_000) }
            if attachmentBytes > 0 { parts[.attachments, default: 0] += tokens(bytes: attachmentBytes) }
            let part: Part
            switch message.sequence {
            case 0...: part = .messages
            case -3: part = message.content.hasPrefix("Earlier conversation summary") ? .summary : .memory
            case -4: part = .skills
            case -1, -2, -7, -8: part = .projectContext
            default: part = .systemPrompt
            }
            parts[part, default: 0] += tokens(bytes: message.content.utf8.count + 16)
        }
        if !systemPrompt.isEmpty { parts[.systemPrompt, default: 0] += tokens(bytes: systemPrompt.utf8.count) }
        for tool in tools {
            let bytes = tool.name.utf8.count + tool.description.utf8.count
                + (tool.requiredArguments.count + tool.optionalArguments.count) * 48 + 96
            parts[tool.name.hasPrefix("mcp__") ? .mcpTools : .systemTools, default: 0] += tokens(bytes: bytes)
        }
        return ContextUsage(parts: parts, limit: limit, autoCompactAt: autoCompactBytes.map { tokens(bytes: $0) })
    }
}
