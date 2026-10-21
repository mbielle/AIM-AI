@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

@MainActor
final class ToolProgressModelTests: XCTestCase {
    func testEngineToolEventsDrivePreviewWithoutExposingArguments() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: HoldingToolRunner())
        model.selectMode(.code)
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        model.workspacePath = FileManager.default.temporaryDirectory.path
        model.workspaceToolsEnabled = true
        model.composerText = "Read the project"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        XCTAssertTrue(model.isSending)

        await model.handle(.toolStarted(conversationID: id, callID: "call-1", name: "read_file"))
        XCTAssertEqual(model.toolProgress.items.map(\.name), ["read_file"])
        XCTAssertEqual(model.toolProgress.items.first?.state, .running)
        await model.handle(.toolFinished(conversationID: id, callID: "call-1", isError: false))
        XCTAssertEqual(model.toolProgress.items.first?.state, .succeeded)
        XCTAssertEqual(model.completedToolCount, 1)

        await model.handle(.toolStarted(conversationID: id, callID: "call-2", name: "run_command"))
        await model.cancelCurrentTurn()
        XCTAssertEqual(model.toolProgress.items.last?.state, .interrupted)
        XCTAssertFalse(model.isSending)
        _ = await model.prepareForTermination()
    }
}

private struct HoldingToolRunner: NativeAgentTurnRunning {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { _ in }
    }
    func cancel(conversationID: UUID) async {}
}
