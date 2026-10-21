import AIMApplication
import XCTest

final class WorkspaceChangeManifestTests: XCTestCase {
    private func call(_ run: WorkspaceRun, _ ordinal: Int, _ name: String, _ arguments: [String: String],
                      result: String = "ok", metadata: [String: String] = [:], state: WorkspaceCallState = .succeeded) throws -> WorkspaceCall {
        var call = try WorkspaceCall(runID: run.id, ordinal: ordinal,
            call: ModelToolCall(id: "\(run.id)-\(ordinal)", name: name, jsonArguments: arguments.mapValues { .string($0) }))
        call.state = state
        call.result = result
        call.resultMetadataJSON = try JSONEncoder().encode(metadata)
        return call
    }

    func testOnlyAppliedChangesAreListedInOrder() throws {
        let id = UUID()
        let first = WorkspaceRun(conversationID: id, provider: .openRouter, modelID: "m", workspacePath: "/w")
        let calls1 = [
            try call(first, 0, "propose_edit", ["path": "src/a.swift"], metadata: ["proposal_id": "p1"]),
            try call(first, 1, "apply_edit", ["proposal_id": "p1"]),
            try call(first, 2, "propose_file", ["path": "never.txt"], metadata: ["proposal_id": "p2"]),
            try call(first, 3, "apply_edit", ["proposal_id": "p2"], state: .failed),
            try call(first, 4, "move_file", ["source": "x", "destination": "docs/x.md"])
        ]
        let second = WorkspaceRun(conversationID: id, provider: .openRouter, modelID: "m", workspacePath: "/w")
        let calls2 = [
            try call(second, 0, "propose_patch", ["patch": "…"], result: "Prepared patch P (update src/b.swift, add src/c.swift). No file was changed.",
                     metadata: ["proposal_id": "p3"]),
            try call(second, 1, "apply_edit", ["proposal_id": "p3"]),
            try call(second, 2, "propose_edit", ["path": "src/a.swift"], metadata: ["proposal_id": "p4"]),
            try call(second, 3, "apply_edit", ["proposal_id": "p4"])
        ]
        let runs = [WorkspaceRunHistory(run: second, calls: calls2), WorkspaceRunHistory(run: first, calls: calls1)]
        XCTAssertEqual(WorkspaceChangeManifest.changedPaths(runs), ["docs/x.md", "src/b.swift", "src/c.swift", "src/a.swift"])
        XCTAssertNil(WorkspaceChangeManifest.message([], conversationID: id))
        XCTAssertTrue(WorkspaceChangeManifest.message(runs, conversationID: id)?.content.contains("read a file again") == true)
    }
}
