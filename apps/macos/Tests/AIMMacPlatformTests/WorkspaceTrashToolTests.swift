import AIMAgentKit
@testable import AIMMacPlatform
import Darwin
import XCTest

final class WorkspaceTrashToolTests: XCTestCase {
    func testApprovedFileMovesToRecoverableLocation() async throws {
        let (base, root, recovery) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let source = nested.appendingPathComponent("notes.txt")
        try "important".write(to: source, atomically: true, encoding: .utf8)

        let result = await service(recovery: recovery).execute(request(root, "nested/notes.txt"))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("notes.txt"), encoding: .utf8), "important")
    }

    func testTraversalSymlinksDirectoriesAndHardlinksAreRejected() async throws {
        let (base, root, recovery) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let inside = root.appendingPathComponent("inside.txt")
        try "inside".write(to: inside, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-file"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-parent"), withDestinationURL: base)
        XCTAssertEqual(link(outside.path, root.appendingPathComponent("hardlink").path), 0)

        for path in ["../outside.txt", "/tmp/outside.txt", "folder", "linked-file",
                     "linked-parent/outside.txt", "hardlink", "inside.txt/../outside.txt",
                     "inside.txt//extra", "./inside.txt", "missing.txt"] {
            let result = await service(recovery: recovery).execute(request(root, path))
            XCTAssertTrue(result.isError, "Unexpectedly accepted \(path)")
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "inside")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
    }

    func testDestructiveActionAlwaysAsksEvenWithAutoApproveAndPlanRejects() async throws {
        let (base, root, recovery) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = root.appendingPathComponent("notes.txt")
        try "keep".write(to: source, atomically: true, encoding: .utf8)
        let broker = ToolApprovalBroker()
        let tool = RegisteredTool(name: "trash_file", risk: .destructive,
                                  requiredArguments: ["path"], executor: service(recovery: recovery))
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: broker,
                                                     policy: .autoApprove, workspacePath: root.path)
        let denied = Task { await dispatcher.execute(id: "trash-denied", name: "trash_file", arguments: ["path": "notes.txt"]) }
        let first = try await pendingApproval(broker)
        XCTAssertEqual(first.arguments["path"], "notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await broker.decide(id: first.id, sessionID: dispatcher.sessionID, decision: .deny)
        let deniedResult = await denied.value
        XCTAssertTrue(deniedResult.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let approved = Task { await dispatcher.execute(id: "trash-approved", name: "trash_file", arguments: ["path": "notes.txt"]) }
        let second = try await pendingApproval(broker)
        await broker.decide(id: second.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let result = await approved.value
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let plan = try ApprovedToolDispatcher(tools: [tool], broker: broker, policy: .plan, workspacePath: root.path)
        let blocked = await plan.execute(id: "trash-plan", name: "trash_file", arguments: ["path": "notes.txt"])
        XCTAssertTrue(blocked.isError)
        await dispatcher.close()
        await plan.close()
    }

    func testAlreadyCancelledRequestLeavesFileUntouched() async throws {
        let (base, root, recovery) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = root.appendingPathComponent("notes.txt")
        try "keep".write(to: source, atomically: true, encoding: .utf8)
        let tool = service(recovery: recovery)
        let toolRequest = request(root, "notes.txt")
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await tool.execute(toolRequest)
        }.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).isEmpty)
    }

    private func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aim-trash-\(UUID())")
        let root = base.appendingPathComponent("workspace")
        let recovery = base.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        return (base, root, recovery)
    }

    private func service(recovery: URL) -> WorkspaceTrashToolService {
        WorkspaceTrashToolService(trash: { url in
            try FileManager.default.moveItem(at: url, to: recovery.appendingPathComponent(url.lastPathComponent))
        })
    }

    private func request(_ root: URL, _ path: String) -> ToolRequest {
        ToolRequest(name: "trash_file", arguments: ["path": path], risk: .destructive, workspacePath: root.path)
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
