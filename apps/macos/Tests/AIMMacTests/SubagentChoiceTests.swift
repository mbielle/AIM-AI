@testable import AIMAgentRuntime
import AIMAgentKit
import AIMApplication
import AIMCore
import Foundation
import XCTest

private actor AssignmentLog {
    var values: [(ChatProvider?, String?, String?)] = []
    func add(_ assignment: SubagentAssignment) { values.append((assignment.provider, assignment.modelID, assignment.effort)) }
}

final class SubagentChoiceTests: XCTestCase {
    func testExplicitProviderModelAndEffortReachTheChild() async throws {
        let log = AssignmentLog()
        let pool = AgentSubagentPool(assignmentRunner: { assignment in await log.add(assignment); return "ok" },
                                     peerProvider: .anthropic, peerDefaultModel: "claude-opus-5-5")
        let result = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "Scan", "prompt": "list files",
            "provider": "openrouter", "model": "anthropic/claude-haiku-5.5", "effort": "low"], risk: .delegation))
        XCTAssertFalse(result.isError, result.content)
        _ = await pool.execute(ToolRequest(name: "await_subagents", arguments: [:], risk: .readOnly))
        let values = await log.values
        XCTAssertEqual(values.first?.0, .openRouter)
        XCTAssertEqual(values.first?.1, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(values.first?.2, "low")
        await pool.close()
    }

    func testInvalidChoicesAreRefusedWithoutStartingAChild() async {
        let log = AssignmentLog()
        let pool = AgentSubagentPool(assignmentRunner: { assignment in await log.add(assignment); return "ok" }, peerProvider: .openAI, peerDefaultModel: "gpt-6-sol")
        let noModel = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "a", "prompt": "b", "provider": "openrouter"], risk: .delegation))
        XCTAssertTrue(noModel.isError); XCTAssertTrue(noModel.content.contains("model"))
        let badEffort = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "a", "prompt": "b", "effort": "extreme"], risk: .delegation))
        XCTAssertTrue(badEffort.isError); XCTAssertTrue(badEffort.content.contains("effort must be one of"))
        let badProvider = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "a", "prompt": "b", "provider": "perplexity", "model": "sonar"], risk: .delegation))
        XCTAssertTrue(badProvider.isError)
        let noEffortSetting = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "a", "prompt": "b", "provider": "google", "model": "gemini-3-pro", "effort": "high"], risk: .delegation))
        XCTAssertTrue(noEffortSetting.isError == !OpenAIReasoningEffort.applies(to: .google))
        let started = await log.values.count
        XCTAssertLessThanOrEqual(started, 1)
        await pool.close()
    }

    func testRecommendationToolAndUserCancellation() async throws {
        let pool = AgentSubagentPool(assignmentRunner: { _ in try await Task.sleep(for: .seconds(30)); return "late" },
            recommender: { request in "candidates for \(request.size.rawValue): \(request.task) vision=\(request.needsVision)" })
        let advice = await pool.execute(ToolRequest(name: "recommend_subagent_models", arguments: ["task": "read the logs", "size": "small", "needs": "[\"vision\"]"], risk: .readOnly))
        XCTAssertEqual(advice.content, "candidates for small: read the logs vision=true")
        let started = await pool.execute(ToolRequest(name: "delegate_task", arguments: ["title": "slow", "prompt": "wait"], risk: .delegation))
        let id = try XCTUnwrap(started.metadata["job_id"].flatMap(UUID.init(uuidString:)))
        let refusal = await pool.cancelJob(id, reason: "Cancelled by you.")
        XCTAssertNil(refusal)
        let unknown = await pool.cancelJob(UUID(), reason: "Cancelled by you.")
        XCTAssertEqual(unknown, "Unknown sub-agent ID.")
        await pool.close()
    }
}

/// Test 28 refused every Agent run with a folder: a parent tool was registered without its
/// executor declaring it. The parent's tools must pass the dispatcher's own registration check.
final class SubagentParentToolsTests: XCTestCase {
    func testParentToolsRegisterInTheDispatcher() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-subagent-tools-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pool = AgentSubagentPool(assignmentRunner: { _ in "ok" })
        for writes in [false, true] {
            let tools = AgentSubagentPool.parentTools(pool, writes: writes)
            XCTAssertTrue(tools.allSatisfy { pool.supportedTools.contains($0.name) }, tools.map(\.name).filter { !pool.supportedTools.contains($0) }.joined())
            XCTAssertNoThrow(try ApprovedToolDispatcher(tools: tools, broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: folder.path))
        }
        XCTAssertEqual(pool.risk(for: "recommend_subagent_models", arguments: [:]), .readOnly)
    }
}
