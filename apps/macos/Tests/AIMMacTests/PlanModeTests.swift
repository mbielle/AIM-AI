@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

@MainActor
final class PlanModeTests: XCTestCase {
    func testPlanSelectionNeverOffersMutationToolsEvenWithStalePermissions() {
        let tools = WorkspaceToolSelection.definitions(planOnly: true, allowCommands: true, allowEdits: true)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.allSatisfy { $0.risk == .readOnly })
        for name in ["run_command", "apply_edit", "undo_edit", "propose_file", "propose_edit", "create_dir", "copy_file", "move_file", "trash_file"] {
            XCTAssertFalse(tools.contains { $0.name == name }, name)
        }
        XCTAssertTrue(Set(tools.map(\.name)).contains("read_file"))
        XCTAssertTrue(Set(tools.map(\.name)).contains("git_status"))

        let normal = WorkspaceToolSelection.definitions(planOnly: false, allowCommands: true, allowEdits: true)
        XCTAssertTrue(Set(normal.map(\.name)).isSuperset(of: ["run_command", "apply_edit", "undo_edit", "create_dir", "copy_file", "move_file", "trash_file"]))
    }

    func testCodeComposerSnapshotsPlanWithoutWritePermissions() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Plan request captured")
        let recorder = PlanRequestRecorder()
        let model = AppModel(database: database, turnRunner: PlanRequestRunner { request in
            recorder.set(request); captured.fulfill()
        })
        model.selectMode(.code)
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        model.workspacePath = FileManager.default.temporaryDirectory.path
        model.workspaceToolsEnabled = true
        model.workspacePlanOnly = true
        // Simulate stale state outside the disabled UI controls. The request
        // still must not expose execution or mutation capabilities.
        model.workspaceEditsEnabled = true
        model.workspaceCommandsEnabled = true
        model.composerText = "Plan the refactor"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.get())
        XCTAssertEqual(request.mode, .code)
        XCTAssertEqual(request.workspaceToolsEnabled, true)
        XCTAssertEqual(request.workspacePlanOnly, true)
        XCTAssertEqual(request.workspaceEditsEnabled, false)
        XCTAssertEqual(request.workspaceCommandsEnabled, false)
        _ = await model.prepareForTermination()
    }

    func testOldAgentRequestWithoutPlanFieldRemainsDecodable() throws {
        let request = AgentRequest(conversationID: UUID(), text: "Test", modelID: "fixture", mode: .code)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "workspacePlanOnly")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(AgentRequest.self, from: oldData).workspacePlanOnly)
    }
}

private struct PlanRequestRunner: NativeAgentTurnRunning {
    let capture: @Sendable (AgentRequest) -> Void
    func cancel(conversationID: UUID) async {}
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        capture(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class PlanRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: AgentRequest?
    func set(_ request: AgentRequest) { lock.withLock { self.request = request } }
    func get() -> AgentRequest? { lock.withLock { request } }
}
