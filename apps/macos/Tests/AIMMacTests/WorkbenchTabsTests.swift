@testable import AIMMac
import AIMCore
import XCTest

@MainActor
final class WorkbenchTabsTests: XCTestCase {
    func testTabsBelongToTheirConversationAndTerminalsToTheirFolder() {
        let conversation = UUID()
        XCTAssertEqual(WorkbenchTab(kind: .sources, conversationID: conversation).conversationID, conversation)
        XCTAssertNil(WorkbenchTab(kind: .terminal, workspacePath: "/tmp", conversationID: conversation).conversationID)
    }

    func testSourcesAreSavedWithTheirAnswerAndActionDetailsAreNot() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let conversation = UUID(), message = UUID()
        let sources = WorkbenchTab(kind: .sources, conversationID: conversation)
        sources.messageID = message; sources.focusID = "https://example.com"
        let actions = WorkbenchTab(kind: .actions, conversationID: conversation)
        actions.actions = [ConversationAction(id: "a", conversationID: conversation, turnID: message, ordinal: 0, name: "run_command", state: .completed, output: "secret output")]
        let store = WorkbenchSessionStore(url: url)
        try store.save([SavedWorkbenchTab(sources), SavedWorkbenchTab(actions)])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("secret output"))
        let restored = try store.load().map { $0.restore() }
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].kind, .sources)
        XCTAssertEqual(restored[0].conversationID, conversation)
        XCTAssertEqual(restored[0].messageID, message)
        XCTAssertEqual(restored[0].focusID, "https://example.com")
    }

    func testSideChatsSavedBeforeConversationTabsStillLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        try Data(#"[{"id":"9F1A1C1E-0B6B-4C55-8C17-2E7C3E9A1B11","kind":"sideChat","draft":"hello","messages":[]}]"#.utf8).write(to: url)
        let restored = try WorkbenchSessionStore(url: url).load().map { $0.restore() }
        XCTAssertEqual(restored.first?.sideChat.draft, "hello")
        XCTAssertNil(restored.first?.conversationID, "older side chats stay visible in every conversation")
    }
}
