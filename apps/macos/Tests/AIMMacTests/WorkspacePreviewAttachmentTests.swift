@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class WorkspacePreviewAttachmentTests: XCTestCase {
    func testExplicitPreviewAttachmentStaysInDraftUntilSend() throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        model.mode = .code
        model.workspacePath = "/tmp/example-workspace"
        XCTAssertTrue(model.attachWorkspacePreview("let value = 42", named: "Sources/App.swift",
                                               from: "/tmp/example-workspace"))
        XCTAssertEqual(model.pendingAttachments.count, 1)
        XCTAssertEqual(model.pendingAttachments.first?.name, "Sources/App.swift")
        XCTAssertEqual(model.pendingAttachments.first?.content, "let value = 42")
        XCTAssertTrue(model.messages.isEmpty)

        XCTAssertFalse(model.attachWorkspacePreview("outside", named: "Other.swift", from: "/tmp/other"))
        XCTAssertEqual(model.pendingAttachments.count, 1)
        XCTAssertFalse(model.attachWorkspacePreview(String(repeating: "x", count: TextAttachment.maximumFileBytes + 1),
                                                    named: "Huge.swift", from: "/tmp/example-workspace"))
        XCTAssertEqual(model.pendingAttachments.count, 1)
        model.mode = .chat
        XCTAssertFalse(model.attachWorkspacePreview("chat", named: "Other.swift", from: "/tmp/example-workspace"))
        XCTAssertEqual(model.pendingAttachments.count, 1)
    }
}
