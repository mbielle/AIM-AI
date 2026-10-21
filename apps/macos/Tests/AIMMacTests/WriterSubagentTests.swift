@testable import AIMAgentRuntime
import AIMAgentKit
import AIMApplication
@testable import AIMMac
import AIMMacPlatform
import Foundation
import XCTest

final class WriterSubagentTests: XCTestCase {
    private var scratch: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aim-writer-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        repository = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Fixture"],
                          ["config", "user.email", "fixture@example.invalid"]] { try git(arguments) }
        try "keep\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "old\n".write(to: repository.appendingPathComponent("obsolete.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
    }

    override func tearDownWithError() throws {
        try? git(["worktree", "prune"])
        try? FileManager.default.removeItem(at: scratch)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus)) }
    }

    private func pool(database: AIMDatabase, conversationID: UUID, deleteObsolete: Bool = false) -> AgentSubagentPool {
        let writer = SubagentWriterSupport(
            service: SubagentWorkspaceService(root: scratch.appendingPathComponent("Worktrees", isDirectory: true)),
            repository: SQLiteSubagentWorkspaceRepository(database: database), allowCommands: false)
        return AgentSubagentPool(assignmentRunner: { assignment in
            guard assignment.writer, let workspace = assignment.workspace else { return "read-only" }
            let root = URL(fileURLWithPath: workspace)
            try "child work\n".write(to: root.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
            if deleteObsolete { try FileManager.default.removeItem(at: root.appendingPathComponent("obsolete.txt")) }
            return SubagentReport(summary: "Added feature.txt", changes: ["feature.txt"], evidence: ["read back"],
                                  notChecked: [], confidence: .high).json
        }, jobRepository: SQLiteSubagentJobRepository(database: database), conversationID: conversationID,
           workspacePath: repository.path, writer: writer)
    }

    private func conversation(_ database: AIMDatabase) async throws -> UUID {
        let chat = Conversation(title: "Writer", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        return chat.id
    }

    func testWriterWorksInWorktreeAndMergesOnlyAfterReview() async throws {
        let database = try AIMDatabase(inMemory: true)
        let chatID = try await conversation(database)
        let pool = pool(database: database, conversationID: chatID)
        let delegated = await pool.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "Feature", "prompt": "add feature.txt", "mode": "write"], risk: .delegation))
        XCTAssertFalse(delegated.isError, delegated.content)
        let jobID = try XCTUnwrap(delegated.metadata["job_id"])
        let collected = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        XCTAssertTrue(collected.content.contains("Added feature.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("feature.txt").path),
                       "the workspace is unchanged before the merge")

        let early = await pool.execute(ToolRequest(name: "merge_subagent_changes", arguments: ["job_id": jobID], risk: .localMutation))
        XCTAssertTrue(early.isError)
        XCTAssertEqual(pool.risk(for: "merge_subagent_changes", arguments: ["job_id": jobID]), .destructive,
                       "unknown changes are treated conservatively")

        let review = await pool.execute(ToolRequest(name: "review_subagent_changes", arguments: ["job_id": jobID], risk: .readOnly))
        XCTAssertFalse(review.isError, review.content)
        XCTAssertTrue(review.content.contains("A feature.txt"))
        XCTAssertEqual(pool.risk(for: "merge_subagent_changes", arguments: ["job_id": jobID]), .localMutation)
        let preview = try await pool.review(ToolRequest(name: "merge_subagent_changes", arguments: ["job_id": jobID], risk: .localMutation))
        XCTAssertTrue(preview?.after.contains("+child work") == true)

        let merged = await pool.execute(ToolRequest(name: "merge_subagent_changes", arguments: ["job_id": jobID], risk: .localMutation))
        XCTAssertFalse(merged.isError, merged.content)
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("feature.txt"), encoding: .utf8), "child work\n")
        let record = try await SQLiteSubagentWorkspaceRepository(database: database).load(jobID: try XCTUnwrap(UUID(uuidString: jobID)))
        XCTAssertEqual(record?.state, .merged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record?.worktreePath ?? "/"))
        let again = await pool.execute(ToolRequest(name: "merge_subagent_changes", arguments: ["job_id": jobID], risk: .localMutation))
        XCTAssertTrue(again.isError)
        await pool.close()
    }

    func testDeletionsNeedTheStrongerApprovalAndDiscardLeavesWorkspaceAlone() async throws {
        let database = try AIMDatabase(inMemory: true)
        let chatID = try await conversation(database)
        let pool = pool(database: database, conversationID: chatID, deleteObsolete: true)
        let delegated = await pool.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "Cleanup", "prompt": "remove obsolete", "mode": "write"], risk: .delegation))
        let jobID = try XCTUnwrap(delegated.metadata["job_id"])
        _ = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        _ = await pool.execute(ToolRequest(name: "review_subagent_changes", arguments: ["job_id": jobID], risk: .readOnly))
        XCTAssertEqual(pool.risk(for: "merge_subagent_changes", arguments: ["job_id": jobID]), .destructive)
        let discarded = await pool.execute(ToolRequest(name: "discard_subagent_changes", arguments: ["job_id": jobID], risk: .localMutation))
        XCTAssertFalse(discarded.isError, discarded.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("obsolete.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent("feature.txt").path))
        let retry = await pool.execute(ToolRequest(name: "retry_subagent", arguments: ["job_id": jobID], risk: .delegation))
        XCTAssertTrue(retry.isError)
        await pool.close()
    }

    func testWriterModeNeedsWriterSupportAndARepository() async throws {
        let readOnly = AgentSubagentPool(runner: { _ in "x" }, workspacePath: repository.path)
        let refused = await readOnly.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "W", "prompt": "write", "mode": "write"], risk: .delegation))
        XCTAssertTrue(refused.isError)

        let database = try AIMDatabase(inMemory: true)
        let chatID = try await conversation(database)
        let plain = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let writer = SubagentWriterSupport(service: SubagentWorkspaceService(root: scratch.appendingPathComponent("Worktrees")),
                                           repository: SQLiteSubagentWorkspaceRepository(database: database), allowCommands: false)
        let pool = AgentSubagentPool(assignmentRunner: { _ in "x" }, conversationID: chatID,
                                     workspacePath: plain.path, writer: writer)
        let notRepository = await pool.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "W", "prompt": "write", "mode": "write"], risk: .delegation))
        XCTAssertTrue(notRepository.isError)
        XCTAssertTrue(notRepository.content.contains("Git repository"))
    }
}
