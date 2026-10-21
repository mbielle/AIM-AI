import Foundation
import Markdown

/// A display-only projection of observed project-source references. Stored text, tool arguments,
/// IDs, chunk ordinals and timeline offsets are never rewritten. Unknown references stay intact.
public struct ProjectSourceCitationPresentation: Sendable {
    private struct Reference: Sendable {
        let marker: String
        let name: String
        let chunk: Int
    }
    private let references: [String: Reference]

    public init(message: NativeChatMessage, attachments: [NativeChatAttachment] = []) {
        guard message.role == .assistant else { references = [:]; return }
        var found: [String: Reference] = [:]
        for activity in message.skillActivities ?? [] where ProjectSourceTools.contains(activity.name) && !activity.isError && activity.running != true {
            Self.collect(activity.detail, into: &found)
        }
        for action in message.actions ?? [] where ProjectSourceTools.contains(action.name) && action.state == .completed && action.turnID == message.id {
            Self.collect(action.output, into: &found)
            Self.collect(action.detail, into: &found)
        }
        for attachment in attachments {
            guard let sourceID = attachment.projectSourceID, Self.validName(attachment.name), let text = attachment.text,
                  text.utf8.count <= 64_000 else { continue }
            // Only explicitly attributed project attachments qualify; a manually attached code file
            // containing the same string is not evidence of a project-source citation.
            for match in Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), UUID(uuidString: String(text[range])) == sourceID,
                      let index = Range(match.range(at: 2), in: text), let number = Int(text[index]), number > 0,
                      let markerRange = Range(match.range, in: text) else { continue }
                let marker = String(text[markerRange]).lowercased()
                found[marker] = Reference(marker: marker, name: attachment.name, chunk: number - 1)
                if found.count >= 128 { break }
            }
        }
        references = found
    }

    /// Apply after the timeline has sliced the original content. Markdown code/links/HTML remain
    /// intact, except a standalone inline-code citation that exactly names a known reference.
    public func displayed(_ text: String, markdown: Bool = true) -> String {
        guard !references.isEmpty, text.utf8.count <= 1_000_000, text.range(of: "source:", options: .caseInsensitive) != nil else { return text }
        var protected = ProtectedRanges(source: text, references: references, markdown: markdown)
        protected.visit(Document(parsing: text))
        var replacements = protected.citations
        for match in Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard !protected.ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let swiftRange = Range(match.range, in: text), let reference = references[String(text[swiftRange]).lowercased()] else { continue }
            var range = match.range, label = Self.label(reference.name, markdown: markdown)
            let original = text as NSString, end = range.location + range.length
            if range.location > 0, end < original.length, original.character(at: range.location - 1) == 91, original.character(at: end) == 93 {
                range = NSRange(location: range.location - 1, length: range.length + 2)
                label = "[" + label + "]"
            }
            replacements.append(Replacement(range: Self.withLegacySuffix(range, reference: reference, source: text), text: label))
        }
        var result = text
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement.text)
        }
        return result
    }

    private static let pattern = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_:/])source:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})#([1-9][0-9]{0,5})(?![A-Za-z0-9_-])"#)
    private struct Envelope: Decodable { let excerpts: [Excerpt] }
    private struct Excerpt: Decodable { let sourceID: String, chunkID: String, name: String, citation: String }
    private static func collect(_ output: String?, into references: inout [String: Reference]) {
        guard let output, output.utf8.count <= 20_480, references.count < 128 else { return }
        // Build 46 saved compact tool JSON after the action's query/path and a blank line.
        // Accept that exact envelope, never mine arbitrary answer prose for an asserted filename.
        let body = output.range(of: "\n\n{", options: .backwards).map { String(output[$0.upperBound...]) }
        let json = body.map { "{" + $0 } ?? output
        guard let bytes = json.data(using: .utf8), bytes.count <= ProjectSourceTools.maximumResultBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes), envelope.excerpts.count <= 8 else { return }
        for excerpt in envelope.excerpts {
            guard let sourceID = UUID(uuidString: excerpt.sourceID), let chunk = Int(excerpt.chunkID), (0..<10_000).contains(chunk), validName(excerpt.name) else { continue }
            let marker = "source:\(sourceID.uuidString.lowercased())#\(chunk + 1)"
            guard excerpt.citation.lowercased() == marker else { continue }
            references[marker] = Reference(marker: marker, name: excerpt.name, chunk: chunk)
        }
    }
    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 255 && name.utf8.count <= 1_024 && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func label(_ name: String, markdown: Bool) -> String {
        guard markdown else { return name }
        return name.reduce(into: "") { output, character in
            if "\\`*_{}[]()#+-.!|>~<".contains(character) { output.append("\\") }
            output.append(character)
        }
    }
    private static func withLegacySuffix(_ range: NSRange, reference: Reference, source: String) -> NSRange {
        let end = range.location + range.length
        guard let tailRange = Range(NSRange(location: end, length: (source as NSString).length - end), in: source) else { return range }
        let suffix = String(source[tailRange].prefix(1_200))
        let pattern = "^[ \\t]*\\(" + NSRegularExpression.escapedPattern(for: reference.name) + ",[ \\t]*chunk[ \\t]+" + String(reference.chunk) + "\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) else { return range }
        return NSRange(location: range.location, length: range.length + match.range.length)
    }
    private struct Replacement { let range: NSRange; let text: String }
    private struct ProtectedRanges: MarkupWalker {
        let source: String
        let references: [String: Reference]
        let markdown: Bool
        var ranges: [NSRange] = []
        var citations: [Replacement] = []
        mutating func visitCodeBlock(_ code: CodeBlock) { protect(code) }
        mutating func visitLink(_ link: Link) { protect(link) }
        mutating func visitImage(_ image: Markdown.Image) { protect(image) }
        mutating func visitHTMLBlock(_ html: HTMLBlock) { protect(html) }
        mutating func visitInlineHTML(_ html: InlineHTML) { protect(html) }
        mutating func visitInlineCode(_ code: InlineCode) {
            guard let range = range(code) else { return }
            ranges.append(range)
            var literal = code.code
            if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
            guard let match = SelfProjection.pattern.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)), match.range.location == 0,
                  let markerRange = Range(match.range, in: literal), let reference = references[String(literal[markerRange]).lowercased()],
                  SelfProjection.withLegacySuffix(match.range, reference: reference, source: literal).length == (literal as NSString).length else { return }
            citations.append(Replacement(range: SelfProjection.withLegacySuffix(range, reference: reference, source: source), text: SelfProjection.label(reference.name, markdown: markdown)))
        }
        private typealias SelfProjection = ProjectSourceCitationPresentation
        private mutating func protect(_ node: any Markup) { if let range = range(node) { ranges.append(range) } }
        private func range(_ node: any Markup) -> NSRange? {
            guard let range = node.range else { return nil }
            func offset(_ location: SourceLocation) -> String.Index? {
                var line = 1, index = source.utf8.startIndex
                while line < location.line, index < source.utf8.endIndex {
                    if source.utf8[index] == 10 { line += 1 }
                    index = source.utf8.index(after: index)
                }
                guard line == location.line, let value = source.utf8.index(index, offsetBy: location.column - 1, limitedBy: source.utf8.endIndex) else { return nil }
                return String.Index(value, within: source)
            }
            guard let lower = offset(range.lowerBound), let upper = offset(range.upperBound), lower <= upper else { return nil }
            return NSRange(lower..<upper, in: source)
        }
    }
}
