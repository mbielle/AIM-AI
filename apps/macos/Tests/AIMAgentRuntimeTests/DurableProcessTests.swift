import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

final class DurableProcessTests: XCTestCase {
    func testTerminalParentStopsOwnedProcessesWithoutCrashingTickOrRevivingThem() async throws {
        let (_, context, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DurableProcessRegistry()
        let service = try await registry.service(context: context, workspace: directory.path)
        let started = await service.execute(ToolRequest(id: "start", name: "start_command", arguments: ["command": "/bin/sleep 20"], risk: .destructive, workspacePath: directory.path))
        XCTAssertFalse(started.isError)
        let pending = try await registry.pending(context.executionID); XCTAssertNotNil(pending)
        let parent = try await context.repository.execution(context.executionID)
        _ = try await context.repository.transition(context.executionID, owner: context.owner,
            expectedRevision: try XCTUnwrap(parent).revision, to: .cancelled)
        try await registry.tick(); try await registry.tick()
        let receipts = try await context.repository.processes(executionID: context.executionID)
        var receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.state, "stopped")
        receipt.state = "running"; receipt.version += 1
        do { try await context.repository.saveProcess(receipt, owner: context.owner); XCTFail("Terminal process revived") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
        let remaining = try await registry.pending(context.executionID); XCTAssertNil(remaining)
    }
    private func fixture() async throws -> (RuntimeShellService, RuntimeExecutionContext, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-process-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "process", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: database, artifacts: try ExecutionArtifactStore(directory: directory.appending(path: "artifacts")))
        let owner = UUID(); try await repository.installOwner(owner)
        let record = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        _ = try await repository.transition(record.id, owner: owner, expectedRevision: 0, to: .running)
        let context = RuntimeExecutionContext(repository: repository, executionID: record.id, owner: owner)
        let service = RuntimeShellService(context: context, workspace: directory.path)
        try await service.restore()
        return (service, context, directory)
    }
    func testTurnReleaseKeepsProcessAndCompletedReceiptRestoresWithoutReplay() async throws {
        let (service, context, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = await service.execute(ToolRequest(id: "start", name: "start_command",
            arguments: ["command": "/bin/sleep 0.2; printf x >> effects.txt; printf fixture-output"], risk: .destructive, workspacePath: directory.path))
        XCTAssertFalse(started.isError)
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        await service.closeSession()
        var receipt: ToolResult?
        for _ in 0..<100 {
            let value = await service.execute(ToolRequest(id: "read", name: "read_command", arguments: ["handle": handle], risk: .readOnly, workspacePath: directory.path))
            if value.metadata["process_state"] == "completed" { receipt = value; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(receipt?.content.contains("fixture-output") == true)
        let records = try await context.repository.processes(executionID: context.executionID)
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].state, "completed")
        let replacement = RuntimeShellService(context: context, workspace: directory.path)
        try await replacement.restore()
        let restored = await replacement.execute(ToolRequest(id: "restored-read", name: "read_command", arguments: ["handle": handle], risk: .readOnly, workspacePath: directory.path))
        XCTAssertTrue(restored.content.contains("fixture-output")); XCTAssertFalse(restored.isError)
        let reconciled = try await replacement.reconcile(ModelToolCall(id: "start", name: "start_command", arguments: [:]), workspacePath: directory.path)
        XCTAssertEqual(reconciled?.metadata["reconciled_by"], "durable_process_receipt")
        let repeated = await replacement.execute(ToolRequest(id: "start", name: "start_command", arguments: ["command": "printf x >> effects.txt"], risk: .destructive, workspacePath: directory.path))
        XCTAssertEqual(repeated.metadata["process_handle"], handle)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "effects.txt"), encoding: .utf8), "x")
        await service.stop(); await replacement.stop()
    }
    func testActiveProcessAfterOwnerReplacementIsUnknownAndCannotReplay() async throws {
        let (service, context, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = await service.execute(ToolRequest(id: "start", name: "start_command", arguments: ["command": "/bin/sleep 20"], risk: .destructive, workspacePath: directory.path))
        let id = try XCTUnwrap(start.metadata["process_handle"])
        let owner = UUID(); try await context.repository.installOwner(owner)
        let nextContext = RuntimeExecutionContext(repository: context.repository, executionID: context.executionID, owner: owner)
        let replacement = RuntimeShellService(context: nextContext, workspace: directory.path)
        try await replacement.restore()
        let uncertain = await replacement.hasUncertainProcess(); XCTAssertTrue(uncertain)
        let observation = await replacement.execute(ToolRequest(id: "read", name: "read_command", arguments: ["handle": id], risk: .readOnly, workspacePath: directory.path))
        XCTAssertTrue(observation.isError); XCTAssertEqual(observation.metadata["process_state"], "unknown")
        let reconciled = try await replacement.reconcile(ModelToolCall(id: "start", name: "start_command", arguments: [:]), workspacePath: directory.path)
        XCTAssertNil(reconciled)
        let running = try await context.repository.execution(context.executionID)
        _ = try await context.repository.transition(context.executionID, owner: owner, expectedRevision: try XCTUnwrap(running).revision, to: .waitingUser)
        try await context.repository.acknowledgeUncertainProcess(try XCTUnwrap(UUID(uuidString: id)), executionID: context.executionID, owner: owner)
        try await replacement.restore()
        let stillUncertain = await replacement.hasUncertainProcess(); XCTAssertFalse(stillUncertain)
        let inspected = try await replacement.reconcile(ModelToolCall(id: "start", name: "start_command", arguments: [:]), workspacePath: directory.path)
        XCTAssertTrue(inspected?.content.contains("interrupted") == true)
        let records = try await context.repository.processes(executionID: context.executionID)
        let record = try XCTUnwrap(records.first)
        do { try await context.repository.saveProcess(record, owner: context.owner); XCTFail("Old process worker wrote") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        await service.stop(); await replacement.stop()
    }

    func testRestartInterruptedCommandsAreHandedBackToTheAgentWithoutAPerson() async throws {
        let (service, context, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = await service.execute(ToolRequest(id: "start", name: "start_command", arguments: ["command": "/bin/sleep 20"], risk: .destructive, workspacePath: directory.path))
        XCTAssertNotNil(start.metadata["process_handle"])
        let owner = UUID(); try await context.repository.installOwner(owner)
        let nextContext = RuntimeExecutionContext(repository: context.repository, executionID: context.executionID, owner: owner)
        let replacement = RuntimeShellService(context: nextContext, workspace: directory.path)
        try await replacement.restore()
        let uncertain = await replacement.hasUncertainProcess(); XCTAssertTrue(uncertain)
        // The task is still running: AIM records the stop itself and the agent carries on.
        let count = try await context.repository.interruptUnknownProcesses(executionID: context.executionID, owner: owner)
        XCTAssertEqual(count, 1)
        try await replacement.restore()
        let after = await replacement.hasUncertainProcess(); XCTAssertFalse(after)
        let state = try await context.repository.execution(context.executionID)?.state
        XCTAssertEqual(state, .running)
        await service.stop(); await replacement.stop()
    }

    func testExternalEnginesReceiveTheConversationSoFar() {
        let id = UUID(), source = UUID()
        let messages = [
            ConversationMessage(conversationID: id, role: .user, content: "Find the Jev release date.", sequence: 0),
            ConversationMessage(conversationID: id, role: .assistant, content: "It was released on 15 September 2026.", sequence: 1),
            ConversationMessage(id: source, conversationID: id, role: .user, content: "And who funded it?", sequence: 2)
        ]
        let preface = try? XCTUnwrap(RuntimeExternalEngineDriver.historyPreface(messages, before: source))
        XCTAssertTrue(preface?.contains("Person: Find the Jev release date.") == true)
        XCTAssertTrue(preface?.contains("You (earlier answer): It was released on 15 September 2026.") == true)
        XCTAssertFalse(preface?.contains("And who funded it?") == true, "the new message is sent separately")
        XCTAssertNil(RuntimeExternalEngineDriver.historyPreface([messages[2]], before: source))
        let long = (0..<50).map { ConversationMessage(conversationID: id, role: .user, content: String(repeating: "x", count: 2_000) + "#\($0)", sequence: $0) }
        let bounded = RuntimeExternalEngineDriver.historyPreface(long, before: nil, limit: 10_000) ?? ""
        XCTAssertTrue(bounded.contains("#49") && !bounded.contains("#10\n") && bounded.contains("[Older messages omitted.]"))
    }
}
