import Foundation

/// Credential-shaped strings are replaced in every tool result before the
/// model sees it (as Otto's output redactor does): API keys, tokens, private
/// keys, passwords in assignments and JWTs. The person's files are unchanged.
public enum SecretRedactor {
    static let marker = "[redacted secret]"
    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"\bsk-(?:ant-|proj-|or-)?[A-Za-z0-9_\-]{20,}"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        // Quoted literal assigned to a secret-named key (not code such as `apiKey = config.apiKey`).
        #"(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)\b(\s*[:=]\s*)(?:"(?!\[redacted)[^"\s]{8,}"|'(?!\[redacted)[^'\s]{8,}')"#,
        // .env-style line: SOME_API_KEY=value.
        #"(?m)^\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|SECRET|API_KEY|APIKEY|TOKEN|PRIVATE_KEY)[A-Z0-9_]*(\s*=\s*)(?!\[redacted)[^\s#]{8,}"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._\-]{20,}"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let assignmentPatterns: Set<Int> = [8, 9]

    /// The redacted text and how many secrets were replaced.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        guard text.count < 2_000_000 else { return (text, 0) }
        var output = text
        var count = 0
        for (index, pattern) in patterns.enumerated() {
            let range = NSRange(output.startIndex..., in: output)
            let matches = pattern.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            count += matches
            if assignmentPatterns.contains(index) {
                // Assignments keep their key name so the model still understands the line.
                output = replacingAssignments(output, pattern: pattern)
            } else {
                output = pattern.stringByReplacingMatches(in: output, range: range, withTemplate: marker)
            }
        }
        return (output, count)
    }

    private static func replacingAssignments(_ text: String, pattern: NSRegularExpression) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let separator = Range(match.range(at: 1), in: text) else { continue }
            result.replaceSubrange(whole, with: String(text[whole.lowerBound..<separator.upperBound]) + marker)
        }
        return result
    }
}

/// Person-defined lifecycle hooks around every tool call (like Claude Code's).
public protocol ToolHookRunning: Sendable {
    /// A reason to block the call before any approval or effect, or nil to continue.
    func beforeTool(name: String, arguments: [String: String], workspace: String?) async -> String?
    /// Extra text to append to the tool result (e.g. a linter's output), or nil.
    func afterTool(name: String, arguments: [String: String], result: ToolResult, workspace: String?) async -> String?
}
