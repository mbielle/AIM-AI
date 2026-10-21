import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

package enum ContinuityTurnOutcome: Sendable {
    case verified(result: Data)
    case completed(result: Data)
    case continueObjective(progress: String)
    case wait(WakeCondition)
    case user(String)
}

package protocol ContinuityTurnDriving: Sendable {
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome
    func cancel(conversationID: UUID) async
    func reconcile(_ checkpoint: ExecutionCheckpoint, request: AgentRequest, context: RuntimeExecutionContext) async throws -> ExecutionCheckpoint?
    func controlChildren(executionID: UUID, cancel: Bool) async
    /// Stops one running child at the person's request; nil when accepted.
    func cancelChild(executionID: UUID, childID: UUID) async -> String?
    func tick() async throws
    func restoreWaiting(_ request: AgentRequest, context: RuntimeExecutionContext) async throws
    func interactions(_ execution: AgentExecution, children: [DurableSubagent]) async -> ContinuityInteractions
    func approve(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool
    func answer(id: String, text: String) async -> Bool
    func approvalReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool
    func questionReceipt(id: String, conversationID: UUID, text: String) async -> Bool
    func quiesce(executionID: UUID, conversationID: UUID) async
}
extension ContinuityTurnDriving {
    func reconcile(_ checkpoint: ExecutionCheckpoint, request: AgentRequest, context: RuntimeExecutionContext) async throws -> ExecutionCheckpoint? { nil }
    func controlChildren(executionID: UUID, cancel: Bool) async {}
    func cancelChild(executionID: UUID, childID: UUID) async -> String? { "Unknown sub-agent ID." }
    func tick() async throws {}
    func restoreWaiting(_ request: AgentRequest, context: RuntimeExecutionContext) async throws {}
    func interactions(_ execution: AgentExecution, children: [DurableSubagent]) async -> ContinuityInteractions { ContinuityInteractions(approvals: [], questions: []) }
    func approve(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool { false }
    func answer(id: String, text: String) async -> Bool { false }
    func approvalReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool { false }
    func questionReceipt(id: String, conversationID: UUID, text: String) async -> Bool { false }
    func quiesce(executionID: UUID, conversationID: UUID) async {}
}

/// Admission is durable; workers belong to this actor. Closing a subscriber has no effect.
package actor RunCoordinator {
    private let repository: SQLiteAgentExecutionRepository
    private let driver: any ContinuityTurnDriving
    private let lease: RuntimeLease
    private let authorized: @Sendable (UUID?) async -> Bool
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var maximumRoots: Int
    private var started = false
    private var stopping = false
    private var pumping = false
    private var pumpRequested = false
    private var resources: [UUID: Set<String>] = [:]
    private var remoteSessionReservations: Set<UUID> = []
    private var admissionsInFlight: Set<UUID> = []
    private struct RemoteOperation: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var remoteOperations: [UUID: RemoteOperation] = [:]
    private func stopRemoteOperations() async {
        let pending = Array(remoteOperations.values)
        for item in pending { item.cancel() }
        for item in pending { await item.wait() }
    }
    package var isActive: Bool { started && !stopping }

    package init(repository: SQLiteAgentExecutionRepository, driver: any ContinuityTurnDriving,
                 lease: RuntimeLease, maximumRoots: Int = 2,
                 authorized: @escaping @Sendable (UUID?) async -> Bool) {
        self.repository = repository; self.driver = driver; self.lease = lease
        self.maximumRoots = max(1, maximumRoots); self.authorized = authorized
    }

    package func start() async throws {
        guard !started, !stopping else { return }
        try await repository.installOwner(lease.generation)
        try await repository.resumeTransferred(owner: lease.generation)
        started = true
        for record in try await repository.list(states: [.running, .queued]) {
            if record.state == .running {
                do {
                    var checkpoint = try await repository.checkpoint(record.id)
                    if let pending = checkpoint, pending.needsReconciliation, await authorized(record.accountID),
                       let observed = try await driver.reconcile(pending, request: JSONDecoder().decode(AgentRequest.self, from: record.request),
                            context: RuntimeExecutionContext(repository: repository, executionID: record.id, owner: lease.generation)) {
                        _ = try await repository.saveCheckpoint(observed, executionID: record.id, owner: lease.generation,
                            expectedRevision: record.revision)
                        checkpoint = observed
                    }
                    // Without any checkpoint the turn stopped before its first action: nothing was changed,
                    // but a model request may have been billed. It waits for the person; nothing is resent.
                    let state: ExecutionState = checkpoint == nil ? .waitingUser : checkpoint!.needsReconciliation ? .blocked : .queued
                    guard let current = try await repository.execution(record.id) else { throw ExecutionStoreError.notFound }
                    _ = try await repository.transition(record.id, owner: lease.generation,
                        expectedRevision: current.revision, to: state,
                        reason: state == .blocked ? "Interrupted effect requires reconciliation."
                            : state == .waitingUser ? "Interrupted before any action. Nothing was changed." : nil)
                } catch {
                    guard let current = try await repository.execution(record.id) else { throw ExecutionStoreError.notFound }
                    _ = try await repository.transition(record.id, owner: lease.generation,
                        expectedRevision: current.revision, to: .blocked, reason: "Checkpoint recovery refused; no effect replayed: \(String(describing: error))")
                }
            }
        }
        // Tasks paused only because AIM was closed continue on their own.
        for record in try await repository.list(states: [.paused]) where record.reason == Self.closedReason {
            try? await resume(record.id)
        }
        try await tick(at: .now)
    }

    package func admit(commandID: UUID, accountID: UUID?, request: AgentRequest, executionID: UUID? = nil) async throws -> AgentExecution {
        guard started, !stopping, await authorized(accountID),
              request.mode != .chat else { throw ExecutionStoreError.invalidTransition }
        guard !remoteSessionReservations.contains(request.conversationID),
              admissionsInFlight.insert(request.conversationID).inserted else { throw ExecutionStoreError.duplicateConversation }
        defer { admissionsInFlight.remove(request.conversationID) }
        if let turns = request.continuityMaximumTurns, turns <= 0 { throw ExecutionStoreError.invalidTransition }
        if let cap = request.continuityMaximumSpendUSD {
            guard let amount = Decimal(string: cap, locale: Locale(identifier: "en_US_POSIX")),
                  !amount.isNaN, amount > 0 else { throw ExecutionStoreError.invalidTransition }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(request)
        let record = try await repository.admit(AgentExecution(id: executionID ?? UUID(), commandID: commandID,
            conversationID: request.conversationID, accountID: accountID, request: data), owner: lease.generation,
            initialMessageID: request.sourceMessageID, initialText: request.text)
        try await AccountRuntimeActivity.begin(record, request: request, repository: repository)
        try await pump()
        return record
    }

    package func snapshot(_ id: UUID) async throws -> AgentExecution? {
        guard let record = try await repository.execution(id) else { return nil }
        guard await authorized(record.accountID) else { throw ExecutionStoreError.invalidTransition }; return record
    }
    package func list() async throws -> [AgentExecution] {
        var result: [AgentExecution] = []
        for record in try await repository.list() where await authorized(record.accountID) { result.append(record) }
        return result
    }
    package func control(commandID: UUID, id: UUID, action: String, text: String? = nil, sourceMessageID: UUID? = nil) async throws -> AgentExecution {
        let existing = try await require(id)
        guard await authorized(existing.accountID) else { throw ExecutionStoreError.invalidTransition }
        let receipt = try await repository.control(commandID: commandID, executionID: id, action: action, text: text, sourceMessageID: sourceMessageID, owner: lease.generation)
        if action == "pause" || action == "cancel" {
            workers[id]?.cancel(); await driver.cancel(conversationID: existing.conversationID)
            await driver.controlChildren(executionID: id, cancel: action == "cancel")
            await workers[id]?.value
        }
        try await pump()
        return receipt
    }
    /// The person stops one sub-agent of this execution. A child no pool is running is
    /// cancelled in the store directly; an already finished child is left unchanged.
    package func cancelChild(executionID: UUID, childID: UUID) async throws {
        let record = try await require(executionID)
        guard await authorized(record.accountID) else { throw ExecutionStoreError.invalidTransition }
        let child = try await repository.child(childID)
        guard child.parentExecutionID == executionID else { throw ExecutionStoreError.invalidTransition }
        guard !child.state.isTerminal else { return }
        if await driver.cancelChild(executionID: executionID, childID: childID) == nil { return }
        _ = try await repository.transitionChild(childID, owner: lease.generation, expectedRevision: child.revision, to: .cancelled, result: "Cancelled by you.")
    }
    package func interactions(_ id: UUID) async throws -> ContinuityInteractions {
        let record = try await require(id)
        guard await authorized(record.accountID) else { throw ExecutionStoreError.invalidTransition }
        let childRecords = try await repository.children(parentExecutionID: id)
        return await driver.interactions(record, children: childRecords)
    }
    package func approve(executionID: UUID, id: UUID, sessionID: UUID, decision: ApprovalDecision) async throws {
        let pending = try await interactions(executionID)
        let sessions = Set(try await repository.children(parentExecutionID: executionID).map(\.id) + [executionID])
        guard sessions.contains(sessionID) else { throw ExecutionStoreError.invalidTransition }
        if await driver.approvalReceipt(id: id, sessionID: sessionID, decision: decision) { return }
        guard pending.approvals.contains(where: { $0.id == id && $0.sessionID == sessionID }),
              await driver.approve(id: id, sessionID: sessionID, decision: decision) else { throw ExecutionStoreError.invalidTransition }
    }
    package func answer(executionID: UUID, id: String, text: String) async throws {
        let pending = try await interactions(executionID)
        let record = try await require(executionID)
        if await driver.questionReceipt(id: id, conversationID: record.conversationID, text: text) { return }
        guard pending.questions.contains(where: { $0.id == id }), await driver.answer(id: id, text: text) else {
            throw ExecutionStoreError.invalidTransition
        }
    }
    package func eventCursor(_ id: UUID) async throws -> Int64 {
        guard let _ = try await snapshot(id) else { throw ExecutionStoreError.notFound }
        return try await repository.eventCursor(id)
    }
    package func processes(_ id: UUID) async throws -> [DurableProcess] {
        guard let _ = try await snapshot(id) else { throw ExecutionStoreError.notFound }
        return try await repository.processes(executionID: id).map { value in var value = value; value.payload = Data(); return value }
    }
    package func acknowledgeProcess(_ id: UUID, processID: UUID) async throws {
        guard let _ = try await snapshot(id) else { throw ExecutionStoreError.notFound }
        try await repository.acknowledgeUncertainProcess(processID, executionID: id, owner: lease.generation)
    }
    package func projectActivity(_ messages: [ConversationMessage]) async throws -> [ConversationMessage] {
        try await RuntimeConversationActivity.apply(repository: repository, to: messages)
    }
    package func events(_ id: UUID, after: Int64) async throws -> [ExecutionEvent] {
        guard let _ = try await snapshot(id) else { throw ExecutionStoreError.notFound }
        return try await repository.events(id, after: after)
    }
    package func configure(maximumRoots: Int) async throws {
        guard maximumRoots > 0 else { throw ExecutionStoreError.invalidTransition }
        self.maximumRoots = maximumRoots; try await pump()
    }

    /// Remote operations use the same resource ownership as workers. Session
    /// reservations are installed before any await so admission cannot race deletion.
    package func withRemoteResources<T: Sendable>(workspace: String?, desktop: Bool,
        conversationID: UUID? = nil, mutatingSession: Bool = false,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard started, !stopping else { throw ExecutionStoreError.invalidTransition }
        var required: Set<String> = desktop ? ["desktop"] : []
        if let workspace {
            required.insert("workspace:" + URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        guard resources.values.allSatisfy({ $0.isDisjoint(with: required) }) else { throw ExecutionStoreError.invalidTransition }
        if mutatingSession {
            guard let conversationID, !admissionsInFlight.contains(conversationID),
                  remoteSessionReservations.insert(conversationID).inserted else { throw ExecutionStoreError.duplicateConversation }
        }
        let reservation = UUID()
        resources[reservation] = required
        defer {
            remoteOperations.removeValue(forKey: reservation)
            resources.removeValue(forKey: reservation)
            if mutatingSession, let conversationID { remoteSessionReservations.remove(conversationID) }
            Task { try? await self.pump() }
        }
        if mutatingSession, let conversationID {
            guard !(try await repository.list()).contains(where: { $0.conversationID == conversationID && !$0.state.isTerminal }) else {
                throw ExecutionStoreError.duplicateConversation
            }
        }
        try Task.checkCancellation()
        guard started, !stopping else { throw ExecutionStoreError.invalidTransition }
        let task = Task { try await operation() }
        remoteOperations[reservation] = RemoteOperation(cancel: { task.cancel() }, wait: { _ = try? await task.value })
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The reason given to tasks paused because AIM was closed; they resume when it reopens.
    package static let closedReason = "Paused because AIM was closed."

    /// What stopped a run, in words the person can act on.
    static func plainReason(_ error: Error) -> String {
        switch error {
        case ModelToolError.repeatedFailures: return "The agent kept repeating actions that failed. Resume to let it try another approach."
        case ModelToolError.limitReached: return "This step grew too large to send, even after compacting. Resume to continue from a summary."
        case ModelToolError.invalidProtocol: return "The provider kept sending answers AIM could not use, even after retrying. Resume to try again."
        case let ChatServiceError.http(status): return "The provider returned an error (HTTP \(status)) after several retries. Resume to try again."
        case is URLError: return "The connection to the provider was lost after several retries. Resume to try again."
        default:
            let detail = String(String(describing: error).prefix(160))
            return "The task stopped on an unexpected error (\(detail)). Resume to try again."
        }
    }

    package func pause(_ id: UUID, reason: String = "Paused by user.") async throws {
        let record = try await require(id)
        guard !record.state.isTerminal else { throw ExecutionStoreError.invalidTransition }
        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                                          to: .paused, reason: reason)
        workers[id]?.cancel(); await driver.cancel(conversationID: record.conversationID)
        await driver.controlChildren(executionID: id, cancel: false)
        await workers[id]?.value
    }
    package func cancel(_ id: UUID) async throws {
        let record = try await require(id)
        guard !record.state.isTerminal else { throw ExecutionStoreError.invalidTransition }
        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                                          to: .cancelled, reason: "Cancelled by user.")
        workers[id]?.cancel(); await driver.cancel(conversationID: record.conversationID)
        await driver.controlChildren(executionID: id, cancel: true)
        await workers[id]?.value
    }
    package func resume(_ id: UUID) async throws {
        let record = try await require(id)
        guard [.paused, .waitingUser].contains(record.state), await authorized(record.accountID) else {
            throw ExecutionStoreError.invalidTransition
        }
        if let checkpoint = try await repository.checkpoint(id), checkpoint.needsReconciliation {
            _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                to: .blocked, reason: "Uncertain effect must be reconciled before resuming.")
            return
        }
        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision, to: .queued)
        try await pump()
    }
    package func accept(_ id: UUID) async throws {
        let record = try await require(id)
        guard record.state == .awaitingReview, await authorized(record.accountID) else {
            throw ExecutionStoreError.invalidTransition
        }
        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                                          to: .accepted, reason: "Result accepted by user; not host-verified.")
    }

    /// Event payloads never change account, scopes or model configuration.
    package func wake(_ id: UUID, key: String, payload: Data) async throws {
        _ = try await repository.enqueueWake(executionID: id, dedupKey: key, payload: payload, owner: lease.generation)
        _ = try await repository.consumeWake(executionID: id, owner: lease.generation)
        try await pump()
    }
    package func tick(at date: Date) async throws {
        guard started, !stopping else { return }
        for record in try await repository.list(states: [.waitingEvent, .waitingNetwork]) {
            if !(await authorized(record.accountID)) { try await pause(record.id); continue }
            do {
                try await ProfileScopedCredentialStore.$requiredOwnerID.withValue(record.accountID) {
                    try await driver.restoreWaiting(JSONDecoder().decode(AgentRequest.self, from: record.request),
                        context: RuntimeExecutionContext(repository: repository, executionID: record.id, owner: lease.generation))
                }
            } catch {
                let current = try await require(record.id)
                _ = try await repository.transition(record.id, owner: lease.generation, expectedRevision: current.revision,
                    to: .blocked, reason: "Waiting child recovery refused: \(String(describing: error))")
            }
        }
        try await driver.tick()
        // Only tasks still under way change; a finished one was measured when it settled. Measuring
        // every task ever run on each tick rewrote them all and flooded the account sync (Round 36).
        // A task waiting for the person or blocked changes only when it resumes or ends (both refresh it).
        for root in try await repository.list() where [.queued, .running].contains(root.state) {
            // Statistics errors never authorize or restart a task. Its journal remains available for a retry.
            try? await AccountRuntimeActivity.refresh(root, repository: repository, now: date)
        }
        for condition in try await repository.dueConditions(at: date) {
            let key = "deadline:\(condition.id):\(condition.dueAt?.timeIntervalSince1970 ?? 0)"
            _ = try await repository.enqueueWake(executionID: condition.executionID, dedupKey: key,
                payload: try JSONEncoder().encode(condition), owner: lease.generation, at: date)
        }
        for record in try await repository.list(states: [.waitingEvent, .waitingNetwork]) {
            _ = try await repository.consumeWake(executionID: record.id, owner: lease.generation, at: date)
        }
        try await pump()
    }
    package func shutdown() async throws {
        stopping = true
        await stopRemoteOperations()
        // Only active tasks pause; one already waiting for the person keeps its own decision.
        for record in try await repository.list(states: [.queued, .running, .waitingEvent, .waitingNetwork]) {
            try await pause(record.id, reason: Self.closedReason)
        }
        for task in workers.values { task.cancel() }
        for task in workers.values { await task.value }
        workers.removeAll(); started = false; lease.release()
    }
    package func relinquishForTransfer() async throws {
        stopping = true
        await stopRemoteOperations()
        let transferred = try await repository.list(states: [.queued, .running, .waitingEvent, .waitingNetwork])
        for record in transferred {
            try await repository.requestTransfer(record.id, owner: lease.generation)
        }
        for record in transferred { await driver.quiesce(executionID: record.id, conversationID: record.conversationID) }
        let currentWorkers = Array(workers.values)
        for task in currentWorkers { await task.value }
        guard try await repository.list(states: [.running]).isEmpty else { throw ExecutionStoreError.invalidTransition }
        started = false; lease.release()
    }
    package func suspendUnauthorized() async throws {
        for record in try await repository.list(states: [.running, .queued, .waitingEvent, .waitingNetwork, .waitingUser]) {
            if !(await authorized(record.accountID)) { try await pause(record.id) }
        }
    }
    package func suspendAllForLogout() async throws {
        await stopRemoteOperations()
        for record in try await repository.list(states: [.running, .queued, .waitingEvent, .waitingNetwork, .waitingUser]) {
            try await pause(record.id)
        }
    }

    private func require(_ id: UUID) async throws -> AgentExecution {
        guard started,
              let record = try await repository.execution(id) else { throw ExecutionStoreError.notFound }
        return record
    }
    private func pump() async throws {
        guard started, !stopping else { return }
        pumpRequested = true
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while pumpRequested, !stopping {
        pumpRequested = false
        for record in try await repository.list(states: [.queued]) {
            guard !stopping else { break }
            guard workers.count < maximumRoots else { break }
            guard workers[record.id] == nil else { continue }
            guard !remoteSessionReservations.contains(record.conversationID) else { continue }
            guard await authorized(record.accountID) else {
                _ = try await repository.transition(record.id, owner: lease.generation, expectedRevision: record.revision,
                    to: .paused, reason: "Account access suspended.")
                continue
            }
            // Re-fetch after suspension points; another actor command may have paused it.
            guard let current = try await repository.execution(record.id), current.state == .queued,
                  workers[record.id] == nil, workers.count < maximumRoots,
                  !remoteSessionReservations.contains(record.conversationID) else { continue }
            let request = try JSONDecoder().decode(AgentRequest.self, from: record.request)
            if let maximum = request.continuityMaximumTurns, (record.completedTurns ?? 0) >= maximum {
                _ = try await repository.transition(record.id, owner: lease.generation, expectedRevision: current.revision,
                    to: .paused, reason: "The user's explicit mission-turn limit was reached.")
                continue
            }
            // Agent tasks run side by side; driving the screen is arbitrated per action (ScreenControlArbiter).
            var required: Set<String> = []
            if let path = request.workspacePath, request.workspaceEditsEnabled == true || request.workspaceCommandsEnabled == true {
                required.insert("workspace:" + URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
            }
            guard resources.values.allSatisfy({ $0.isDisjoint(with: required) }) else { continue }
            resources[record.id] = required
            do {
            _ = try await repository.transition(record.id, owner: lease.generation,
                                                expectedRevision: current.revision, to: .running)
            } catch { resources.removeValue(forKey: record.id); throw error }
            workers[record.id] = Task { await self.execute(record.id) }
        }
        }
    }
    private func execute(_ id: UUID) async {
        do {
            let record = try await require(id)
            guard record.state == .running, await authorized(record.accountID) else { throw CancellationError() }
            var request = try JSONDecoder().decode(AgentRequest.self, from: record.request)
            if let checkpoint = try await repository.checkpoint(id), checkpoint.turn.calls.isEmpty, record.settledCheckpointAt == checkpoint.savedAt {
                request.continuationMessage = "Continue the approved objective: inspect remaining criteria and take the next useful action. Do not weaken criteria or expand permissions. If the result is ready, deliver it."
            }
            let context = RuntimeExecutionContext(repository: repository, executionID: id, owner: lease.generation)
            let journal = EngineEventCoalescer { [repository, generation = lease.generation] event in
                try await repository.recordEvent(id, owner: generation, kind: "engine", payload: JSONEncoder().encode(event))
            }
            let outcome: ContinuityTurnOutcome
            do {
                outcome = try await ProfileScopedCredentialStore.$requiredOwnerID.withValue(record.accountID) {
                    try await driver.run(request, context: context) { event in try await journal.record(event) }
                }
                try await journal.flush()
            } catch { try? await journal.flush(); throw error }
            try Task.checkCancellation()
            let current = try await require(id)
            guard current.state == .running else { throw CancellationError() }
            if let reason = current.boundaryPauseReason {
                _ = try await repository.settle(id, owner: lease.generation, expectedRevision: current.revision,
                                               state: .paused, reason: reason, delivery: nil)
                workers.removeValue(forKey: id); resources.removeValue(forKey: id); return
            }
            switch outcome {
            case .verified(let result):
                _ = try await repository.settle(id, owner: lease.generation, expectedRevision: current.revision,
                                               state: .verified, reason: "Host criteria re-observed.", delivery: result)
            case .completed(let result):
                // Like ChatGPT or Codex: the answer ends the task. A correction is simply a new message.
                _ = try await repository.settle(id, owner: lease.generation, expectedRevision: current.revision,
                                               state: .accepted, reason: "Completed.", delivery: result)
            case .continueObjective(let progress):
                let previous = try await repository.latestEvents(id, kind: "progress", limit: 2)
                let unchanged = previous.count == 2 && previous.allSatisfy { $0.payload == Data(progress.utf8) }
                try await repository.recordEvent(id, owner: lease.generation, kind: "progress", payload: Data(progress.utf8))
                _ = try await repository.settle(id, owner: lease.generation, expectedRevision: current.revision,
                    state: unchanged ? .blocked : .queued,
                    reason: unchanged ? "Repeated turns without observable progress; user guidance required." : nil, delivery: nil)
            case .wait(let condition):
                guard condition.executionID == id else { throw ExecutionStoreError.invalidTransition }
                _ = try await repository.wait(condition, owner: lease.generation, expectedRevision: current.revision)
            case .user(let reason):
                _ = try await repository.settle(id, owner: lease.generation, expectedRevision: current.revision,
                                               state: .waitingUser, reason: reason, delivery: nil)
            }
        } catch {
            do {
                if let record = try await repository.execution(id), record.state == .running {
                    if error is ExecutionBoundaryPause, let reason = record.boundaryPauseReason {
                        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision, to: .paused, reason: reason)
                    } else if let retry = error as? ProviderRetryDeferral {
                        let checkpoint = try await repository.checkpoint(id)
                        if checkpoint?.needsReconciliation == true {
                            _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                                to: .blocked, reason: "Uncertain effect requires reconciliation before a provider retry.")
                        } else {
                        let previous = try await repository.latestEvents(id, kind: "providerRetry", limit: 1).first
                        let count = min(20, (previous.flatMap { Int(String(decoding: $0.payload, as: UTF8.self)) } ?? 0) + 1)
                        let due = max(retry.notBefore ?? .now, Date.now.addingTimeInterval(min(1800, pow(2, Double(count)))))
                        try await repository.recordEvent(id, owner: lease.generation, kind: "providerRetry", payload: Data(String(count).utf8))
                        _ = try await repository.wait(WakeCondition(executionID: id, kind: .network, key: "providerRetry", dueAt: due),
                            owner: lease.generation, expectedRevision: record.revision)
                        }
                    } else if error is ToolRegistrationError {
                        // The tools could not be prepared: nothing was sent and nothing changed.
                        _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                            to: .failed, reason: "AIM could not prepare the agent's tools. Nothing was sent or changed.")
                    } else {
                    let needsUser: Bool
                    if error is SpendAdmissionError || error is ProviderCredentialError || error is RuntimePrivacyError || error is AgentProviderPluginError { needsUser = true }
                    else if let provider = error as? ProviderRequestError {
                        needsUser = provider.classification == .authentication || provider.classification == .quota
                    }
                    else if let provider = error as? ChatServiceError {
                        switch provider {
                        case .missingKey, .http(401), .http(402), .http(403), .planLimitReached: needsUser = true
                        default: needsUser = false
                        }
                    } else { needsUser = false }
                    // Say in plain words why the run waits; spending pauses send nothing until resumed.
                    let reason: String
                    switch error as? SpendAdmissionError {
                    case .unknownBound?: reason = "Paused before sending: AIM could not verify this request's maximum price under your spending limit."
                    case .limitReached?: reason = "Paused before sending: your spending limit is reached."
                    case .exceptionDeclined?: reason = "Paused before sending: the request over your spending limit was declined."
                    default: reason = Self.plainReason(error)
                    }
                    // Only an action whose effect is unknown needs inspection; anything else pauses
                    // with a plain reason and resumes from its last checkpoint.
                    let uncertain = (try? await repository.checkpoint(id))??.needsReconciliation == true
                    _ = try await repository.transition(id, owner: lease.generation, expectedRevision: record.revision,
                        to: needsUser || !uncertain ? .waitingUser : .blocked,
                        reason: uncertain && !needsUser ? "An action may have had an effect AIM could not confirm. Check it, then resume. Cause: \(reason)" : reason)
                    }
                }
            } catch { /* An obsolete owner cannot report or change state. */ }
        }
        if let root = try? await repository.execution(id) { try? await AccountRuntimeActivity.refresh(root, repository: repository) }
        workers.removeValue(forKey: id)
        resources.removeValue(forKey: id)
        do { try await pump() } catch { /* Persistent state remains authoritative. */ }
    }
}

/// Streamed words are written in small groups (the app reads every 100 ms) rather than one row
/// per word; every other event first writes what was pending, so order is kept.
actor EngineEventCoalescer {
    private let write: @Sendable (EngineEvent) async throws -> Void
    private var text: (UUID, String)?
    private var reasoning: (UUID, String)?
    private var lastFlush = Date.distantPast
    init(write: @escaping @Sendable (EngineEvent) async throws -> Void) { self.write = write }

    func record(_ event: EngineEvent) async throws {
        switch event {
        case let .textDelta(conversationID, piece):
            if reasoning != nil { try await flush() }
            text = (conversationID, (text?.1 ?? "") + piece)
        case let .reasoningDelta(conversationID, piece):
            if text != nil { try await flush() }
            reasoning = (conversationID, (reasoning?.1 ?? "") + piece)
        default:
            try await flush()
            try await write(event)
            return
        }
        if Date.now.timeIntervalSince(lastFlush) >= 0.1 { try await flush() }
    }

    func flush() async throws {
        lastFlush = .now
        if let (conversationID, value) = reasoning { reasoning = nil; try await write(.reasoningDelta(conversationID: conversationID, text: value)) }
        if let (conversationID, value) = text { text = nil; try await write(.textDelta(conversationID: conversationID, text: value)) }
    }
}
