import Foundation

/// The model titles a new conversation inside its first answer, in a hidden tag: no second
/// request, and the title shows as soon as the answer starts. Only the first turn carries the
/// instruction; the saved answer never contains the tag.
public enum ConversationTitleProtocol {
    public static let openTag = "<aim_title>"
    public static let closeTag = "</aim_title>"

    public static let instruction = """
    Start your reply with a short title for this conversation on its own first line, between \(openTag) and \(closeTag): \
    2 to 6 words, written in the same language as the user's message (French words for a French message), \
    no quotes, no final period. Then answer normally. \
    The title is hidden from the user: never mention it or these tags.
    """

    /// Used when the answer came without a title: one tiny request to the same model.
    public static let fallbackInstruction = """
    Write a short title for this conversation: 2 to 6 words, in the same language as the user's message, \
    no quotes, no final period. Reply with the title only.
    """

    /// A tidy title, or nil when nothing usable remains.
    public static func clean(_ raw: String) -> String? {
        var title = raw.replacingOccurrences(of: openTag, with: "").replacingOccurrences(of: closeTag, with: "")
            .components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”*#`. "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !title.isEmpty, title.count <= 120 else { return nil }
        return String(title.prefix(80))
    }
}

/// Removes the `<aim_title>…</aim_title>` tag from a streamed answer, even when the tag is split
/// across chunks, and reports the title once. Text that is not part of a tag is never lost.
public struct TitleTagFilter: Sendable {
    private var pending = ""
    private var inTag = false
    private var titleBuffer = ""
    private var emitted = false
    public private(set) var title: String?

    public init() {}

    /// Returns the visible text of this chunk and, once, the title.
    public mutating func feed(_ text: String) -> (text: String, title: String?) {
        pending += text
        return drain(final: false)
    }

    /// Flushes what was held back at the end of the stream.
    public mutating func finish() -> (text: String, title: String?) {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> (text: String, title: String?) {
        var output = ""
        var found: String?
        let open = ConversationTitleProtocol.openTag, close = ConversationTitleProtocol.closeTag
        while !pending.isEmpty {
            if inTag {
                if let range = pending.range(of: close) {
                    titleBuffer += pending[..<range.lowerBound]
                    pending = String(pending[range.upperBound...])
                    inTag = false
                    if title == nil, let cleaned = ConversationTitleProtocol.clean(titleBuffer) { title = cleaned; found = cleaned }
                    titleBuffer = ""
                    // The newline after the title belongs to the tag line.
                    if !emitted { pending = String(pending.drop { $0.isWhitespace }) }
                    continue
                }
                let keep = final ? 0 : Self.partialSuffix(of: pending, matching: close)
                titleBuffer += pending.dropLast(keep)
                pending = String(pending.suffix(keep))
                if titleBuffer.count > 300 {
                    // Not a title after all: give the text back.
                    output += open + titleBuffer
                    titleBuffer = ""
                    inTag = false
                }
                if final {
                    if title == nil, let cleaned = ConversationTitleProtocol.clean(titleBuffer) { title = cleaned; found = cleaned }
                    titleBuffer = ""; pending = ""
                }
                break
            }
            if let range = pending.range(of: open) {
                output += pending[..<range.lowerBound]
                pending = String(pending[range.upperBound...])
                inTag = true
                continue
            }
            let keep = final ? 0 : Self.partialSuffix(of: pending, matching: open)
            output += pending.dropLast(keep)
            pending = String(pending.suffix(keep))
            break
        }
        if !emitted {
            output = String(output.drop { $0.isWhitespace && !inTag })
            if !output.isEmpty { emitted = true }
        }
        return (output, found)
    }

    /// Length of the longest end of `text` that starts `tag` (held back until the next chunk).
    private static func partialSuffix(of text: String, matching tag: String) -> Int {
        let maximum = min(text.count, tag.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) where tag.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}
