import SwiftUI

enum GitDiffText {
    static func format(_ text: String) -> AttributedString {
        var output = AttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var span = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                span.foregroundColor = Color(nsColor: .systemGreen)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                span.foregroundColor = Color(nsColor: .systemRed)
            } else if line.hasPrefix("@@") {
                span.foregroundColor = Color(nsColor: .systemBlue)
            }
            output.append(span)
        }
        return output
    }
}
