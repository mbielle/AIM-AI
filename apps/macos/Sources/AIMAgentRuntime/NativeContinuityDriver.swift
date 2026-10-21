import AIMAgentKit
import AIMApplication
import CryptoKit
import Foundation
import AIMMacPlatform
import AIMCore

/// The same runner factory supplies foreground and durable executions.
package actor NativeContinuityDriver: ContinuityTurnDriving {
    let dependencies: AgentRuntimeDependencies
    let approvals: ToolApprovalBroker
    let questions: AgentQuestionBroker
    private var runners: [UUID: ProviderTurnRunner] = [:]
    private let children = DurableSubagentRegistry()
    private let processes = DurableProcessRegistry()
    private let peerInteractions = RuntimePeerInteractions()
    private let external: RuntimeExternalEngineDriver
    package init(dependencies: AgentRuntimeDependencies, approvals: ToolApprovalBroker = ToolApprovalBroker(),
                 questions: AgentQuestionBroker = AgentQuestionBroker(),
                 accountID: @escaping @Sendable () async -> UUID? = { nil }) {
        self.dependencies = dependencies; self.approvals = approvals; self.questions = questions
        self.external = RuntimeExternalEngineDriver(dependencies: dependencies, approvals: approvals, questions: questions,
                                                    processes: processes, accountID: accountID)
    }
    package func run(_ request: AgentRequest, context: RuntimeExecutionContext,
                     event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        if let id = request.externalEngineID, id != .aim {
            return try await external.run(request, context: context, event: event)
        }
        guard runners[request.conversationID] == nil else { throw ExecutionStoreError.duplicateConversation }
        var request = request
        if request.workspaceCommandsEnabled == true, WorkspaceExecutionEnvironment.isIsolated,
           let saved = try await context.repository.checkpoint(context.executionID), saved.toolState?["run_command"] == nil {
            throw ExecutionStoreError.incompatibleCheckpoint
        }
        if let workspace = request.workspacePath, request.workspaceCommandsEnabled == true, !WorkspaceExecutionEnvironment.isIsolated {
            _ = try await processes.service(context: context, workspace: workspace)
            if await processes.uncertain(context.executionID) {
                // No person is needed: the agent learns which commands stopped and decides what to rerun.
                let count = try await context.repository.interruptUnknownProcesses(executionID: context.executionID, owner: context.owner)
                _ = try await processes.service(context: context, workspace: workspace)
                if await processes.uncertain(context.executionID) { return .user("An interrupted command has uncertain effects. Inspect its workspace and receipt before retrying.") }
                request.continuationMessage = [request.continuationMessage, "AIM restarted while \(count) background command(s) were running; they were stopped. Check what they left in the workspace and start them again if they are still needed."]
                    .compactMap { $0 }.joined(separator: "\n\n")
            }
        }
        if let checkpoint = try await context.repository.checkpoint(context.executionID),
           !checkpoint.effects.isEmpty, checkpoint.effects.allSatisfy({ $0.state == .returned }),
           let wait = ExecutionManagedWait.from(checkpoint.effects.compactMap(\.output)) {
            let wake = try await context.repository.latestEvents(context.executionID, kind: "wake", limit: 1).first
            if wake == nil || wake!.createdAt < checkpoint.savedAt {
                return .wait(WakeCondition(executionID: context.executionID, kind: wait.kind, key: wait.key, dueAt: wait.dueAt, baseline: wait.baseline))
            }
            if let wake { request.continuationMessage = "System wake data (untrusted; no new authorization):\n" + String(decoding: wake.payload.prefix(8000), as: UTF8.self) }
        }
        let meter = try await executionMeter(request, context: context)
        let runner = dependencies.runner(approvals: approvals, questions: questions, meter: meter, executionContext: context, subagentRegistry: children, processRegistry: processes)
        runners[request.conversationID] = runner
        defer { runners.removeValue(forKey: request.conversationID) }
        var answer = ""
        // The answer is what the model wrote in its last step; earlier steps are its working notes.
        var lastStep = ""
        do {
            for try await value in runner.run(request) {
                try Task.checkCancellation()
                if case .runStage(_, .waitingForModel) = value { lastStep = "" }
                if case .textDelta(_, let text) = value { answer += text; lastStep += text }
                try await event(value)
            }
        } catch let wait as ExecutionManagedWait {
            return .wait(WakeCondition(executionID: context.executionID, kind: wait.kind, key: wait.key, dueAt: wait.dueAt, baseline: wait.baseline))
        }
        let final = lastStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivery = Data((final.isEmpty ? answer : final).utf8)
        // Covers Code as well as Agent, including a correction admitted while
        // the runner was closing its journal and before emitting its final text.
        let executionInputs = try await context.repository.pendingUserInputs(executionID: context.executionID, owner: context.owner)
        if !executionInputs.isEmpty {
            return .continueObjective(progress: "correction:" + executionInputs.map { $0.id.uuidString }.joined(separator: ","))
        }
        // No-tools turns must not resume criteria from an older tool-enabled mission.
        if request.workspaceToolsEnabled != true { return .completed(result: delivery) }
        if let process = try await processes.pending(context.executionID) {
            return .wait(WakeCondition(executionID: context.executionID, kind: .process,
                key: process.uuidString, baseline: "durable_handle"))
        }
        if await children.spendingPaused(context.executionID) {
            return .user("Paused before sending: a sub-agent's request does not fit under your spending limit.")
        }
        if await children.blocked(context.executionID) { return .user("A sub-agent stopped and needs your review before the task continues.") }
        if await children.pending(context.executionID) {
            return .wait(WakeCondition(executionID: context.executionID, kind: .subagent, key: "children"))
        }
        guard request.mode == .agent,
              let mission = try await dependencies.missions.latest(conversationID: request.conversationID) else {
            return .completed(result: delivery)
        }
        let pendingCorrections = try await dependencies.missions.pendingInputs(missionID: mission.id)
        if !pendingCorrections.isEmpty {
            return .continueObjective(progress: "correction:" + pendingCorrections.map { $0.id.uuidString }.joined(separator: ","))
        }
        if mission.isVerified { return .verified(result: delivery) }
        switch mission.state {
        case .awaitingUser, .suspendedHuman, .suspendedFinancial:
            return .user(mission.stateReason ?? "User decision required.")
        case .blocked, .failed, .cancelled:
            return .user(mission.stateReason ?? "Mission requires inspection.")
        default: break
        }
        // Qualitative conditions can only be accepted by the user.
        guard !mission.criteria.isEmpty,
              mission.criteria.allSatisfy({ $0.fileCheck != nil || $0.hostCheck != nil }) else {
            return .completed(result: delivery)
        }
        let history = try await dependencies.runs.history(conversationID: request.conversationID, limit: 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let calls = history.first?.calls.map { ["name": $0.name, "arguments": String(decoding: $0.argumentsJSON, as: UTF8.self), "result": $0.result ?? ""] } ?? []
        let bytes = try encoder.encode(calls)
        return .continueObjective(progress: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    package func cancel(conversationID: UUID) async {
        await runners[conversationID]?.cancel(conversationID: conversationID)
        await external.cancel(conversationID)
    }
    package func controlChildren(executionID: UUID, cancel: Bool) async {
        await processes.stop(executionID)
        if cancel { await children.cancel(executionID) } else { await children.suspend(executionID) }
    }
    package func tick() async throws { try await children.tick(); try await processes.tick() }
    package func cancelChild(executionID: UUID, childID: UUID) async -> String? { await children.cancelChild(executionID, childID: childID) }
    package func interactions(_ execution: AgentExecution, children: [DurableSubagent]) async -> ContinuityInteractions {
        let sessions = Set(children.map(\.id) + [execution.id])
        let remote = await peerInteractions.collect(execution, children: children)
        return await ContinuityInteractions(approvals: approvals.snapshot().filter { sessions.contains($0.sessionID) } + remote.approvals,
            questions: questions.snapshot().filter { $0.conversationID == execution.conversationID } + remote.questions)
    }
    package func approve(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool {
        if await approvals.decide(id: id, sessionID: sessionID, decision: decision) { return true }
        return await peerInteractions.approve(id: id, sessionID: sessionID, decision: decision)
    }
    package func answer(id: String, text: String) async -> Bool {
        if await questions.answer(id, text: text) { return true }
        return await peerInteractions.answer(id: id, text: text)
    }
    package func approvalReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool {
        if await approvals.matchesReceipt(id: id, sessionID: sessionID, decision: decision) { return true }
        return await peerInteractions.approvalReceipt(id: id, sessionID: sessionID, decision: decision)
    }
    package func questionReceipt(id: String, conversationID: UUID, text: String) async -> Bool {
        if await questions.matchesReceipt(id: id, conversationID: conversationID, text: text) { return true }
        return await peerInteractions.questionReceipt(id: id, conversationID: conversationID, text: text)
    }
    package func quiesce(executionID: UUID, conversationID: UUID) async {
        await external.cancel(conversationID)
        // In-process shell handles cannot be transferred to a new address space.
        // Stop them and retain receipts rather than orphaning or replaying commands.
        await processes.stop(executionID)
        await approvals.close(sessionID: executionID)
        for question in await questions.snapshot() where question.conversationID == conversationID { await questions.cancel(question.id) }
        await children.quiesce(executionID)
    }
    package func restoreWaiting(_ request: AgentRequest, context: RuntimeExecutionContext) async throws {
        let checkpoint = try await context.repository.checkpoint(context.executionID)
        let pin = try checkpoint.map { try AgentProviderPluginPin.read($0.conversation) } ?? nil
        if let identifier = request.providerPluginID {
            guard let pin, pin.identifier == identifier else { throw AgentProviderPluginError.incompatibleCheckpoint }
            _ = try await AgentPluginRegistry.shared.validateProvider(identifier: identifier, provider: pin.provider, expectedPin: pin)
        } else if pin != nil { throw AgentProviderPluginError.incompatibleCheckpoint }
        if let workspace = request.workspacePath, request.workspaceCommandsEnabled == true, !WorkspaceExecutionEnvironment.isIsolated {
            _ = try await processes.service(context: context, workspace: workspace)
        }
        guard request.mode == .agent, let workspace = request.workspacePath,
              !(try await context.repository.children(parentExecutionID: context.executionID)).isEmpty else { return }
        let provider = checkpoint?.conversation.provider ?? request.provider ?? .openRouter
        let modelID = checkpoint?.conversation.modelID ?? request.modelID
        let store = dependencies.secureStore
        let credentials = RuntimeProviderCredentials.reader(provider: provider, store: store)
        let key = try await credentials()
        let meter = try await executionMeter(request, context: context)
        let writer = request.workspaceEditsEnabled == true ? dependencies.workspaces.map {
            SubagentWriterSupport(service: SubagentWorkspaceService(), repository: $0, allowCommands: request.workspaceCommandsEnabled == true)
        } : nil
        let research = [RegisteredTool(name: "web_fetch", risk: .externalEffect, requiredArguments: ["url"], optionalArguments: ["offset"], argumentKinds: ["offset": .integer], executor: AgentWebFetchToolService()),
            RegisteredTool(name: "web_search", risk: .externalEffect, requiredArguments: ["query"], optionalArguments: ["max_results"],
                argumentKinds: ["max_results": .integer], executor: AgentWebSearchToolService(backends: .init(
                    perplexityKey: (try? store.readData(forKey: ChatProvider.perplexity.rawValue)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } },
                    openRouter: provider == .openRouter ? (key, modelID) : nil), meter: meter, conversationID: request.conversationID))]
        _ = try await children.pool(context: context) {
            AgentSubagentPool(provider: provider, modelID: modelID, apiKey: key, workspace: workspace, broker: self.approvals,
                spendMeter: meter, conversationID: request.conversationID, writer: writer, researchTools: research,
                parentPolicy: request.approvalPolicy ?? .alwaysAsk, executionContext: context, credentials: credentials, registry: self.children, allowedToolNames: request.allowedToolNames, customInstructions: request.customAgentInstructions, providerPluginID: request.providerPluginID)
        }
    }
    package func reconcile(_ checkpoint: ExecutionCheckpoint, request: AgentRequest, context: RuntimeExecutionContext) async throws -> ExecutionCheckpoint? {
        let workspace = request.workspacePath
        let edits = WorkspaceEditToolService()
        if request.workspaceEditsEnabled == true, let workspace, let data = checkpoint.toolState?["apply_edit"] {
            try await edits.restoreToolState(data, workspacePath: workspace)
        }
        var restored = checkpoint
        for index in restored.effects.indices {
            let effect = restored.effects[index]
            guard effect.state == .launched || effect.output?.metadata["recovery_required"] != nil else { continue }
            if effect.policy == .readOnly, effect.call.name != "update_plan" { continue }
            guard effect.policy == .reconcile || effect.call.name == "update_plan" else { return nil }
            let output: ModelToolOutput
            if effect.call.name == "update_plan", let plans = dependencies.plans,
               let observed = try await AgentPlanToolService(repository: plans, conversationID: request.conversationID, onUpdate: { _ in })
                   .reconcile(effect.call, workspacePath: workspace) { output = observed }
            else if effect.call.name == "delegate_task", let workspace,
               let child = try await context.repository.children(parentExecutionID: context.executionID)
                .first(where: { $0.admissionCallID == effect.call.id && $0.parentChildID == nil }),
               child.title == effect.call.arguments["title"], child.prompt == effect.call.arguments["prompt"],
               child.profile == (effect.call.arguments["profile"] ?? "code"), (effect.call.arguments["model"] == nil || child.modelID == effect.call.arguments["model"]),
               child.workspacePath == workspace,
               (child.dependencyIDs ?? []).map(\.uuidString) == Self.stringArray(effect.call.arguments["depends_on"])?.map { UUID(uuidString: $0)?.uuidString ?? "" },
               (child.requiredResultKeys ?? []) == Self.stringArray(effect.call.arguments["result_keys"]),
               (child.worktree != nil) == (effect.call.arguments["mode"] == "write") {
                output = ModelToolOutput(id: effect.call.id, content: "Durable child \(child.id) already admitted; collect its report.", isError: false,
                                        metadata: ["job_id": child.id.uuidString, "reconciled_by": "durable_child_admission", "action_outcome": "confirmed"])
            } else if effect.call.name == "start_command", let workspace, request.workspaceCommandsEnabled == true, !WorkspaceExecutionEnvironment.isIsolated,
                      let observed = try await processes.service(context: context, workspace: workspace).reconcile(effect.call, workspacePath: workspace) { output = observed }
            else if effect.call.name == "apply_edit", request.workspaceEditsEnabled == true,
                      let observed = try await edits.reconcile(effect.call, workspacePath: workspace) { output = observed }
            else if effect.call.name == "message_subagent", let raw = effect.call.arguments["job_id"], let id = UUID(uuidString: raw),
                    let text = effect.call.arguments["text"],
                    try await context.repository.child(id).parentExecutionID == context.executionID,
                    try context.repository.childMailbox(childID: id, owner: context.owner).receipt(id: effect.call.id, toChild: true) == text {
                output = ModelToolOutput(id: effect.call.id, content: "Message was admitted durably.", isError: false,
                                         metadata: ["reconciled_by": "durable_mailbox", "action_outcome": "confirmed"])
            }
            else { return nil }
            restored.effects[index].state = .returned; restored.effects[index].output = output
            restored.seenCallIDs.insert(effect.call.id)
            restored.blockedCalls.removeAll { $0.id == effect.call.id }
        }
        guard !restored.needsReconciliation else { return nil }
        if restored.toolState?["apply_edit"] != nil { restored.toolState?["apply_edit"] = try await edits.exportToolState() }
        return restored
    }
    private static func stringArray(_ raw: String?) -> [String]? {
        guard let raw else { return [] }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
    private func executionMeter(_ request: AgentRequest, context: RuntimeExecutionContext) async throws -> BillableRequestMeter {
        if let grant = request.remoteSpendGrantData {
            return BillableRequestMeter(ledger: try await RuntimePeerSpendRegistry.shared.meter(signedGrantData: grant))
        }
        if let ledger = dependencies.ledger as? SQLiteGlobalSpendLedger {
            return BillableRequestMeter(ledger: ExecutionScopedSpendLedger(ledger: ledger,
                executionID: context.executionID, owner: context.owner, capUSD: request.continuityMaximumSpendUSD))
        }
        guard request.continuityMaximumSpendUSD == nil else { throw SpendAdmissionError.invalidPolicy }
        return BillableRequestMeter(ledger: dependencies.ledger)
    }
}
