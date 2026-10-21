import AIMApplication
import XCTest

final class TranscriptSearchTests: XCTestCase {
    private func message(_ text: String, role: MessageRole = .user) -> ConversationMessage {
        .init(conversationID: UUID(), role: role, content: text, sequence: 0)
    }

    func testLiteralCaseAndAccentInsensitiveSearchPreservesMessageOrder() {
        let first = message("Un café ☕ avec Swift. Swift encore.")
        let second = message("CAFE et Swift", role: .assistant)
        let result = TranscriptSearch.find("cafe", in: [first, second])
        XCTAssertEqual(result.matches.map(\.id), [first.id, second.id])
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(TranscriptSearch.find("swift", in: [first]).matches.count, 2)
        XCTAssertTrue(TranscriptSearch.find(".*", in: [first]).matches.isEmpty)
    }

    func testExcludesAttachmentsAndHiddenContext() {
        var attached = message("Visible")
        attached.attachments = [.init(name: "Needle", content: "Needle")]
        let result = TranscriptSearch.find("Needle", in: [attached, message("Needle", role: .system), message("Needle", role: .tool)])
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testResultLimitsAndLongMessageTruncationAreExplicit() {
        let messages = [message("found"), message("found"), message("found")]
        XCTAssertFalse(TranscriptSearch.find("found", in: messages, limit: 3).isTruncated)
        let result = TranscriptSearch.find("found", in: messages, limit: 2)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertTrue(result.isTruncated)
        let long = message(String(repeating: "x", count: 1_024 * 1_024 + 1) + "needle")
        let truncated = TranscriptSearch.find("needle", in: [long])
        XCTAssertTrue(truncated.matches.isEmpty)
        XCTAssertTrue(truncated.isTruncated)
    }

    func testExcerptIsBoundedAndEmptyOrExcessiveQueriesDoNotSearch() {
        let source = message(String(repeating: "🙂", count: 100) + "Needle" + String(repeating: "é", count: 100))
        let result = TranscriptSearch.find("needle", in: [source])
        XCTAssertEqual(result.matches.first?.excerpt.count, 148)
        XCTAssertTrue(result.matches.first?.excerpt.hasPrefix("…") == true)
        for query in ["", " \n ", String(repeating: "x", count: 257)] {
            XCTAssertTrue(TranscriptSearch.find(query, in: [source]).matches.isEmpty)
        }
    }
}
