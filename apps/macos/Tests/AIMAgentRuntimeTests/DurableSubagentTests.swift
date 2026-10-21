import AIMCore
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

final class DurableSubagentTests: XCTestCase {
    private func fixture() async throws -> (AIMDatabase, RuntimeExecutionContext, AgentExecution) {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Parent", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await repository.installOwner(owner)
        var parent = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        parent = try await repository.transition(parent.id, owner: owner, expectedRevision: parent.revision, to: .running)
        return (database, RuntimeExecutionContext(repository: repository, executionID: parent.id, owner: owner), parent)
    }
    func testConfiguredGeneralRouteIsCapturedAndTaskModelTakesPriority() async throws {
        let (_, context, parent) = try await fixture()
        let configured = SubagentModelChoice(provider: .google, modelID: "configured-model")
        let pool = AgentSubagentPool(assignmentRunner: { assignment in
            (assignment.provider?.rawValue ?? "nil") + ":" + (assignment.modelID ?? "nil")
        }, conversationID: parent.conversationID, workspacePath: "/tmp", executionContext: context,
            defaultChoice: configured, peerProvider: .openRouter, peerDefaultModel: "main")
        for (callID, explicit) in [("default", false), ("explicit", true)] {
            var args = ["title": callID, "prompt": "Inspect fixture"]
            if explicit { args["model"] = "task-model" }
            let result = await pool.execute(.init(id: callID, name: "delegate_task", arguments: args, risk: .delegation))
            XCTAssertFalse(result.isError, result.content)
        }
        _ = await pool.execute(.init(name: "await_subagents", arguments: ["timeout_seconds": "5"], risk: .readOnly))
        for _ in 0..<200 {
            if try await context.repository.children(parentExecutionID: parent.id).allSatisfy({ $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let children = try await context.repository.children(parentExecutionID: parent.id)
        let automatic = try XCTUnwrap(children.first { $0.admissionCallID == "default" })
        let explicit = try XCTUnwrap(children.first { $0.admissionCallID == "explicit" })
        XCTAssertEqual(automatic.providerID, "google"); XCTAssertEqual(automatic.modelID, "configured-model")
        XCTAssertEqual(explicit.providerID, "openrouter"); XCTAssertEqual(explicit.modelID, "task-model")
        XCTAssertEqual(automatic.result, "google:configured-model"); XCTAssertEqual(explicit.result, "openrouter:task-model")
        let observedParent = try await context.repository.execution(parent.id)
        let currentParent = try XCTUnwrap(observedParent)
        if currentParent.state != .running {
            _ = try await context.repository.transition(parent.id, owner: context.owner, expectedRevision: currentParent.revision, to: .running)
        }
        var conflict = DurableSubagent(id: automatic.id, parentExecutionID: automatic.parentExecutionID,
            admissionCallID: automatic.admissionCallID, title: automatic.title, prompt: automatic.prompt,
            workspacePath: automatic.workspacePath, modelID: automatic.modelID, profile: automatic.profile,
            worktree: automatic.worktree, parentChildID: automatic.parentChildID, dependencyIDs: automatic.dependencyIDs,
            depth: automatic.depth, requiredResultKeys: automatic.requiredResultKeys)
        conflict.providerID = "openai"
        do { _ = try await context.repository.admitChild(conflict, owner: context.owner); XCTFail("Route mutation must conflict") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .commandConflict) }
        await pool.close()
    }

    func testUnavailableGeneralRouteAdmitsNoChildAndNeverSubstitutes() async throws {
        let (_, context, parent) = try await fixture()
        let pool = AgentSubagentPool(assignmentRunner: { _ in XCTFail("Must not launch"); return "" },
            conversationID: parent.conversationID, workspacePath: "/tmp", executionContext: context,
            defaultChoice: .init(provider: .google, modelID: "missing"), peerProvider: .openRouter, peerDefaultModel: "main",
            routeValidator: { _ in throw ProviderCredentialError.unavailable })
        let result = await pool.execute(.init(id: "missing", name: "delegate_task", arguments: ["title": "Inspect", "prompt": "Fixture"], risk: .delegation))
        XCTAssertTrue(result.isError)
        let children = try await context.repository.children(parentExecutionID: parent.id)
        XCTAssertTrue(children.isEmpty)
        await pool.close()
    }

    func testNetworkJournalProjectsOneStableActionAndCancelledWait() async throws {
        let (_, context, parent) = try await fixture()
        let start = parent.createdAt.addingTimeInterval(-1)
        let user = ConversationMessage(conversationID: parent.conversationID, role: .user, content: "Fixture", sequence: 0, createdAt: start)
        let assistant = ConversationMessage(conversationID: parent.conversationID, role: .assistant, content: "", sequence: 1, createdAt: start.addingTimeInterval(2))
        let fragment = ConversationMessage(conversationID: parent.conversationID, role: .assistant, content: "Fragment", sequence: 2, createdAt: start.addingTimeInterval(3))
        for stage: AgentRunStage in [.waitingForNetwork, .waitingForModel, .waitingForNetwork] {
            try await context.repository.recordEvent(parent.id, owner: context.owner, kind: "engine", payload: JSONEncoder().encode(EngineEvent.runStage(conversationID: parent.conversationID, stage: stage)))
        }
        let observed = try await context.repository.execution(parent.id)
        let current = try XCTUnwrap(observed)
        _ = try await context.repository.transition(parent.id, owner: context.owner, expectedRevision: current.revision, to: .cancelled)
        let first = try await RuntimeConversationActivity.apply(repository: context.repository, to: [user, assistant, fragment])
        let again = try await RuntimeConversationActivity.apply(repository: context.repository, to: first)
        let actions = try XCTUnwrap(again[1].actions)
        XCTAssertEqual(actions.count, 1); XCTAssertEqual(actions[0].state, .cancelled)
        XCTAssertTrue(actions[0].detail?.contains("2") == true)
        XCTAssertEqual(actions[0].id, parent.id.uuidString + ":network")
        XCTAssertNil(again[2].actions)
    }

    private func checkpoint(_ text: String = "Child result") -> ExecutionCheckpoint {
        ExecutionCheckpoint(conversation: ModelConversationCheckpoint(codec: "native-v1", provider: .openRouter,
            modelID: "fixture", transcript: Data("[]".utf8), pendingIDs: [], seenIDs: [], finished: true, usage: TokenUsage()),
            turn: ModelToolTurn(text: text, calls: []), effects: [], ordinal: 0, seenCallIDs: [])
    }
    func testMessagesConsumeOnlyWithCheckpointAndOldOwnerCannotWrite() async throws {
        let (_, context, _) = try await fixture()
        let child = try await context.repository.admitChild(DurableSubagent(id: UUID(), parentExecutionID: context.executionID,
            admissionCallID: "delegate", title: "Inspect", prompt: "read", workspacePath: "/tmp", modelID: nil, profile: "code", worktree: nil), owner: context.owner)
        let mailbox = context.repository.childMailbox(childID: child.id, owner: context.owner)
        try mailbox.post(id: "message", text: "Keep exact reference ABC123", toChild: true)
        try mailbox.post(id: "message", text: "Keep exact reference ABC123", toChild: true)
        XCTAssertEqual(try mailbox.messages(toChild: true).count, 1)
        _ = try await context.repository.transitionChild(child.id, owner: context.owner, expectedRevision: child.revision, to: .running)
        var saved = checkpoint(); saved.conversation.extensions = ["mailbox_consumed": try JSONEncoder().encode(["message"])]
        try await context.repository.saveChildCheckpoint(saved, childID: child.id, owner: context.owner)
        XCTAssertTrue(try mailbox.messages(toChild: true).isEmpty)
        XCTAssertEqual(try mailbox.receipt(id: "message", toChild: true), "Keep exact reference ABC123")
        let nextOwner = UUID(); try await context.repository.installOwner(nextOwner)
        do { try await context.repository.saveChildCheckpoint(saved, childID: child.id, owner: context.owner); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        do { try mailbox.post(id: "late", text: "old worker", toChild: true); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }
    func testParentAndChildRestartRetainsResultWorktreeAndWakeReceipt() async throws {
        let (database, context, parent) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: "durable-child-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childWorkspace = root.appending(path: "isolated-writer")
        try FileManager.default.createDirectory(at: childWorkspace, withIntermediateDirectories: false)
        let childID = UUID()
        let worktree = SubagentWorkspaceRecord(jobID: childID, conversationID: parent.conversationID, title: "Writer",
            repositoryRoot: root.path, relativeWorkspace: "", worktreePath: childWorkspace.path, branch: "aim/subagent-fixture", baseCommit: "fixture")
        let workspaces = SQLiteSubagentWorkspaceRepository(database: database)
        try await workspaces.save(worktree)
        var child = try await context.repository.admitChild(DurableSubagent(id: childID, parentExecutionID: parent.id,
            admissionCallID: "delegate-writer", title: "Writer", prompt: "Update fixture", workspacePath: root.path,
            modelID: "fixture", profile: "code", worktree: worktree), owner: context.owner)
        child = try await context.repository.transitionChild(childID, owner: context.owner, expectedRevision: child.revision, to: .running)
        try await context.repository.saveChildCheckpoint(checkpoint("Exact saved result"), childID: childID, owner: context.owner)
        _ = try await context.repository.wait(WakeCondition(executionID: parent.id, kind: .subagent, key: "children"),
            owner: context.owner, expectedRevision: parent.revision)
        let nextOwner = UUID(); try await context.repository.installOwner(nextOwner)
        let next = RuntimeExecutionContext(repository: context.repository, executionID: parent.id, owner: nextOwner)
        let pool = AgentSubagentPool(assignmentRunner: { assignment in
            let saved = try await next.repository.childCheckpoint(try XCTUnwrap(assignment.childID))
            return try XCTUnwrap(saved).turn.text
        }, conversationID: parent.conversationID, workspacePath: root.path,
            writer: SubagentWriterSupport(service: SubagentWorkspaceService(), repository: workspaces, allowCommands: false), executionContext: next)
        try await pool.restoreChildren()
        for _ in 0..<100 {
            if try await next.repository.child(childID).state == .accepted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let finished = try await next.repository.child(childID)
        XCTAssertEqual(finished.state, .accepted); XCTAssertEqual(finished.result, "Exact saved result")
        let retained = try await workspaces.load(jobID: childID)
        XCTAssertEqual(retained?.state, .active); XCTAssertNil(retained?.reviewedPatchSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: childWorkspace.path))
        let payload = try await next.repository.consumeWake(executionID: parent.id, owner: nextOwner)
        XCTAssertNotNil(payload)
        let awakened = try await next.repository.execution(parent.id)
        XCTAssertEqual(awakened?.state, .queued)
        let merge = await pool.execute(ToolRequest(name: "merge_subagent_changes", arguments: ["job_id": childID.uuidString], risk: .localMutation))
        XCTAssertTrue(merge.isError, "An unreviewed worktree cannot merge")
        await pool.close()
    }
    func testWriterAdmissionRejectsParentWorkspaceReuse() async throws {
        let (_, context, parent) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: "unsafe-child-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childID = UUID()
        let shared = SubagentWorkspaceRecord(jobID: childID, conversationID: parent.conversationID, title: "Writer",
            repositoryRoot: root.path, relativeWorkspace: "", worktreePath: root.path, branch: "aim/unsafe-fixture", baseCommit: "fixture")
        do {
            _ = try await context.repository.admitChild(DurableSubagent(id: childID, parentExecutionID: parent.id,
                admissionCallID: "unsafe-writer", title: "Writer", prompt: "Update fixture", workspacePath: root.path,
                modelID: "fixture", profile: "code", worktree: shared), owner: context.owner)
            XCTFail("A writer must not be admitted into its parent's workspace")
        } catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
        let children = try await context.repository.children(parentExecutionID: parent.id)
        XCTAssertTrue(children.isEmpty)
    }
}
