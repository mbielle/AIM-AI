import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

final class DurableWorkspaceEditTests: XCTestCase {
    func testProposalSurvivesRestartAndLostWriteResultIsReconciledByObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-durable-edit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.resolvingSymlinksInPath().path
        let first = WorkspaceEditToolService()
        let prepared = await first.execute(ToolRequest(name: "propose_file", arguments: ["path": "result.txt", "content": "exact expected result"], risk: .readOnly, workspacePath: workspace))
        XCTAssertFalse(prepared.isError, prepared.content)
        let proposal = try XCTUnwrap(prepared.metadata["proposal_id"])
        let beforeEffect = try await first.exportToolState()
        let second = WorkspaceEditToolService(); try await second.restoreToolState(beforeEffect, workspacePath: workspace)
        let applied = await second.execute(ToolRequest(name: "apply_edit", arguments: ["proposal_id": proposal], risk: .localMutation, workspacePath: workspace))
        XCTAssertFalse(applied.isError, applied.content)
        let third = WorkspaceEditToolService(); try await third.restoreToolState(beforeEffect, workspacePath: workspace)
        let observed = try await third.reconcile(ModelToolCall(id: "write", name: "apply_edit", arguments: ["proposal_id": proposal]), workspacePath: workspace)
        XCTAssertEqual(observed?.metadata["reconciled_by"], "host_file_observation")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "result.txt"), encoding: .utf8), "exact expected result")
        let review = try await third.review(ToolRequest(name: "undo_edit", arguments: ["proposal_id": proposal], risk: .localMutation, workspacePath: workspace))
        XCTAssertNotNil(review)
    }
    func testChangedTargetIsNeverReconciledAsSuccessful() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-durable-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.resolvingSymlinksInPath().path
        let first = WorkspaceEditToolService()
        let prepared = await first.execute(ToolRequest(name: "propose_file", arguments: ["path": "result.txt", "content": "wanted"], risk: .readOnly, workspacePath: workspace))
        let proposal = try XCTUnwrap(prepared.metadata["proposal_id"])
        let saved = try await first.exportToolState()
        try "external modification".write(to: directory.appending(path: "result.txt"), atomically: true, encoding: .utf8)
        let restored = WorkspaceEditToolService(); try await restored.restoreToolState(saved, workspacePath: workspace)
        let observed = try await restored.reconcile(ModelToolCall(id: "write", name: "apply_edit", arguments: ["proposal_id": proposal]), workspacePath: workspace)
        XCTAssertNil(observed)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "result.txt"), encoding: .utf8), "external modification")
    }
}
