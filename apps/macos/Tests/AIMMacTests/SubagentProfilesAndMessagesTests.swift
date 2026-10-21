@testable import AIMAgentRuntime
import AIMAgentKit
import AIMApplication
@testable import AIMMac
import XCTest

private final class RecordingConversation: SteerableModelToolConversation, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String]] = []
    var steering: [[String]] { lock.withLock { received } }
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn {
        lock.withLock { received.append([]) }
        return ModelToolTurn(text: "", calls: [])
    }
    func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        lock.withLock { received.append(userMessages) }
        return ModelToolTurn(text: "", calls: [])
    }
}

final class SubagentProfilesAndMessagesTests: XCTestCase {
    func testParentMessagesReachTheChildAndNotesReachTheParent() async throws {
        let pool = AgentSubagentPool(assignmentRunner: { assignment in
            XCTAssertEqual(assignment.profile, .review)
            assignment.mailbox.post(toParent: "Found a suspicious cast in Parser.swift")
            for _ in 0..<100 {
                let messages = assignment.mailbox.drainForChild()
                if !messages.isEmpty { return "child got: " + messages.joined(separator: " | ") }
                try await Task.sleep(for: .milliseconds(20))
            }
            return "no message"
        })
        let started = await pool.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "Review", "prompt": "review Parser", "profile": "review"], risk: .delegation))
        XCTAssertFalse(started.isError, started.content)
        let listed = await pool.execute(ToolRequest(name: "list_subagents", arguments: [:], risk: .readOnly))
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(listed.content.utf8)) as? [[String: String]])?.first?["id"])
        let sent = await pool.execute(ToolRequest(name: "message_subagent", arguments: ["job_id": id, "text": "Focus on error paths"], risk: .readOnly))
        XCTAssertFalse(sent.isError, sent.content)
        let done = await pool.execute(ToolRequest(name: "await_subagents", arguments: ["timeout_seconds": "5"], risk: .readOnly))
        let row = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(done.content.utf8)) as? [[String: String]])?.first)
        XCTAssertEqual(row["result"], "child got: Focus on error paths")
        XCTAssertEqual(row["notes"], "Found a suspicious cast in Parser.swift")
        let late = await pool.execute(ToolRequest(name: "message_subagent", arguments: ["job_id": id, "text": "too late"], risk: .readOnly))
        XCTAssertTrue(late.isError, "a finished child cannot receive messages")
        let research = await pool.execute(ToolRequest(name: "delegate_task",
            arguments: ["title": "Web", "prompt": "find", "profile": "research"], risk: .delegation))
        XCTAssertTrue(research.isError, "research needs web tools from the parent")
        await pool.close()
    }

    func testParentMessagesAreDeliveredAtTheNextModelStep() async throws {
        let inner = RecordingConversation()
        let mailbox = SubagentMailbox()
        let conversation = MailboxSteeredConversation(inner: inner, mailbox: mailbox)
        _ = try await conversation.next(outputs: [])
        mailbox.post(toChild: "Stop and summarize")
        _ = try await conversation.next(outputs: [])
        _ = try await conversation.next(outputs: [])
        XCTAssertEqual(inner.steering.count, 3)
        XCTAssertEqual(inner.steering[0], [])
        XCTAssertEqual(inner.steering[1].count, 1)
        XCTAssertTrue(inner.steering[1][0].hasSuffix("Stop and summarize"))
        XCTAssertEqual(inner.steering[2], [], "a message is delivered once")
    }
}
