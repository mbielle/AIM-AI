@testable import AIMAgentRuntime
import AIMAgentKit
import AIMApplication
@testable import AIMMac
import XCTest

final class AgentEnvironmentAndChildModelTests: XCTestCase {
    func testEnvironmentMessageIsDailyStableAndDescribesGit() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("aim-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = AgentEnvironmentContext.message(workspace: plain.path, conversationID: UUID(), now: date)
        let later = AgentEnvironmentContext.message(workspace: plain.path, conversationID: UUID(), now: date.addingTimeInterval(60))
        XCTAssertEqual(first.content, later.content, "no clock time, so the cached prefix survives a minute")
        XCTAssertTrue(first.content.contains("Git context is unavailable"))
        XCTAssertTrue(first.content.contains(plain.path))
        XCTAssertTrue(AgentEnvironmentContext.message(workspace: nil, conversationID: UUID()).content.contains("No workspace"))
    }

    func testDelegatedChildCanUseAnotherModel() async throws {
        let models = ModelBox()
        let pool = AgentSubagentPool(assignmentRunner: { assignment in
            await models.add(assignment.modelID ?? "parent")
            return "done"
        })
        _ = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Fast", "prompt": "look", "model": "vendor/fast"], risk: .delegation))
        _ = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Default", "prompt": "look"], risk: .delegation))
        let invalid = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Bad", "prompt": "look", "model": "two words"], risk: .delegation))
        XCTAssertTrue(invalid.isError)
        _ = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        let used = await models.values
        XCTAssertEqual(Set(used), ["vendor/fast", "parent"])
        await pool.close()
    }

    func testTurnContextGoesRightBeforeTheLatestUserMessage() {
        let id = UUID()
        let history = [ConversationMessage(conversationID: id, role: .user, content: "a", sequence: 0),
                       ConversationMessage(conversationID: id, role: .assistant, content: "b", sequence: 1),
                       ConversationMessage(conversationID: id, role: .user, content: "c", sequence: 2)]
        let context = [ConversationMessage(conversationID: id, role: .user, content: "ctx", sequence: -3)]
        XCTAssertEqual(ProviderTurnRunner.placingContext(context, in: history).map(\.content), ["a", "b", "ctx", "c"])
        XCTAssertEqual(ProviderTurnRunner.placingContext(context, in: []).map(\.content), ["ctx"])
    }
}

private actor ModelBox {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
