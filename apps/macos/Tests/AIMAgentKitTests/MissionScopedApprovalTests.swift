import AIMAgentKit
import AIMApplication
import XCTest

private actor ScopedFixtureTool: MissionIntentProviding {
    nonisolated let supportedTools: Set<String> = ["scoped"]
    var target: MissionResource
    private(set) var executions = 0

    init(target: MissionResource) { self.target = target }
    func setTarget(_ target: MissionResource) { self.target = target }
    func missionIntent(for request: ToolRequest) -> MissionToolIntent? {
        MissionToolIntent(operation: .input, target: target)
    }
    func execute(_ request: ToolRequest) -> ToolResult {
        executions += 1
        return ToolResult(requestID: request.id, content: "fixture input")
    }
    func cancel(requestID: String) {}
}

final class MissionScopedApprovalTests: XCTestCase {
    func testCancelledMissionCannotFallBackToLegacyAutoPolicy() async throws {
        let (repository, missionID, target) = try await mission()
        let loaded = try await repository.load(id: missionID)
        let mission = try XCTUnwrap(loaded)
        _ = try await repository.transition(missionID: missionID, expectedRevision: mission.revision,
            to: .cancelled, reason: "Stopped", activeRunID: nil)
        let tool = ScopedFixtureTool(target: target)
        let dispatcher = try ApprovedToolDispatcher(
            tools: [RegisteredTool(name: "scoped", risk: .localMutation, executor: tool)],
            broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil,
            missionRepository: repository, missionID: missionID)
        let result = await dispatcher.execute(id: "after-stop", name: "scoped", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("no longer active"))
        let count = await tool.executions
        XCTAssertEqual(count, 0)
    }

    func testScopeDoesNotOverrideSupervisedOrDestructiveApproval() async throws {
        let (repository, missionID, target) = try await mission()
        let rule = try MissionAuthorizationRule(resource: target, operations: [.input])
        _ = try await repository.replaceAuthorization(missionID: missionID, expectedRevision: nil, rules: [rule])
        for (policy, risk) in [(ApprovalPolicy.smart, ToolRisk.computerAction), (.autoApprove, .destructive)] {
            let tool = ScopedFixtureTool(target: target)
            let broker = ToolApprovalBroker()
            let dispatcher = try ApprovedToolDispatcher(
                tools: [RegisteredTool(name: "scoped", risk: risk, executor: tool)],
                broker: broker, policy: policy, workspacePath: nil,
                missionRepository: repository, missionID: missionID)
            let task = Task { await dispatcher.execute(id: UUID().uuidString, name: "scoped", arguments: [:]) }
            let approval = try await nextApproval(broker)
            let before = await tool.executions
            XCTAssertEqual(before, 0)
            await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
            let denied = await task.value
            XCTAssertTrue(denied.isError)
        }
    }

    func testCoveredAutoActionSkipsPromptButOutsideScopeNeedsExactApproval() async throws {
        let (repository, missionID, target) = try await mission()
        let rule = try MissionAuthorizationRule(resource: target, operations: [.input])
        _ = try await repository.replaceAuthorization(missionID: missionID, expectedRevision: nil, rules: [rule])
        let tool = ScopedFixtureTool(target: target)
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "scoped", risk: .computerAction, executor: tool)],
            broker: broker, policy: .autoApprove, workspacePath: nil,
            missionRepository: repository, missionID: missionID)
        let allowed = await dispatcher.execute(id: "covered", name: "scoped", arguments: [:])
        XCTAssertFalse(allowed.isError)
        let noApprovals = await broker.snapshot()
        XCTAssertTrue(noApprovals.isEmpty)
        let firstCount = await tool.executions
        XCTAssertEqual(firstCount, 1)

        let other = try MissionResource(kind: .application, identifier: "com.test.Other")
        await tool.setTarget(other)
        let outside = Task { await dispatcher.execute(id: "outside", name: "scoped", arguments: [:]) }
        let approval = try await nextApproval(broker)
        XCTAssertFalse(approval.allowsSessionDecision)
        let before = await tool.executions
        XCTAssertEqual(before, 1)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let denied = await outside.value
        XCTAssertTrue(denied.isError)
        let after = await tool.executions
        XCTAssertEqual(after, 1)
    }

    func testRevocationAtLaunchAndTargetChangeDuringApprovalPreventEffect() async throws {
        let (repository, missionID, target) = try await mission()
        let rule = try MissionAuthorizationRule(resource: target, operations: [.input])
        let authorization = try await repository.replaceAuthorization(missionID: missionID,
            expectedRevision: nil, rules: [rule])
        let tool = ScopedFixtureTool(target: target)
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "scoped", risk: .computerAction, executor: tool)],
            broker: broker, policy: .autoApprove, workspacePath: nil,
            missionRepository: repository, missionID: missionID)
        let revoked = await dispatcher.execute(id: "revoke", name: "scoped", arguments: [:], willExecute: {
            _ = try await repository.revokeAuthorization(missionID: missionID,
                expectedRevision: authorization.revision)
        })
        XCTAssertTrue(revoked.isError)
        let afterRevocation = await tool.executions
        XCTAssertEqual(afterRevocation, 0)

        let other = try MissionResource(kind: .application, identifier: "com.test.Other")
        let third = try MissionResource(kind: .application, identifier: "com.test.Third")
        await tool.setTarget(other)
        let pending = Task { await dispatcher.execute(id: "changed", name: "scoped", arguments: [:]) }
        let approval = try await nextApproval(broker)
        await tool.setTarget(third)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        let changed = await pending.value
        XCTAssertTrue(changed.isError)
        XCTAssertTrue(changed.content.contains("target changed"))
        let afterTargetChange = await tool.executions
        XCTAssertEqual(afterTargetChange, 0)
    }

    private func mission() async throws -> (SQLiteAgentMissionRepository, UUID, MissionResource) {
        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Scoped action", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let repository = SQLiteAgentMissionRepository(database: database)
        let mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Edit the fixture")
        let target = try MissionResource(kind: .application, identifier: "com.test.Target")
        return (repository, mission.id, target)
    }

    private func nextApproval(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let approval = await broker.snapshot().first { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Approval did not appear", code: 1)
    }
}
