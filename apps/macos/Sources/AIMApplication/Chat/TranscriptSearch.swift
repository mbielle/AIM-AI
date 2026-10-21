import Foundation

public struct TranscriptSearchResult: Sendable {
    public struct Match: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let messageID: UUID
        public let offset: Int
        public let excerpt: String
    }
    public let matches: [Match]
    public let isTruncated: Bool
}

/// One result per occurrence, in transcript order. Attachments and hidden
/// tool/system context are intentionally outside this local text search.
public enum TranscriptSearch {
    public static func find(_ query: String, in messages: [ConversationMessage], limit: Int = 200) -> TranscriptSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256, limit > 0 else { return .init(matches: [], isTruncated: false) }
        var matches: [TranscriptSearchResult.Match] = []
        var remainingBytes = 20 * 1_024 * 1_024
        var truncated = false
        for message in messages {
            if Task.isCancelled { return .init(matches: matches, isTruncated: true) }
            guard message.role == .user || message.role == .assistant else { continue }
            guard remainingBytes > 0 else { truncated = true; break }
            let budget = min(remainingBytes, 1_024 * 1_024)
            let bytes = message.content.utf8.prefix(budget + 1)
            if bytes.count > budget { truncated = true }
            let text = String(decoding: bytes.prefix(budget), as: UTF8.self)
            remainingBytes -= min(bytes.count, budget)
            var cursor = text.startIndex
            var first = true
            while cursor < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex) {
                guard matches.count < limit else { truncated = true; break }
                let start = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
                matches.append(.init(id: first ? message.id : UUID(), messageID: message.id,
                                     offset: text.distance(from: text.startIndex, to: range.lowerBound),
                                     excerpt: (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")))
                first = false; cursor = range.upperBound
            }
        }
        return .init(matches: matches, isTruncated: truncated)
    }
}
