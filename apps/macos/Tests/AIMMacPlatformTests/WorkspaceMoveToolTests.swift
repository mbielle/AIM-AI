import AIMAgentKit
import AIMMacPlatform
import XCTest

final class WorkspaceMoveToolTests: XCTestCase {
    func testMovesRegularFileBetweenExistingDirectoriesWithoutCopy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source")
        let targetFolder = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: false)
        let source = sourceFolder.appendingPathComponent("original.bin")
        let destination = targetFolder.appendingPathComponent("renamed.bin")
        let contents = Data(repeating: 0x41, count: 180_000)
        try contents.write(to: source)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber

        let result = await move(root, from: "source/original.bin", to: "target/renamed.bin")
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(after, before)
    }

    func testExistingDestinationAndInvalidPathsLeaveBothEntriesUnchanged() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "keep".write(to: destination, atomically: true, encoding: .utf8)
        for (from, to) in [
            ("source.txt", "destination.txt"), ("source.txt", "source.txt"),
            ("../source.txt", "new.txt"), ("source.txt", "../escape.txt"),
            ("source.txt", "/tmp/escape.txt"), ("source.txt", "missing/new.txt"),
            ("source.txt", "a//b"), ("source.txt", "a/./b")
        ] {
            let result = await move(root, from: from, to: to)
            XCTAssertTrue(result.isError, "\(from) → \(to)")
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    func testSymlinksAndDirectoriesCannotBeMovedOutsideWorkspace() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aim-move-symlink-\(UUID())")
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try "inside".write(to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-file"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-parent"), withDestinationURL: base)
        for (from, to) in [
            ("linked-file", "moved.txt"), ("linked-parent/outside.txt", "moved.txt"),
            ("inside.txt", "linked-parent/moved.txt"), ("folder", "moved-folder")
        ] {
            let result = await move(root, from: from, to: to)
            XCTAssertTrue(result.isError, "\(from) → \(to)")
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("inside.txt"), encoding: .utf8), "inside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("moved.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("moved.txt").path))
    }

    func testMoveRequiresExactApprovalAndPlanRejectsIt() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try "review me".write(to: source, atomically: true, encoding: .utf8)
        let broker = ToolApprovalBroker()
        let tool = RegisteredTool(name: "move_file", risk: .localMutation,
                                  requiredArguments: ["source", "destination"], executor: WorkspaceMoveToolService())
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: broker,
                                                     policy: .smart, workspacePath: root.path)
        let denied = Task { await dispatcher.execute(id: "move-denied", name: "move_file",
            arguments: ["source": "source.txt", "destination": "denied.txt"]) }
        let first = try await pendingApproval(broker)
        XCTAssertEqual(first.arguments["source"], "source.txt")
        XCTAssertEqual(first.arguments["destination"], "denied.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied.txt").path))
        await broker.decide(id: first.id, sessionID: dispatcher.sessionID, decision: .deny)
        let deniedResult = await denied.value
        XCTAssertTrue(deniedResult.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let approved = Task { await dispatcher.execute(id: "move-approved", name: "move_file",
            arguments: ["source": "source.txt", "destination": "approved.txt"]) }
        let second = try await pendingApproval(broker)
        await broker.decide(id: second.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let approvedResult = await approved.value
        XCTAssertFalse(approvedResult.isError, approvedResult.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("approved.txt"), encoding: .utf8), "review me")

        let plan = try ApprovedToolDispatcher(tools: [tool], broker: broker, policy: .plan, workspacePath: root.path)
        let blocked = await plan.execute(id: "move-plan", name: "move_file",
            arguments: ["source": "approved.txt", "destination": "not-moved.txt"])
        XCTAssertTrue(blocked.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("not-moved.txt").path))
        await dispatcher.close()
        await plan.close()
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-move-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func move(_ root: URL, from source: String, to destination: String) async -> ToolResult {
        await WorkspaceMoveToolService().execute(ToolRequest(name: "move_file",
            arguments: ["source": source, "destination": destination], risk: .localMutation, workspacePath: root.path))
    }

    private func pendingApproval(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let approval = await broker.snapshot().first { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ApprovalMissing()
    }

    private struct ApprovalMissing: Error {}
}
