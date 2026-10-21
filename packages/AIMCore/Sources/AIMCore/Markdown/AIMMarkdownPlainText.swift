import Markdown

/// Display-only preview text. Read the AST directly instead of formatting and
/// reparsing its nodes: a second parse would mistake escaped literal markers
/// for emphasis. Link labels and code remain visible; destinations and HTML do not.
public enum AIMMarkdownPlainText {
    public static func string(_ source: String) -> String {
        text(Document(parsing: AIMMarkdownNormalizer.normalize(source)))
    }

    private static func text(_ node: any Markup) -> String {
        if let node = node as? Markdown.Text { return node.string }
        if let node = node as? InlineCode { return node.code }
        if let node = node as? CodeBlock { return node.code }
        if node is SoftBreak || node is LineBreak { return " " }
        if node is InlineHTML || node is HTMLBlock || node is ThematicBreak { return "" }
        // Inline containers concatenate runs; block containers separate paragraphs,
        // list items and table cells so preview words never run together.
        let separator = node is any InlineContainer ? "" : " "
        return node.children.map(text).joined(separator: separator)
    }
}
