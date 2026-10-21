import Foundation
import Markdown

/// A normalized, safe Markdown value shared by Remote conversations and Projects.
///
/// The web client has to repair a number of recurring model-output mistakes before
/// passing text to remark-gfm. Keeping that work in a pure type makes the native
/// renderer deterministic and independently testable.
public struct AIMMarkdownDocument: Equatable, Sendable {
    public let source: String
    public let normalizedSource: String
    public let containsUnsafeHTML: Bool
    public let nodeCount: Int
    public let blocks: [AIMMarkdownBlockNode]

    public init(source: String) {
        self.source = source
        containsUnsafeHTML = AIMMarkdownNormalizer.containsUnsafeHTML(source)
        normalizedSource = AIMMarkdownNormalizer.normalize(source)

        let document = Document(parsing: normalizedSource)
        var counter = AIMMarkdownNodeCounter()
        counter.visit(document)
        nodeCount = counter.count
        blocks = AIMMarkdownAST.blocks(in: document)
    }
}

public enum AIMMarkdownBlockNode: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case list(AIMMarkdownListNode)
    case quote(String)
    case code(language: String?, content: String)
    case math(content: String, display: Bool)
    case table(headers: [String], rows: [[String]])
    case rule
}

public struct AIMMarkdownListItemNode: Equatable, Sendable {
    public let text: String
    public let children: [AIMMarkdownListNode]

    public init(text: String, children: [AIMMarkdownListNode] = []) {
        self.text = text
        self.children = children
    }
}

public indirect enum AIMMarkdownListNode: Equatable, Sendable {
    case unordered([AIMMarkdownListItemNode])
    case ordered([AIMMarkdownListItemNode])

    public var items: [AIMMarkdownListItemNode] {
        switch self {
        case let .unordered(items), let .ordered(items): items
        }
    }
}

private enum AIMMarkdownAST {
    static func blocks(in document: Document) -> [AIMMarkdownBlockNode] {
        document.children.compactMap(block)
    }

    private static func block(_ markup: any Markup) -> AIMMarkdownBlockNode? {
        if let heading = markup as? Heading {
            return .heading(level: heading.level, text: inlineSource(heading))
        }
        if let paragraph = markup as? Paragraph {
            let source = inlineSource(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            if source.hasPrefix("$$"), source.hasSuffix("$$"), source.count > 4 {
                return .math(
                    content: String(source.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines),
                    display: true
                )
            }
            if source.hasPrefix("$"), source.hasSuffix("$"), source.count > 2 {
                return .math(content: String(source.dropFirst().dropLast()), display: false)
            }
            return source.isEmpty ? nil : .paragraph(source)
        }
        if let list = markup as? UnorderedList {
            let node = listNode(list, ordered: false)
            return node.items.contains(where: { !$0.children.isEmpty })
                ? .list(node)
                : .unorderedList(node.items.map(\.text))
        }
        if let list = markup as? OrderedList {
            let node = listNode(list, ordered: true)
            return node.items.contains(where: { !$0.children.isEmpty })
                ? .list(node)
                : .orderedList(node.items.map(\.text))
        }
        if let quote = markup as? BlockQuote {
            let text = quote.children.map { child in
                if let paragraph = child as? Paragraph { return inlineSource(paragraph) }
                return child.format().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\s*>\s?"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
            return .quote(text)
        }
        if let code = markup as? CodeBlock {
            return .code(language: code.language, content: code.code.trimmingCharacters(in: .newlines))
        }
        if let table = markup as? Table {
            let headers = rowCells(table.head)
            let rows: [[String]] = table.body.children.compactMap { row -> [String]? in
                guard let row = row as? Table.Row else { return nil }
                return rowCells(row)
            }
            return .table(headers: headers, rows: rows)
        }
        if markup is ThematicBreak { return .rule }
        // Raw HTML is intentionally omitted. The normalizer already removes the
        // dangerous forms, but native screens never execute arbitrary HTML.
        return nil
    }

    private static func inlineSource(_ container: any InlineContainer) -> String {
        container.inlineChildren.map { child in
            if child is SoftBreak || child is LineBreak { return "\n" }
            // Detached first: inside a list item `format()` prefixes text runs with the item's
            // indentation, which put a wide gap after a bold lead-in ("**Title**    : text").
            return child.detachedFromParent.format()
        }.joined()
    }

    private static func listNode(_ list: any Markup, ordered: Bool) -> AIMMarkdownListNode {
        let items = list.children.compactMap { child -> AIMMarkdownListItemNode? in
            guard let item = child as? ListItem else { return nil }
            let text = item.children.compactMap { child -> String? in
                guard let paragraph = child as? Paragraph else { return nil }
                return inlineSource(paragraph)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            let children = item.children.compactMap { child -> AIMMarkdownListNode? in
                if let nested = child as? UnorderedList { return listNode(nested, ordered: false) }
                if let nested = child as? OrderedList { return listNode(nested, ordered: true) }
                return nil
            }
            guard !text.isEmpty || !children.isEmpty else { return nil }
            return .init(text: text, children: children)
        }
        return ordered ? .ordered(items) : .unordered(items)
    }

    private static func rowCells(_ row: any Markup) -> [String] {
        row.children.compactMap { cell in
            guard let cell = cell as? Table.Cell else { return nil }
            return inlineSource(cell)
        }
    }
}

private struct AIMMarkdownNodeCounter: MarkupWalker {
    var count = 0

    mutating func defaultVisit(_ markup: any Markup) {
        count += 1
        descendInto(markup)
    }
}

public enum AIMMarkdownNormalizer {
    private static let exoticBulletCharacters = CharacterSet(
        charactersIn: "•▪▫◦●◯‣⁃►▶▸▹→➔➜✦✧★☆∙·∎❖❯◆◇♦"
    )

    /// Mirrors the recovery pipeline used by the web renderer while deliberately
    /// neutralising raw HTML. Native views render links and images explicitly, so
    /// preserving arbitrary HTML would only increase the attack surface.
    public static func normalize(_ source: String) -> String {
        var normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        normalized = neutralizeUnsafeHTML(in: normalized)

        // Convert the website's alternate delimiters first so formula contents are
        // protected from the prose-oriented algebra repairs below.
        normalized = transformOutsideFences(normalized) { chunk in
            var value = chunk
            value = replace(#"\\\\\[([\s\S]*?)\\\\\]"#, in: value, with: "\n\\$\\$\n$1\n\\$\\$\n")
            value = replace(#"\\\[([\s\S]*?)\\\]"#, in: value, with: "\n\\$\\$\n$1\n\\$\\$\n")
            value = replace(#"\\\\\(([\s\S]*?)\\\\\)"#, in: value, with: "\\$$1\\$")
            value = replace(#"\\\(([\s\S]*?)\\\)"#, in: value, with: "\\$$1\\$")
            return value
        }

        normalized = transformOutsideProtectedRegions(normalized) { chunk in
            var value = chunk
            value = replace(
                #"([)\]}a-zA-Z])(\d{1,2})\.\s*(\\[a-zA-Z]+|[a-zA-Z]\s*\()"#,
                in: value,
                with: "$1\n$2. $3"
            )
            value = replace(#"\be\^\(([^()\n]{1,80})\)"#, in: value, with: #"\$e^{$1}\$"#)
            value = replace(#"\b([A-Za-z])\^(-?\d+)\b"#, in: value, with: #"\$$1^{$2}\$"#)
            return value
        }

        normalized = replace(#"^[\s]*[─━—–-]{3,}[\s]*$"#, in: normalized, with: "\n\n---\n\n", anchorsMatchLines: true)
        normalized = replace(#"^(#{1,6})([^\s#])"#, in: normalized, with: "$1 $2", anchorsMatchLines: true)
        normalized = replace(#"^(#{1,6})\s{2,}"#, in: normalized, with: "$1 ", anchorsMatchLines: true)
        normalized = replace(#"([^\n])\n(#{1,6}\s)"#, in: normalized, with: "$1\n\n$2")

        normalized = normalizeListMarkers(in: normalized)
        normalized = normalizeOrderedListSequence(in: normalized)
        normalized = repairTables(in: normalized)
        normalized = replace(#"\n{3,}"#, in: normalized, with: "\n\n")
        return normalized.trimmingCharacters(in: .newlines)
    }

    public static func containsUnsafeHTML(_ source: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"<\s*/?\s*(script|style|iframe|object|embed|form|input|button|meta|link)\b|\son[a-z]+\s*="#,
            options: [.caseInsensitive]
        ) else { return false }
        return expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }

    private static func neutralizeUnsafeHTML(in source: String) -> String {
        var result = source
        for element in ["script", "style", "iframe", "object", "embed", "form", "button"] {
            result = replace(
                #"<\s*\#(element)\b[^>]*>[\s\S]*?<\s*/\s*\#(element)\s*>"#,
                in: result,
                with: "",
                caseInsensitive: true
            )
        }
        result = replace(
            #"<\s*/?\s*(script|style|iframe|object|embed|form|input|button|meta|link)\b[^>]*>"#,
            in: result,
            with: "",
            caseInsensitive: true
        )
        result = replace(#"<!--[\s\S]*?-->"#, in: result, with: "")
        return result
    }

    private static func normalizeListMarkers(in source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let line = String(rawLine)
                let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return line }

                if let first = trimmed.unicodeScalars.first,
                   exoticBulletCharacters.contains(first),
                   trimmed.dropFirst().first?.isWhitespace == true {
                    return indentation + "- " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                }

                if let match = firstMatch(#"^(\d+)[\.)][\s\u00A0\u2000-\u200B\u202F]+(.+)$"#, in: trimmed),
                   match.count == 3 {
                    return indentation + match[1] + ". " + match[2]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private static func normalizeOrderedListSequence(in source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var expected: Int?
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                expected = nil
                continue
            }
            guard let match = firstMatch(#"^(\s*)(\d+)\.\s+(.+)$"#, in: line), match.count == 4 else {
                if !line.hasPrefix("  ") && !line.hasPrefix("\t") { expected = nil }
                continue
            }
            let current = expected ?? 1
            lines[index] = match[1] + String(current) + ". " + match[3]
            expected = current + 1
        }
        return lines.joined(separator: "\n")
    }

    private static func repairTables(in source: String) -> String {
        transformOutsideFences(source) { segment in
            var output: [String] = []
            let lines = segment.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            var inTable = false

            while index < lines.count {
                let line = lines[index]
                guard let columns = pipeColumnCount(line), columns >= 2 else {
                    inTable = false
                    output.append(line)
                    index += 1
                    continue
                }
                if inTable {
                    output.append(line)
                    index += 1
                    continue
                }
                let next = lines.indices.contains(index + 1) ? lines[index + 1] : nil
                let following = lines.indices.contains(index + 2) ? lines[index + 2] : nil
                if let next, isValidDelimiter(next, columns: columns) {
                    output.append(line)
                    inTable = true
                    index += 1
                    continue
                }
                let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
                if let next, isBrokenDelimiter(next), let following, pipeColumnCount(following) == columns {
                    output.append(contentsOf: [line, delimiter])
                    inTable = true
                    index += 2
                    continue
                }
                if let next, pipeColumnCount(next) == columns {
                    output.append(contentsOf: [line, delimiter])
                    inTable = true
                    index += 1
                    continue
                }
                output.append(line)
                index += 1
            }
            return output.joined(separator: "\n")
        }
    }

    private static func pipeColumnCount(_ line: String) -> Int? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("|"), value.hasSuffix("|"), value.count > 2 else { return nil }
        return value.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).count
    }

    private static func isValidDelimiter(_ line: String, columns: Int) -> Bool {
        guard pipeColumnCount(line) == columns else { return false }
        return line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
            .allSatisfy { rawCell in
                let value = rawCell.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return value.count >= 3 && value.allSatisfy { $0 == "-" }
            }
    }

    private static func isBrokenDelimiter(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.contains("|") && value.allSatisfy { "|-: \t".contains($0) }
    }

    private static func transformOutsideFences(_ source: String, transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"```[\s\S]*?```|~~~[\s\S]*?~~~"#) else {
            return transform(source)
        }
        return transformOutsideMatches(source, expression: expression, transform: transform)
    }

    private static func transformOutsideProtectedRegions(_ source: String, transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`|\$\$[\s\S]*?\$\$|(?<!\$)\$[^$\n]+?\$(?!\$)"#
        ) else { return transform(source) }
        return transformOutsideMatches(source, expression: expression, transform: transform)
    }

    private static func transformOutsideMatches(
        _ source: String,
        expression: NSRegularExpression,
        transform: (String) -> String
    ) -> String {
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return transform(source) }
        var result = ""
        var location = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            result += transform(String(source[location..<range.lowerBound]))
            result += source[range]
            location = range.upperBound
        }
        result += transform(String(source[location...]))
        return result
    }

    private static func replace(
        _ pattern: String,
        in source: String,
        with template: String,
        anchorsMatchLines: Bool = false,
        caseInsensitive: Bool = false
    ) -> String {
        var options: NSRegularExpression.Options = []
        if anchorsMatchLines { options.insert(.anchorsMatchLines) }
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: template
        )
    }

    private static func firstMatch(_ pattern: String, in source: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: source) else { return "" }
            return String(source[range])
        }
    }
}
