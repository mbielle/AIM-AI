@testable import AIMAgentRuntime
import AIMAgentKit
import AIMApplication
@testable import AIMMac
import Foundation
import XCTest

final class AgentSubagentPoolTests: XCTestCase {
    func testDelegatesAreBoundedAndAwaitReturnsEveryResult() async throws {
        let counter = SubagentCounter()
        let gate = SubagentGate()
        let pool = AgentSubagentPool { prompt in
            await counter.enter()
            await gate.wait()
            await counter.leave()
            return "inspected: \(prompt)"
        }
        for index in 0..<5 {
            let request = ToolRequest(name: "delegate_task", arguments: ["title": "Task \(index)", "prompt": "read \(index)"], risk: .delegation)
            let result = await pool.execute(request)
            XCTAssertFalse(result.isError)
        }
        // Hold the first wave until all three workers have entered. Scheduler load must not
        // turn a timing-based overlap assertion into a flaky concurrency test.
        let entered = await counter.waitForRunning(3, timeout: .seconds(2))
        XCTAssertTrue(entered)
        await gate.open()
        let result = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0["status"] == "done" && $0["result"]?.hasPrefix("inspected:") == true })
        let maximum = await counter.maximum
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertGreaterThan(maximum, 1)
        await pool.close()
    }

    func testRetryMarkersDoNotMakeANewTask() {
        let base = AgentSubagentPool.taskKey("Réalisations de la communauté avec JEV")
        XCTAssertEqual(AgentSubagentPool.taskKey("Réalisations de la communauté avec JEV (2e essai)"), base)
        XCTAssertEqual(AgentSubagentPool.taskKey("réalisations de la communauté avec JEV — retry 3"), base)
        XCTAssertNotEqual(AgentSubagentPool.taskKey("Modèles IA basés sur la décision (JEV)"), base)
    }

    func testTheSameTaskIsNotDelegatedTwice() async throws {
        let gate = SubagentGate()
        let pool = AgentSubagentPool { _ in await gate.wait(); return "done" }
        let first = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Research JEV", "prompt": "find"], risk: .delegation))
        XCTAssertFalse(first.isError)
        let again = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "research jev", "prompt": "find again"], risk: .delegation))
        XCTAssertFalse(again.isError)
        XCTAssertEqual(again.metadata["deduplicated"], "true")
        XCTAssertEqual(again.metadata["job_id"], first.metadata["job_id"])
        await gate.open()
        _ = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        let later = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Research JEV", "prompt": "follow-up"], risk: .delegation))
        XCTAssertNil(later.metadata["deduplicated"], "A finished task may be delegated again")
        await pool.close()
    }

    func testRejectsInvalidDelegationButDoesNotLimitCumulativeJobs() async {
        let pool = AgentSubagentPool { _ in "done" }
        let invalid = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "", "prompt": "x"], risk: .delegation))
        XCTAssertTrue(invalid.isError)
        for index in 0..<12 {
            let result = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "\(index)", "prompt": "x"], risk: .delegation))
            XCTAssertFalse(result.isError)
        }
        let excessive = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "extra", "prompt": "x"], risk: .delegation))
        XCTAssertFalse(excessive.isError)
        await pool.close()
    }

    func testStatusPagesExposeLongQueueWithoutWaitingOrDroppingResults() async throws {
        let pool = AgentSubagentPool { _ in
            try await Task.sleep(for: .seconds(10))
            return "done"
        }
        for index in 0..<23 {
            let result = await pool.execute(ToolRequest(name: "delegate_task",
                arguments: ["title": "Task \(index)", "prompt": "inspect \(index)"], risk: .delegation))
            XCTAssertFalse(result.isError)
        }
        let first = await pool.execute(ToolRequest(name: "list_subagents",
            arguments: [:], risk: .readOnly))
        let firstRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.content.utf8)) as? [[String: String]])
        XCTAssertEqual(firstRows.count, 5)
        XCTAssertEqual(first.metadata["active_jobs"], "23")
        XCTAssertEqual(first.metadata["next_offset"], "5")
        let last = await pool.execute(ToolRequest(name: "list_subagents",
            arguments: ["offset": "20", "limit": "5"], risk: .readOnly))
        let lastRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.content.utf8)) as? [[String: String]])
        XCTAssertEqual(lastRows.count, 3)
        XCTAssertEqual(last.metadata["next_offset"], "end")
        XCTAssertTrue(lastRows.allSatisfy { $0["status"] == "queued" })
        let waited = await pool.execute(ToolRequest(name: "await_subagents",
            arguments: ["timeout_seconds": "1"], risk: .readOnly))
        XCTAssertEqual(waited.metadata["wait_state"], "timed_out")
        XCTAssertEqual(waited.metadata["expected_wait"], "true")
        await pool.close()
    }

    func testCancellingOneQueuedAndOneRunningChildKeepsOtherJobsActive() async throws {
        let pool = AgentSubagentPool { _ in
            try await Task.sleep(for: .seconds(10))
            return "done"
        }
        for index in 0..<4 {
            let result = await pool.execute(ToolRequest(name: "delegate_task",
                arguments: ["title": "Child \(index)", "prompt": "inspect"], risk: .delegation))
            XCTAssertFalse(result.isError)
        }
        let listed = await pool.execute(ToolRequest(name: "list_subagents",
            arguments: ["limit": "20"], risk: .readOnly))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.content.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.map { $0["status"] }, ["running", "running", "running", "queued"])
        for index in [0, 3] {
            let result = await pool.execute(ToolRequest(name: "cancel_subagent",
                arguments: ["job_id": try XCTUnwrap(rows[index]["id"])], risk: .delegation))
            XCTAssertFalse(result.isError)
        }
        var finalRows: [[String: String]] = []
        for _ in 0..<100 {
            let state = await pool.execute(ToolRequest(name: "list_subagents",
                arguments: ["limit": "20"], risk: .readOnly))
            finalRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(state.content.utf8)) as? [[String: String]])
            if finalRows[0]["status"] == "cancelled" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(finalRows[0]["status"], "cancelled")
        XCTAssertEqual(finalRows[3]["status"], "cancelled")
        XCTAssertEqual(finalRows[1]["status"], "running")
        XCTAssertEqual(finalRows[2]["status"], "running")
        await pool.close()
    }

    func testCompletedChildCanBeCollectedInNextPoolForSameConversation() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Durable child", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteSubagentJobRepository(database: db)
        let first = AgentSubagentPool(runner: { prompt in "finding: \(prompt)" },
            jobRepository: repository, conversationID: chat.id, workspacePath: "/fixture")
        let delegated = await first.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "Inspect", "prompt": "repository"], risk: .delegation))
        XCTAssertFalse(delegated.isError)
        let collected = await first.execute(ToolRequest(name: "await_subagents",
            arguments: [:], risk: .readOnly))
        XCTAssertEqual(collected.metadata["wait_state"], "complete")
        await first.close()
        let next = AgentSubagentPool(runner: { _ in "unused" }, jobRepository: repository,
            conversationID: chat.id, workspacePath: "/fixture")
        let listing = await next.execute(ToolRequest(name: "list_subagents",
            arguments: [:], risk: .readOnly))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listing.content.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.first?["status"], "done")
        XCTAssertEqual(rows.first?["result"], "finding: repository")
        await next.close()
    }

    func testInterruptedChildRequiresExplicitSingleRetry() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Retry child", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteSubagentJobRepository(database: db)
        let old = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
                                    title: "Investigate", prompt: "read history")
        try await repository.enqueue(old)
        let recovered = try await repository.recoverInterrupted()
        XCTAssertEqual(recovered, 1)
        let pool = AgentSubagentPool(runner: { prompt in "result: \(prompt)" },
            jobRepository: repository, conversationID: chat.id, workspacePath: "/fixture")
        let retry = await pool.execute(ToolRequest(name: "retry_subagent",
            arguments: ["job_id": old.id.uuidString], risk: .delegation))
        XCTAssertFalse(retry.isError)
        let duplicate = await pool.execute(ToolRequest(name: "retry_subagent",
            arguments: ["job_id": old.id.uuidString], risk: .delegation))
        XCTAssertTrue(duplicate.isError)
        _ = await pool.execute(ToolRequest(name: "await_subagents",
            arguments: [:], risk: .readOnly))
        let listed = await pool.execute(ToolRequest(name: "list_subagents",
            arguments: ["limit": "20"], risk: .readOnly))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.content.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["status"], "interrupted")
        XCTAssertEqual(rows[1]["status"], "done")
        XCTAssertEqual(rows[1]["retry_of"], old.id.uuidString)
        await pool.close()
    }
}

private actor SubagentCounter {
    var running = 0
    var maximum = 0
    func enter() { running += 1; maximum = max(maximum, running) }
    func leave() { running -= 1 }
    func waitForRunning(_ count: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        while running < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return running >= count
    }
}

private actor SubagentGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}
