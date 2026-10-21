@testable import AIMAgentRuntime
import AIMApplication
import XCTest
@testable import AIMMac

@MainActor final class WorkbenchLifecycleTests: XCTestCase {
    func testPersistenceRetainsDraftUntilTabRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchSessionStore(url: directory.appendingPathComponent("side-chats.json"))
        let tab = WorkbenchTab(kind: .sideChat)
        tab.sideChat.draft = "not sent"
        try store.save([SavedWorkbenchTab(tab), SavedWorkbenchTab(WorkbenchTab(kind: .newTab))])
        let restored = try XCTUnwrap(store.load().first).restore()
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.sideChat.draft, "not sent")
        XCTAssertEqual(try store.load().count, 1)
        restored.sideChat.close()
        try store.save([])
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testTabKeepsSideChatUntilExplicitClose() {
        let tab = WorkbenchTab(kind: .sideChat)
        tab.sideChat.draft = "unfinished"
        tab.sideChat.messages = [.init(conversationID: tab.sideChat.id, role: .user, content: "question", sequence: 0)]
        let tabs = [tab, WorkbenchTab(kind: .newTab)]
        XCTAssertEqual(tabs[0].sideChat.draft, "unfinished")
        XCTAssertEqual(tabs[0].sideChat.messages.count, 1)
        tab.sideChat.close()
        XCTAssertTrue(tab.sideChat.draft.isEmpty)
        XCTAssertTrue(tab.sideChat.messages.isEmpty)
    }
}
