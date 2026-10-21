import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import XCTest

final class WorkspaceDirectoryToolTests: XCTestCase {
    func testMissionIntentUsesCanonicalDirectoryTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-directory-intent-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceDirectoryToolService()
        let intent = try await service.missionIntent(for: ToolRequest(name: "create_dir",
            arguments: ["path": "NewFolder"], risk: .localMutation, workspacePath: root.path))
        XCTAssertEqual(intent?.operation, .edit)
        XCTAssertEqual(intent?.target.identifier, root.appendingPathComponent("NewFolder").path)
        do {
            _ = try await service.missionIntent(for: ToolRequest(name: "create_dir",
                arguments: ["path": "../escape"], risk: .localMutation, workspacePath: root.path))
            XCTFail("Traversal must not create a mission-scoped target")
        } catch {}
    }

    func testCreationRequiresApprovalAndNeverCreatesParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-directory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ToolApprovalBroker()
        let tool = RegisteredTool(name: "create_dir", risk: .localMutation, requiredArguments: ["path"], executor: WorkspaceDirectoryToolService())
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: broker, policy: .alwaysAsk, workspacePath: root.path)
        let task = Task { await dispatcher.execute(id: "create-1", name: "create_dir", arguments: ["path": "Sources/NewFolder"]) }
        var pending: PendingToolApproval?
        for _ in 0..<200 {
            pending = await broker.snapshot().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let approval = try XCTUnwrap(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path))
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let missingParent = await task.value
        XCTAssertTrue(missingParent.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path))

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: false)
        let approved = Task { await dispatcher.execute(id: "create-2", name: "create_dir", arguments: ["path": "Sources/NewFolder"]) }
        var second: PendingToolApproval?
        for _ in 0..<200 {
            second = await broker.snapshot().first
            if second != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondApproval = try XCTUnwrap(second)
        XCTAssertEqual(secondApproval.arguments["path"], "Sources/NewFolder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/NewFolder").path))
        await broker.decide(id: secondApproval.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let created = await approved.value
        XCTAssertFalse(created.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/NewFolder").path))
        await dispatcher.close()
    }

    func testTraversalSymlinkAndExistingEntryFailClosed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aim-directory-safety-\(UUID())")
        let root = base.appendingPathComponent("workspace")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut"), withDestinationURL: outside)
        try "keep".write(to: root.appendingPathComponent("existing"), atomically: true, encoding: .utf8)
        let service = WorkspaceDirectoryToolService()
        for path in ["../escape", "/absolute", "a/../escape", "a//escape", "shortcut/new", "missing/new", "existing"] {
            let result = await service.execute(ToolRequest(name: "create_dir", arguments: ["path": path], risk: .localMutation, workspacePath: root.path))
            XCTAssertTrue(result.isError, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("existing"), encoding: .utf8), "keep")
    }

    func testPlanModeForbidsDirectoryCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-directory-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = RegisteredTool(name: "create_dir", risk: .localMutation, requiredArguments: ["path"], executor: WorkspaceDirectoryToolService())
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: ToolApprovalBroker(), policy: .plan, workspacePath: root.path)
        let result = await dispatcher.execute(id: "plan-create", name: "create_dir", arguments: ["path": "cannot-create"])
        XCTAssertTrue(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cannot-create").path))
        await dispatcher.close()
    }

    func testDeniedApprovalNeverCreatesDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-directory-denied-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ToolApprovalBroker()
        let tool = RegisteredTool(name: "create_dir", risk: .localMutation, requiredArguments: ["path"], executor: WorkspaceDirectoryToolService())
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: broker, policy: .alwaysAsk, workspacePath: root.path)
        let task = Task { await dispatcher.execute(id: "denied", name: "create_dir", arguments: ["path": "private"] ) }
        var pending: PendingToolApproval?
        for _ in 0..<200 {
            pending = await broker.snapshot().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let approval = try XCTUnwrap(pending)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let result = await task.value
        XCTAssertTrue(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("private").path))
        await dispatcher.close()
    }
}
