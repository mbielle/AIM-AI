import AIMCore
import AIMApplication
import AppKit
import SwiftUI

/// Parsed Markdown by source text, so a reopened conversation shows formatted text at once.
final class MarkdownBlockCache: @unchecked Sendable {
    static let shared = MarkdownBlockCache()
    private let lock = NSLock()
    private var blocks: [String: [AIMMarkdownBlockNode]] = [:]
    private var order: [String] = []
    private let limit = 600

    func cached(_ source: String) -> [AIMMarkdownBlockNode]? {
        lock.lock(); defer { lock.unlock() }
        return blocks[source]
    }

    /// Parses (or returns the cached parse of) a text.
    @discardableResult
    func parse(_ source: String) -> [AIMMarkdownBlockNode] {
        if let known = cached(source) { return known }
        let parsed = AIMMarkdownDocument(source: source).blocks
        lock.lock()
        if blocks[source] == nil {
            blocks[source] = parsed
            order.append(source)
            if order.count > limit { blocks[order.removeFirst()] = nil }
        }
        lock.unlock()
        return parsed
    }
}

struct NativeMarkdownView: View {
    let source: String
    var appearance = ConversationAppearance()
    var searchQuery = ""
    @State private var blocks: [AIMMarkdownBlockNode]

    init(source: String, appearance: ConversationAppearance = ConversationAppearance(), searchQuery: String = "") {
        self.source = source
        self.appearance = appearance
        self.searchQuery = searchQuery
        // Formatted from the first frame: from the cache, or parsed now when the text is short.
        _blocks = State(initialValue: MarkdownBlockCache.shared.cached(source)
            ?? (source.utf8.count <= 6_000 ? MarkdownBlockCache.shared.parse(source) : []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(AIMTypography.conversation(appearance))
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            // While an answer streams, the previous parse stays on screen until the new one is ready.
            if let known = MarkdownBlockCache.shared.cached(source) { blocks = known; return }
            let source = source
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlockCache.shared.parse(source) }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
    }

    @ViewBuilder private func blockView(_ block: AIMMarkdownBlockNode) -> some View {
        switch block {
        case let .heading(level, text):
            wrapping(inline(text))
                .font(AIMTypography.conversation(appearance, size: appearance.headingSize(level: level), weight: .semibold))
                .padding(.top, 8)
        case .paragraph(let text): wrapping(inline(text))
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 3)
                wrapping(inline(text)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items): flatList(items, ordered: false)
        case .orderedList(let items): flatList(items, ordered: true)
        case .list(let list): nestedList(list)
        case let .code(language, content):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(language ?? "Code").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11))
                }
                ScrollView(.horizontal) {
                    Text(SearchHighlight.apply(to: AttributedString(content), query: searchQuery)).font(AppearancePreferences.codeFont(defaultSize: appearance.codeSize))
                        .lineSpacing(3).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(15).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        case let .math(content, display):
            AIMMathFormulaView(latex: content, fontSize: CGFloat(appearance.mathSize), display: display)
        case let .table(headers, rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { _, text in inline(text).bold() } }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, text in inline(text) } }
                    }
                }.font(.system(size: CGFloat(appearance.tableSize))).padding(12)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        case .rule: Divider().padding(.vertical, 6)
        }
    }

    private func inline(_ source: String) -> Text {
        var attributed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for run in attributed.runs {
            if let link = run.link, !["https", "http", "mailto", "aim-source"].contains(link.scheme?.lowercased() ?? "") {
                attributed[run.range].link = nil
            } else if run.link?.scheme == SourceCitationLink.scheme {
                // A citation pill: small, gray on a light background, like the cited domain it names.
                attributed[run.range].font = .system(size: max(10, CGFloat(appearance.textSize) * 0.72), weight: .medium)
                attributed[run.range].foregroundColor = .secondary
                attributed[run.range].backgroundColor = Color.primary.opacity(0.07)
                attributed[run.range].underlineStyle = nil
            }
        }
        return Text(SearchHighlight.apply(to: attributed, query: searchQuery))
    }

    /// Text that always takes the height it needs at the offered width: in a list row SwiftUI
    /// otherwise cut items to one line ending in "…" until a click re-ran the layout.
    private func wrapping(_ text: Text) -> some View {
        text.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flatList(_ items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text(ordered ? "\(index + 1)." : "•").frame(minWidth: 16, alignment: .trailing)
                    wrapping(inline(item))
                }
            }
        }
    }

    private func nestedList(_ list: AIMMarkdownListNode) -> AnyView {
        let ordered: Bool
        switch list { case .ordered: ordered = true; case .unordered: ordered = false }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text(ordered ? "\(index + 1)." : "•").frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 8) {
                        wrapping(inline(item.text))
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in nestedList(child) }
                    }
                }
            }
        })
    }
}

enum SearchHighlight {
    static func apply(to value: AttributedString, query: String) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256 else { return value }
        var result = value
        let plain = String(value.characters)
        var start = plain.startIndex
        var remaining = 500
        while start < plain.endIndex, remaining > 0,
              let range = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<plain.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow.opacity(0.5)
                result[lower..<upper].foregroundColor = .black
            }
            start = range.upperBound; remaining -= 1
        }
        return result
    }
}
