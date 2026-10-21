import AIMAgentKit
import AIMApplication
import XCTest

private actor OversizedVisualTool: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["observe"]
    private(set) var executions = 0
    func execute(_ request: ToolRequest) -> ToolResult {
        executions += 1
        return ToolResult(requestID: request.id, content: String(repeating: "é", count: 90_000),
            isError: true, metadata: ["partial": "true", "action_outcome": ActionOutcome.unknown.rawValue],
            imagePNG: Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]))
    }
    func cancel(requestID: String) {}
}

final class ToolResultIntegrityTests: XCTestCase {
    func testActionOutcomePersistsSeparatelyFromErrorStatus() throws {
        var result = ToolResult(requestID: "gesture", content: "Input dispatched")
        result.actionOutcome = .unverified
        XCTAssertFalse(result.isError)
        let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.actionOutcome, .unverified)
        XCTAssertFalse(restored.isError)
        result.actionOutcome = .unknown
        result.isError = true
        XCTAssertEqual(result.actionOutcome, .unknown)
        result.actionOutcome = nil
        XCTAssertNil(result.metadata["action_outcome"])
    }

    func testTruncationPreservesPixelsErrorMetadataAndReadableFullText() async throws {
        let tool = OversizedVisualTool(), artifacts = ToolArtifactStore()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "observe", risk: .computerRead, executor: tool)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil, artifacts: artifacts)
        let output = await dispatcher.execute(id: "a", name: "observe", arguments: [:])
        XCTAssertTrue(output.isError)
        XCTAssertNotNil(output.imagePNG)
        XCTAssertEqual(output.metadata["partial"], "true")
        XCTAssertEqual(output.actionOutcome, .unknown)
        XCTAssertEqual(output.metadata["truncated"], "true")
        let reference = try XCTUnwrap(output.metadata["artifact_id"])
        var offset = "0", restored = ""
        repeat {
            let page = await artifacts.execute(ToolRequest(name: "read_tool_artifact",
                arguments: ["artifact_id": reference, "offset": offset, "limit": "65535"], risk: .readOnly))
            XCTAssertFalse(page.isError)
            restored += page.content
            offset = try XCTUnwrap(page.metadata["next_offset"])
        } while offset != "end"
        XCTAssertEqual(restored, String(repeating: "é", count: 90_000))
    }

    func testToolListsAndReadsPriorRunArtifactWithoutCrossWorkspaceAccess() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Artifact continuation", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let first = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                                 modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(first)
        let writer = ToolArtifactStore(runID: first.id, repository: repository,
                                       conversationID: chat.id, workspacePath: "/fixture")
        let id = try await writer.save("A long earlier tool result")
        try await repository.finish(runID: first.id, state: .unverified)
        let second = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                                  modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(second)
        let resumed = ToolArtifactStore(runID: second.id, repository: repository,
                                        conversationID: chat.id, workspacePath: "/fixture")
        let listed = await resumed.execute(ToolRequest(name: "list_tool_artifacts",
                                               arguments: [:], risk: .readOnly))
        XCTAssertFalse(listed.isError)
        let listing = try JSONDecoder().decode(ToolArtifactListing.self, from: Data(listed.content.utf8))
        XCTAssertEqual(listing.artifacts.map(\.id), [id])
        let read = await resumed.execute(ToolRequest(name: "read_tool_artifact",
            arguments: ["artifact_id": id], risk: .readOnly))
        XCTAssertEqual(read.content, "A long earlier tool result")
        let wrongWorkspace = ToolArtifactStore(runID: second.id, repository: repository,
                                               conversationID: chat.id, workspacePath: "/elsewhere")
        let denied = await wrongWorkspace.execute(ToolRequest(name: "read_tool_artifact",
            arguments: ["artifact_id": id], risk: .readOnly))
        XCTAssertTrue(denied.isError)
    }

    func testLaunchPersistenceFailurePreventsEffect() async throws {
        let tool = OversizedVisualTool()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "observe", risk: .readOnly, executor: tool)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let result = await dispatcher.execute(id: "a", name: "observe", arguments: [:], willExecute: {
            throw WorkspaceHistoryError.persistence
        })
        XCTAssertEqual(result.metadata["journal_failure"], "true")
        let count = await tool.executions
        XCTAssertEqual(count, 0)
    }

    func testArgumentLimitCountsJSONEscaping() {
        XCTAssertTrue(ToolPayloadLimits.validArguments(["text": String(repeating: "x", count: 1_000_000)]))
        XCTAssertFalse(ToolPayloadLimits.validArguments(["text": String(repeating: "\n", count: 1_100_000)]))
        XCTAssertFalse(ToolPayloadLimits.validArguments(["text": "\0"]))
    }
}
