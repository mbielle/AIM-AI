import Foundation

/// Public citation metadata. Its URL is the stable identity across transports and account merges.
public struct ConversationSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var title: String
    public var domain: String
    public var references: [Int]?
    public init?(url: String, title: String? = nil, references: [Int]? = nil) {
        guard url.utf8.count <= 8192, let value = URLComponents(string: url),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              let host = value.host, !host.isEmpty, value.user == nil, value.password == nil else { return nil }
        self.id = url; self.url = url; self.domain = host
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : host
        self.references = references
    }
    public static func fromTimeline(_ timeline: [RemoteJSONValue]?) -> [Self] {
        (timeline ?? []).compactMap { value in
            guard case .object(let object) = value, object["type"]?.stringValue == "source", let url = object["url"]?.stringValue else { return nil }
            let refs: [Int]? = object["references"]?.arrayValue?.compactMap { item in if case .number(let number) = item { return Int(exactly: number) }; return nil }
            return Self(url: url, title: object["title"]?.stringValue, references: refs)
        }
    }
    public static func merge(_ lhs: [Self]?, _ rhs: [Self]?) -> [Self]? {
        guard lhs != nil || rhs != nil else { return nil }
        var result: [Self] = []
        for source in (lhs ?? []) + (rhs ?? []) {
            guard var safe = Self(url: source.url, title: source.title, references: source.references) else { continue }
            if let index = result.firstIndex(where: { $0.id == safe.id }) {
                safe.references = Array(Set((result[index].references ?? []) + (safe.references ?? []))).sorted()
                result[index] = safe
            } else { result.append(safe) }
        }
        return result
    }
}

/// A presentation only projection. Ambiguous prose and normal links are never removed.
public struct ConversationSourceProjection: Sendable {
    public let text: String
    public let sources: [ConversationSource]
    public init(text: String, sources: [ConversationSource]? = nil) {
        let lines = text.components(separatedBy: "\n")
        guard let heading = lines.lastIndex(where: { ["sources", "## sources", "### sources", "references", "références"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) else {
            self.text = text; self.sources = sources ?? []; return
        }
        let tail = lines.dropFirst(heading + 1).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let pattern = #"^\s*\[(\d+)\]\s+\[([^\]]+)\]\((https?://[^\s)]+)\)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var recognized: [ConversationSource] = []
        for line in tail {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.range == range,
                  let number = Range(match.range(at: 1), in: line), let title = Range(match.range(at: 2), in: line),
                  let url = Range(match.range(at: 3), in: line),
                  let source = ConversationSource(url: String(line[url]), title: String(line[title]), references: Int(line[number]).map { [$0] }) else {
                self.text = text; self.sources = sources ?? []; return
            }
            recognized.append(source)
        }
        guard !recognized.isEmpty else { self.text = text; self.sources = sources ?? []; return }
        self.text = lines.prefix(heading).joined(separator: "\n").trimmingCharacters(in: .newlines)
        self.sources = ConversationSource.merge(sources, recognized) ?? []
    }
}

public extension ConversationSourceProjection {
    var linkedText: String {
        let allowed = Set(sources.flatMap { $0.references ?? [] })
        let expression = try! NSRegularExpression(pattern: #"(?<![\\\[])\[(\d+)\](?![(:\[])"#)
        var fenced = false
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenced.toggle(); return line }
            guard !fenced else { return line }
            return line.components(separatedBy: "`").enumerated().map { index, span in
                guard index % 2 == 0 else { return span }
                var value = span
                for match in expression.matches(in: span, range: NSRange(span.startIndex..., in: span)).reversed() {
                    guard let numberRange = Range(match.range(at: 1), in: span), let number = Int(span[numberRange]), allowed.contains(number), let range = Range(match.range, in: value) else { continue }
                    value.replaceSubrange(range, with: "[&#91;" + String(number) + "&#93;](aim-source://" + String(number) + ")")
                }
                return value
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }
}
