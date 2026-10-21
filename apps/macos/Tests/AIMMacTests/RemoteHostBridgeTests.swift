@testable import AIMAgentRuntime
@testable import AIMAgentKit
import AIMApplication
import AIMCore
@testable import AIMMacPlatform
@testable import AIMMac
import XCTest

final class RemoteHostBridgeTests: XCTestCase {
    func testOpenAppApprovalSnapshotIncludesTargetPlacementAndBoundedRedactedSummary() {
        let conversation = Conversation(title: "Apps", mode: .agent)
        for (arguments, expected) in [
            (["app": "Calculator"], "Open app · Calculator · in the background"),
            (["bundle_id": "com.apple.calculator", "activate": "true"], "Open app · com.apple.calculator · in front")
        ] {
            let approval = PendingToolApproval(id: UUID(), sessionID: conversation.id, toolName: "open_app",
                arguments: arguments, workspacePath: nil, risk: .destructive,
                allowsSessionDecision: false, review: nil, priorUncertainAction: false)
            let snapshot = RemoteHostBridge.snapshot(conversation, running: true, approval: approval,
                question: nil, messages: [], approvalMode: nil)
            XCTAssertEqual(snapshot.pendingApproval?.objectValue?["summary"]?.stringValue, expected)
            XCTAssertEqual(approval.remoteSummary, expected)
        }
        let secret = PendingToolApproval(id: UUID(), sessionID: conversation.id, toolName: "open_app",
            arguments: ["app": "password=hidden " + String(repeating: "x", count: 400)], workspacePath: nil,
            risk: .destructive, allowsSessionDecision: false, review: nil, priorUncertainAction: false)
        XCTAssertFalse(secret.remoteSummary.contains("hidden"))
        XCTAssertLessThanOrEqual(secret.remoteSummary.count, 300)
    }

    func testSnapshotShowsApprovalsQuestionsAndRunningState() {
        let conversation = Conversation(title: "Ship it", mode: .agent, modelID: "m", workspacePath: "/Users/example/app")
        let messages = [
            ConversationMessage(conversationID: conversation.id, role: .user, content: "Fix the tests", sequence: 0),
            ConversationMessage(conversationID: conversation.id, role: .user, content: "context", sequence: -3),
            ConversationMessage(conversationID: conversation.id, role: .assistant, content: "On it", sequence: 1)
        ]
        let approval = PendingToolApproval(id: UUID(), sessionID: conversation.id, toolName: "run_command",
            arguments: ["command": "swift test"], workspacePath: "/Users/example/app", risk: .destructive,
            allowsSessionDecision: false, review: nil, priorUncertainAction: false)
        let waiting = RemoteHostBridge.snapshot(conversation, running: true, approval: approval, question: nil,
                                                messages: messages, approvalMode: .smart)
        XCTAssertEqual(waiting.status, "waiting_approval")
        XCTAssertEqual(waiting.approvalMode, "smart")
        XCTAssertEqual(waiting.messages.map(\.content), ["Fix the tests", "On it"], "request-only context is not mirrored")
        XCTAssertEqual(waiting.pendingApproval?.objectValue?["summary"]?.stringValue, "run_command · swift test")
        XCTAssertEqual(waiting.id, conversation.id.uuidString.lowercased())

        let question = AgentQuestion(id: "q1", conversationID: conversation.id, text: "Which branch?", options: ["main", "dev"])
        let asking = RemoteHostBridge.snapshot(conversation, running: true, approval: nil, question: question,
                                               messages: messages, approvalMode: nil)
        XCTAssertEqual(asking.pendingApproval?.objectValue?["kind"]?.stringValue, "question")
        XCTAssertEqual(asking.pendingApproval?.objectValue?["messageId"]?.stringValue, "question:q1")
        XCTAssertEqual(asking.approvalMode, "always_ask")

        let running = RemoteHostBridge.snapshot(conversation, running: true, approval: nil, question: nil, messages: messages, approvalMode: nil)
        XCTAssertEqual(running.status, "running")
        let idle = RemoteHostBridge.snapshot(conversation, running: false, approval: nil, question: nil, messages: messages, approvalMode: nil)
        XCTAssertEqual(idle.status, "idle")
        XCTAssertNil(idle.phase)
    }

    func testAgentSnapshotPreservesSelectedEngineAndLegacyDefaults() {
        for id in ["aim", "hermes", "openclaw"] {
            let conversation = Conversation(title: "Agent", mode: .agent, engineID: id)
            XCTAssertEqual(RemoteHostBridge.snapshot(conversation, running: false, approval: nil, question: nil, messages: [], approvalMode: nil).agentSystem, id)
        }
        let old = Conversation(title: "Legacy", mode: .agent)
        XCTAssertEqual(RemoteHostBridge.snapshot(old, running: false, approval: nil, question: nil, messages: [], approvalMode: nil).agentSystem, "aim")
    }

    func testChatConversationsAreRelayedWithoutWorkspaceOrApprovals() {
        let chat = Conversation(title: "Recipe ideas", mode: .chat, modelID: "openai/gpt-5", workspacePath: "/tmp/should-not-leak")
        let snapshot = RemoteHostBridge.snapshot(chat, running: false, approval: nil, question: nil,
            messages: [ConversationMessage(conversationID: chat.id, role: .user, content: "Dinner?", sequence: 0)], approvalMode: nil)
        XCTAssertEqual(snapshot.mode, "chat")
        XCTAssertNil(snapshot.workspace)
        XCTAssertNil(snapshot.agentSystem)
        XCTAssertNil(snapshot.approvalMode)
        XCTAssertEqual(snapshot.modelID, "openai/gpt-5")
    }
}

extension RemoteHostBridgeTests {
    func testFailedLastTurnIsAnnouncedAndCancellationIsNotFailure() {
        let conversation = Conversation(title: "Code", mode: .code)
        var answer = ConversationMessage(conversationID: conversation.id, role: .assistant, content: "partial", sequence: 1, completionStatus: .failed)
        let failed = RemoteHostBridge.snapshot(conversation, running: false, approval: nil, question: nil, messages: [answer], approvalMode: nil)
        XCTAssertEqual(failed.mode, "code"); XCTAssertEqual(failed.status, "failed")
        answer.completionStatus = .cancelled
        XCTAssertEqual(RemoteHostBridge.snapshot(conversation, running: false, approval: nil, question: nil, messages: [answer], approvalMode: nil).status, "idle")
    }
}

extension RemoteHostBridgeTests {
    @MainActor
    func testDurableRootAndChildApprovalMirrorUsesOwningConversation() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Durable", mode: .agent)
        let other = Conversation(title: "Other", mode: .agent)
        var root = AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data())
        root.state = .waitingUser
        model.conversations = [conversation, other]
        model.continuityExecutions = [root]
        for sessionID in [root.id, UUID()] { // root and a durable child have distinct session namespaces
            let approval = PendingToolApproval(id: UUID(), sessionID: sessionID, toolName: "open_app",
                arguments: ["app": "Calculator"], workspacePath: nil, risk: .externalEffect,
                allowsSessionDecision: false, review: nil, priorUncertainAction: false)
            model.updateContinuityInteractions(approvals: [approval], questions: [], roots: [approval.id: root.id])
            XCTAssertTrue(model.toolApproval(approval, belongsTo: conversation.id))
            XCTAssertFalse(model.toolApproval(approval, belongsTo: other.id))
            let snapshots = await RemoteHostBridge(model: model).remoteSnapshots()
            let own = try XCTUnwrap(snapshots.first { $0.id == conversation.id.uuidString.lowercased() })
            XCTAssertEqual(own.pendingApproval?.objectValue?["messageId"]?.stringValue, approval.id.uuidString)
            XCTAssertEqual(own.pendingApproval?.objectValue?["summary"]?.stringValue, "Open app · Calculator · in the background")
            XCTAssertNil(snapshots.first { $0.id == other.id.uuidString.lowercased() }?.pendingApproval)
            model.updateContinuityInteractions(approvals: [approval], questions: [], roots: [approval.id: UUID()])
            XCTAssertFalse(model.toolApproval(approval, belongsTo: conversation.id), "Unknown root fails closed")
        }
        root.state = .verified
        model.continuityExecutions = [root]
        let terminal = PendingToolApproval(id: UUID(), sessionID: root.id, toolName: "open_app", arguments: [:],
            workspacePath: nil, risk: .externalEffect, allowsSessionDecision: false, review: nil, priorUncertainAction: false)
        model.updateContinuityInteractions(approvals: [terminal], questions: [], roots: [terminal.id: root.id])
        XCTAssertFalse(model.toolApproval(terminal, belongsTo: conversation.id))
        _ = await model.prepareForTermination()
    }

    @MainActor
    func testApprovalRejectsStaleMissingAndOtherConversationIDsWithoutDispatch() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Pending", mode: .agent)
        let other = Conversation(title: "Other", mode: .agent)
        model.conversations = [conversation, other]
        let approval = PendingToolApproval(id: UUID(), sessionID: conversation.id, toolName: "open_app",
            arguments: ["bundle_id": "com.apple.calculator"], workspacePath: nil, risk: .externalEffect,
            allowsSessionDecision: false, review: nil, priorUncertainAction: false)
        model.pendingToolApprovals = [approval]
        let bridge = RemoteHostBridge(model: model)
        for messageID in [nil, UUID().uuidString, "question:unrelated"] as [String?] {
            var payload: [String: RemoteJSONValue] = ["approved": .bool(true)]
            if let messageID { payload["messageId"] = .string(messageID) }
            do {
                _ = try await bridge.remoteExecute(type: "approval_response", sessionID: conversation.id.uuidString,
                                                   payload: .object(payload), attachments: [])
                XCTFail("Stale approval must not dispatch")
            } catch let failure as RemoteHostCommandFailure { XCTAssertEqual(failure.code, "approbation_expiree") }
            XCTAssertEqual(model.pendingToolApprovals, [approval])
        }
        do {
            _ = try await bridge.remoteExecute(type: "approval_response", sessionID: other.id.uuidString,
                payload: .object(["messageId": .string(approval.id.uuidString), "approved": .bool(true)]), attachments: [])
            XCTFail("Approval cannot cross conversations")
        } catch let failure as RemoteHostCommandFailure { XCTAssertEqual(failure.code, "aucune_approbation_en_attente") }
        XCTAssertEqual(RemoteHostBridge.summary(approval), "Open app · com.apple.calculator · in the background")
        _ = await model.prepareForTermination()
    }

    @MainActor
    func testQuestionRequiresMatchingIDAndNeverReportsUnacceptedAnswerAsDone() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Question", mode: .agent)
        model.conversations = [conversation]
        let question = AgentQuestion(id: "current", conversationID: conversation.id, text: "Colour?", options: [])
        model.pendingAgentQuestions = [question]
        let bridge = RemoteHostBridge(model: model)
        for id in ["question:old", "question:current"] {
            do {
                _ = try await bridge.remoteExecute(type: "approval_response", sessionID: conversation.id.uuidString,
                    payload: .object(["messageId": .string(id), "answers": .string("Blue")]), attachments: [])
                XCTFail("Stale or unaccepted question must not be reported done")
            } catch let failure as RemoteHostCommandFailure { XCTAssertEqual(failure.code, "approbation_expiree") }
        }
        XCTAssertEqual(model.pendingAgentQuestions, [question])
        _ = await model.prepareForTermination()
    }
}

private actor RemoteApprovalRecordingEngine: AgentEngine {
    nonisolated let id = AgentEngineID.hermes
    private var decisions: [(String, ApprovalDecision)] = []
    func status() -> EngineStatus { EngineStatus(id: id, state: .ready, isInstalled: true) }
    func install() async throws {}
    func start() async throws {}
    func stop() async {}
    func diagnose() async -> EngineDiagnostic? { nil }
    func send(_ request: AgentRequest) async throws {}
    func cancel(conversationID: UUID) async {}
    func decide(approvalID: String, decision: ApprovalDecision) async { decisions.append((approvalID, decision)) }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func recorded() -> [(String, ApprovalDecision)] { decisions }
}

extension RemoteHostBridgeTests {
    @MainActor
    func testTwoPendingApprovalsDispatchesOnlyExactRequestedIDWithAllowOnce() async throws {
        let engine = RemoteApprovalRecordingEngine()
        let model = AppModel(database: try AIMDatabase(inMemory: true), additionalAgentEngines: [engine])
        await model.start()
        let conversation = Conversation(title: "Concurrent approvals", mode: .agent, engineID: "hermes")
        model.conversations = [conversation]
        func approval() -> PendingToolApproval {
            PendingToolApproval(id: UUID(), sessionID: conversation.id, toolName: "open_app", arguments: ["app": "Calculator"],
                workspacePath: nil, risk: .externalEffect, allowsSessionDecision: true, review: nil, priorUncertainAction: false)
        }
        let first = approval(), requested = approval()
        model.pendingToolApprovals = [first, requested]
        _ = try await RemoteHostBridge(model: model).remoteExecute(type: "approval_response", sessionID: conversation.id.uuidString,
            payload: .object(["messageId": .string(requested.id.uuidString), "approved": .bool(true)]), attachments: [])
        let decisions = await engine.recorded()
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.0, conversation.id.uuidString + "/" + requested.id.uuidString)
        XCTAssertEqual(decisions.first?.1, .allowOnce)
        _ = await model.prepareForTermination()
    }
}
