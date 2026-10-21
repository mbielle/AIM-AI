import Foundation
import XCTest
@testable import AIMCore

final class ProjectSourceCitationPresentationTests: XCTestCase {
    private let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var marker: String { "source:" + sourceID.uuidString.lowercased() + "#1" }
    private func result(name: String = "Test.txt", chunk: String = "0", citation: String? = nil) throws -> String {
        let value: [String: Any] = ["excerpts": [["sourceID": sourceID.uuidString.lowercased(), "chunkID": chunk, "name": name, "citation": citation ?? marker, "text": "Synthetic reference only"]], "moreAvailable": false, "untrustedSourceData": true]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func projection(name: String = "Test.txt") throws -> ProjectSourceCitationPresentation {
        let message = NativeChatMessage(role: .assistant, text: "", skillActivities: [.init(id: "read", name: ProjectSourceTools.readName, skill: sourceID.uuidString, isError: false, running: false, detail: try result(name: name))])
        return ProjectSourceCitationPresentation(message: message)
    }
    func testBuild46SavedActionEnvelopeDisplaysFileNameWithoutChangingHistory() throws {
        let id = UUID(), text = "D’après [\(marker)] (Test.txt, chunk 0), la vérification est réussie."
        let action = ConversationAction(id: "read", conversationID: UUID(), turnID: id, ordinal: 0, name: ProjectSourceTools.readName, state: .completed, detail: sourceID.uuidString + " · 0\n\n" + (try result()))
        let message = NativeChatMessage(id: id, role: .assistant, text: text, actions: [action])
        let encoded = try JSONEncoder().encode(message)
        let reopened = try JSONDecoder().decode(NativeChatMessage.self, from: encoded)
        let presentation = ProjectSourceCitationPresentation(message: reopened)
        XCTAssertEqual(presentation.displayed(reopened.text, markdown: false), "D’après [Test.txt], la vérification est réussie.")
        XCTAssertEqual(reopened.text, text)
        XCTAssertEqual(reopened, message)
    }
    func testKnownBareBracketedAndStandaloneCodeCitationsUseReadableNames() throws {
        let value = try projection()
        XCTAssertEqual(value.displayed(marker, markdown: false), "Test.txt")
        XCTAssertEqual(value.displayed("[\(marker)]", markdown: false), "[Test.txt]")
        XCTAssertEqual(value.displayed("`\(marker)` (Test.txt, chunk 0)", markdown: false), "Test.txt")
        XCTAssertEqual(value.displayed("`\(marker) (Test.txt, chunk 0)`", markdown: false), "Test.txt")
        XCTAssertEqual(value.displayed(marker.uppercased(), markdown: false), "Test.txt")
    }
    func testUnknownOrMalformedEvidenceNeverClaimsAFileName() throws {
        let value = try projection()
        XCTAssertEqual(value.displayed(marker.replacingOccurrences(of: "#1", with: "#2")), marker.replacingOccurrences(of: "#1", with: "#2"))
        let wrong = NativeChatMessage(role: .assistant, text: marker, skillActivities: [.init(id: "read", name: ProjectSourceTools.readName, skill: "", detail: try result(citation: "source:" + UUID().uuidString + "#1"))])
        XCTAssertEqual(ProjectSourceCitationPresentation(message: wrong).displayed(marker), marker)
        let truncated = NativeChatMessage(role: .assistant, text: marker, skillActivities: [.init(id: "read", name: ProjectSourceTools.readName, skill: "", detail: "{\"excerpts\":[")])
        XCTAssertEqual(ProjectSourceCitationPresentation(message: truncated).displayed(marker), marker)
        let unrelated = NativeChatMessage(role: .assistant, text: marker, skillActivities: [.init(id: "read", name: "unrelated_tool", skill: "", detail: try result())])
        XCTAssertEqual(ProjectSourceCitationPresentation(message: unrelated).displayed(marker), marker)
    }
    func testUserMessagesCodeBlocksRealInlineCodeAndLinksRemainUntouched() throws {
        let value = try projection()
        let code = "```swift\nlet reference = \"\(marker)\"\n```\n\n`let reference = \"\(marker)\"`\n\n[link](https://example.invalid/\(marker))\n\nhttps://example.invalid/\(marker)"
        XCTAssertEqual(value.displayed(code), code)
        let user = NativeChatMessage(role: .user, text: marker, skillActivities: [.init(id: "read", name: ProjectSourceTools.readName, skill: "", detail: try result())])
        XCTAssertEqual(ProjectSourceCitationPresentation(message: user).displayed(marker), marker)
    }
    func testUnicodeOffsetsProtectCodeAndHumanizeOnlyKnownProseReferences() throws {
        let value = try projection(name: "東京_検証[1].txt")
        let original = "説明 😀 é `let id = \"\(marker)\"`\n\n参照 [\(marker)]"
        let displayed = value.displayed(original, markdown: false)
        XCTAssertEqual(displayed, "説明 😀 é `let id = \"\(marker)\"`\n\n参照 [東京_検証[1].txt]")
        let markdown = value.displayed(marker)
        XCTAssertTrue(markdown.contains("\\_")); XCTAssertTrue(markdown.contains("\\["))
    }
    func testOnlyAttributedFallbackAttachmentProvidesCitationEvidence() {
        let message = NativeChatMessage(role: .assistant, text: "[\(marker)]")
        var attachment = NativeChatAttachment(id: sourceID, name: "Test.txt", kind: .document, mimeType: "text/plain", text: "[\(marker)]\nSynthetic reference")
        XCTAssertEqual(ProjectSourceCitationPresentation(message: message, attachments: [attachment]).displayed(message.text), message.text)
        attachment.projectSourceID = sourceID
        XCTAssertEqual(ProjectSourceCitationPresentation(message: message, attachments: [attachment]).displayed(message.text, markdown: false), "[Test.txt]")
    }
    func testTimelineSlicesCanBePresentedWithoutRewritingOffsetsOrContent() throws {
        let text = "First answer. Then [\(marker)]."
        var builder = TurnTimelineBuilder(); builder.text("First answer. "); builder.action("read"); builder.text("Then [\(marker)]."); builder.finish()
        let original = builder.timeline, value = try projection()
        let layout = TurnLayout<ConversationAction>.make(content: text, timeline: original, tools: [], key: \.id)
        let shown = layout.all.compactMap { item -> String? in
            if case let .text(_, content) = item { return value.displayed(content, markdown: false) }; return nil
        }.joined()
        XCTAssertEqual(shown, "First answer. Then [Test.txt].")
        XCTAssertEqual(builder.timeline, original); XCTAssertEqual(text, "First answer. Then [\(marker)].")
    }
}
