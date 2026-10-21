import AIMAgentKit
import AIMMacPlatform
import XCTest

final class ApprovedWorkspaceTests: XCTestCase {
    func testRealCopyWaitsForApprovalAndPlanCannotCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-approved-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("approved.txt")
        try "approved content".write(to: source, atomically: true, encoding: .utf8)
        let broker = ToolApprovalBroker()
        let tools = WorkspaceToolRegistry.fileTools() + [RegisteredTool(name: "copy_file", risk: .localMutation,
            requiredArguments: ["source", "destination"], executor: WorkspaceCopyToolService())]
        let dispatcher = try ApprovedToolDispatcher(tools: tools, broker: broker, policy: .smart, workspacePath: root.path)
        let task = Task { await dispatcher.execute(id: "copy-1", name: "copy_file", arguments: ["source": "source.txt", "destination": "approved.txt"]) }
        var approval: PendingToolApproval?
        for _ in 0..<200 {
            approval = await broker.snapshot().first
            if approval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let prompt = try XCTUnwrap(approval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(prompt.arguments["source"], "source.txt")
        XCTAssertEqual(prompt.arguments["destination"], "approved.txt")
        await broker.decide(id: prompt.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let result = await task.value
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved content")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "approved content")
        let plan = try ApprovedToolDispatcher(tools: tools, broker: broker, policy: .plan, workspacePath: root.path)
        let denied = await plan.execute(id: "copy-2", name: "copy_file", arguments: ["source": "source.txt", "destination": "blocked.txt"])
        XCTAssertTrue(denied.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked.txt").path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved content")
        let read = await plan.execute(id: "read-1", name: "read_file", arguments: ["path": "approved.txt"])
        XCTAssertEqual(read.content, "approved content")
        let missingDestination = await dispatcher.execute(id: "copy-3", name: "copy_file", arguments: ["source": "source.txt"])
        XCTAssertTrue(missingDestination.isError)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved content")
        await dispatcher.close()
        await plan.close()
    }
}
