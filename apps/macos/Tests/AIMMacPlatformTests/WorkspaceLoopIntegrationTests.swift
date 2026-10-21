import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import XCTest

private actor FileRoundTrip: ModelToolConversation {
    var output: ModelToolOutput?
    private var started = false
    func next(outputs: [ModelToolOutput]) -> ModelToolTurn {
        if !started {
            started = true
            return ModelToolTurn(text: "", calls: [ModelToolCall(id: "read", name: "read_file", arguments: ["path": "fixture.txt"])])
        }
        output = outputs.first
        return ModelToolTurn(text: "File inspected.", calls: [])
    }
}

final class WorkspaceLoopIntegrationTests: XCTestCase {
    func testRealFileIsReadOnlyAfterApprovalAndReturnedThroughLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt")
        try Data("fixture content — not a user document".utf8).write(to: fixture)
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: WorkspaceToolRegistry.fileTools().filter { $0.risk == .readOnly },
            broker: broker, policy: .alwaysAsk, workspacePath: root.path)
        let conversation = FileRoundTrip()
        let task = Task { try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in }) }
        var pending: PendingToolApproval?
        for _ in 0..<200 {
            pending = await broker.snapshot().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pending else { task.cancel(); _ = try? await task.value; XCTFail("No approval"); return }
        let before = await conversation.output
        XCTAssertNil(before)
        await broker.decide(id: pending.id, sessionID: pending.sessionID, decision: .allowOnce)
        try await task.value
        let result = await conversation.output
        XCTAssertEqual(result?.content, "fixture content — not a user document")
        XCTAssertEqual(result?.isError, false)
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "fixture content — not a user document")
        let noWrite = await dispatcher.execute(id: "write", name: "write_file", arguments: ["path": "fixture.txt", "content": "changed"])
        XCTAssertTrue(noWrite.isError)
    }
}
