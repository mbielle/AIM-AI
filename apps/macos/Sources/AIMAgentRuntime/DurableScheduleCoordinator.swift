import AIMAgentKit
import AIMApplication
import AIMCore
import CryptoKit
import Foundation

private struct FrozenScheduleAdmission: Codable, Sendable {
    var task: ScheduledTask
    var prompt: String
    var accountID: UUID
}
/// No scheduler-owned model task. Slots and frozen inputs survive UI/host death.
package actor DurableScheduleCoordinator {
    let repository: SQLiteSchedulerRepository
    let coordinator: RunCoordinator
    let dependencies: AgentRuntimeDependencies
    let owner: UUID
    let accountID: @Sendable () async -> UUID?
    private var ticking = false
    package init(repository: SQLiteSchedulerRepository, coordinator: RunCoordinator, dependencies: AgentRuntimeDependencies,
                 owner: UUID, accountID: @escaping @Sendable () async -> UUID?) {
        self.repository = repository; self.coordinator = coordinator; self.dependencies = dependencies
        self.owner = owner; self.accountID = accountID
    }
    package func enqueue(taskID: UUID, reason: String, payload: String?, commandID: UUID? = nil) async throws {
        let digest = SHA256.hash(data: Data((reason + "\n" + (payload ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        let key = commandID?.uuidString ?? "\(taskID):\(digest):\(Int(Date.now.timeIntervalSince1970 / 30))"
        try await repository.enqueueRuntimeEvent(taskID: taskID, key: key, reason: reason, payload: payload, owner: owner)
    }
    package func observe(taskID: UUID, source: String, output: String, newMail: Bool) async throws {
        let signature = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        try await repository.observeRuntimeTrigger(taskID: taskID, sourceSignature: signature,
            reason: newMail ? "new mail" : "its AppleScript result changed", output: output, newMail: newMail, owner: owner)
    }
    package func tick(at date: Date = .now) async throws {
        guard !ticking, let account = await accountID() else { return }
        ticking = true; defer { ticking = false }
        for event in try await repository.runtimeEvents(owner: owner) {
            guard let task = try await repository.task(id: event.taskID), task.state == .enabled else { continue }
            _ = try await claim(task, reason: event.reason, payload: event.payload, at: date, accountID: account, sourceEventID: event.id)
        }
        for task in try await repository.due(before: date) where task.spec?.schedule != nil {
            _ = try await claim(task, reason: "schedule", payload: nil, at: date, accountID: account)
        }
        var records = try await coordinator.list()
        for admission in try await repository.runtimeAdmissions(owner: owner) {
            let frozen = try JSONDecoder().decode(FrozenScheduleAdmission.self, from: admission.payload)
            guard frozen.accountID == account, let spec = frozen.task.spec else { continue }
            var record = records.first { $0.commandID == admission.commandID }
            if record == nil {
                if try await dependencies.conversations.conversation(id: admission.conversationID) == nil {
                    try await dependencies.conversations.save(Conversation(id: admission.conversationID,
                        title: "⏱ " + frozen.task.title, mode: .agent, engineID: "aim", provider: spec.provider,
                        modelID: spec.modelID, workspacePath: spec.workspacePath))
                }
                var request = AgentRequest(conversationID: admission.conversationID, text: frozen.prompt, modelID: spec.modelID,
                    mode: .agent, workspacePath: spec.workspacePath, provider: spec.provider, workspaceToolsEnabled: true,
                    workspaceEditsEnabled: spec.allowEdits, workspaceCommandsEnabled: spec.allowCommands,
                    approvalPolicy: .autoApprove, memoryEnabled: true, modelSupportsImages: true)
                request.initialMissionScope = spec.scope; request.continuityMaximumSpendUSD = spec.maxSpendUSD
                // A still-active heartbeat conversation stays queued at the scheduler.
                if records.contains(where: { $0.conversationID == admission.conversationID && !$0.state.isTerminal }) { continue }
                record = try await coordinator.admit(commandID: admission.commandID, accountID: account, request: request)
                if let record { records.append(record) }
            }
            guard let record else { continue }
            let status: ScheduledRunStatus
            switch record.state {
            case .accepted, .verified: status = .succeeded
            case .cancelled: status = .interrupted
            case .failed: status = .failed
            case .awaitingReview, .waitingUser, .blocked: status = .needsPerson
            default: continue
            }
            _ = try await repository.finish(id: admission.taskID, executionID: admission.claimID, status: status, detail: record.reason, at: date)
            try await repository.completeRuntimeAdmission(admission.commandID, owner: owner)
        }
    }
    private func claim(_ task: ScheduledTask, reason: String, payload: String?, at date: Date, accountID: UUID, sourceEventID: UUID? = nil) async throws -> Bool {
        guard let spec = task.spec, spec.isValid else { return false }
        let previous = spec.continuesConversation == true
            ? try await repository.executions(taskID: task.id, limit: 1).first?.conversationID : nil
        let conversation = previous ?? UUID(), command = UUID()
        let context = ScheduledRunContext(reason: reason, payload: payload, continuing: previous != nil)
        let frozen = FrozenScheduleAdmission(task: task, prompt: ScheduledAgentRunner.prompt(task: task, context: context), accountID: accountID)
        return try await repository.claim(id: task.id, at: date,
            nextRunAt: reason == "schedule" ? spec.nextRun(after: date) : task.nextRunAt, conversationID: conversation,
            durableCommandID: command, admission: JSONEncoder().encode(frozen), owner: owner, sourceEventID: sourceEventID) != nil
    }
    package func watchedTasks() async throws -> [ScheduledTask] {
        try await repository.list().filter { [.enabled, .running].contains($0.state) }.map {
            var watched = $0; watched.state = .enabled; return watched
        }
    }
}
