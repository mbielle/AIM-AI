import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import XCTest

final class WorkspaceTransferScopeTests: XCTestCase {
    func testCopyAndMoveRequireEveryAffectedPathInsideMissionScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-transfer-scope-\(UUID())")
            .resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("allowed")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "allowed".write(to: allowed.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)

        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Scoped transfer", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let missions = SQLiteAgentMissionRepository(database: database)
        let mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Organize allowed files")
        let folder = try MissionResource(kind: .directory, identifier: allowed.path)
        _ = try await missions.replaceAuthorization(missionID: mission.id, expectedRevision: nil,
            rules: [try MissionAuthorizationRule(resource: folder, operations: [.observe, .edit])])
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "copy_file", risk: .localMutation,
                requiredArguments: ["source", "destination"], executor: WorkspaceCopyToolService()),
            RegisteredTool(name: "move_file", risk: .localMutation,
                requiredArguments: ["source", "destination"], executor: WorkspaceMoveToolService())
        ], broker: broker, policy: .autoApprove, workspacePath: root.path,
            missionRepository: missions, missionID: mission.id)

        let copy = await dispatcher.execute(id: "copy-inside", name: "copy_file",
            arguments: ["source": "allowed/source.txt", "destination": "allowed/copy.txt"])
        XCTAssertFalse(copy.isError, copy.content)
        let move = await dispatcher.execute(id: "move-inside", name: "move_file",
            arguments: ["source": "allowed/copy.txt", "destination": "allowed/moved.txt"])
        XCTAssertFalse(move.isError, move.content)
        let noApprovals = await broker.snapshot()
        XCTAssertTrue(noApprovals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: allowed.appendingPathComponent("moved.txt").path))

        let attempts: [(String, String, String, String)] = [
            ("copy-source-outside", "copy_file", "outside/source.txt", "allowed/foreign.txt"),
            ("copy-destination-outside", "copy_file", "allowed/source.txt", "outside/copied.txt"),
            ("move-source-outside", "move_file", "outside/source.txt", "allowed/foreign.txt"),
            ("move-destination-outside", "move_file", "allowed/moved.txt", "outside/moved.txt")
        ]
        for (id, name, source, destination) in attempts {
            let pending = Task { await dispatcher.execute(id: id, name: name,
                arguments: ["source": source, "destination": destination]) }
            let approval = try await nextApproval(broker)
            XCTAssertEqual(approval.arguments["source"], source)
            XCTAssertEqual(approval.arguments["destination"], destination)
            await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
            let denied = await pending.value
            XCTAssertTrue(denied.isError)
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("source.txt"), encoding: .utf8), "outside")
        XCTAssertEqual(try String(contentsOf: allowed.appendingPathComponent("moved.txt"), encoding: .utf8), "allowed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: allowed.appendingPathComponent("foreign.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("copied.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved.txt").path))
        await dispatcher.close()
    }

    private func nextApproval(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let approval = await broker.snapshot().first { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Approval did not appear", code: 1)
    }
}
