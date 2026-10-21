import AIMCore
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

/// The UI retains a transport; integrated workers live in the coordinator.
package actor AgentRuntimeController: AgentHostClient {
    private let dependencies: AgentRuntimeDependencies
    private let executions: SQLiteAgentExecutionRepository
    private let accountID: @Sendable () async -> UUID?
    private let authenticatedAccountID: @Sendable () async -> UUID?
    private var lease: RuntimeLease?
    private var coordinator: RunCoordinator?
    private var client: (any AgentHostClient)?
    private var clockTask: Task<Void, Never>?
    private var scheduler: DurableScheduleCoordinator?
    private var scheduleMonitor: RuntimeScheduleMonitor?
    private var wakeMonitor: RuntimeWakeMonitor?
    private var channelRouter: RuntimeChannelRouter?
    private var ambientAudio: RuntimeAmbientAudioController?
    private var peerService: RuntimePeerService?
    private var virtualMachines: RuntimeVirtualMachineController?
    private var privacyOwner: RuntimePrivacyOwner?
    private var privacyShutdownInProgress = false
    private var remoteControl: (@Sendable (AgentHostCommand) async throws -> Data)?
    package init(dependencies: AgentRuntimeDependencies, executions: SQLiteAgentExecutionRepository,
                 lease: RuntimeLease?, accountID: @escaping @Sendable () async -> UUID?,
                 authenticatedAccountID: @escaping @Sendable () async -> UUID? = { nil }) {
        self.dependencies = dependencies; self.executions = executions; self.lease = lease; self.accountID = accountID
        self.authenticatedAccountID = authenticatedAccountID
    }
    package func start(database: AIMDatabase, maximumRoots: Int) async throws {
        guard client == nil else { return }
        if let lease {
            let decisions = AgentInteractionStore(database: database, owner: lease.generation)
            let driver = NativeContinuityDriver(dependencies: dependencies,
                approvals: ToolApprovalBroker(persistence: decisions), questions: AgentQuestionBroker(persistence: decisions), accountID: self.accountID)
            let accountID = self.accountID
            let authenticatedAccountID = self.authenticatedAccountID
            let machines = try RuntimeVirtualMachineController(directory: ApplicationPaths().applicationSupport.appending(path: "VirtualMachines"), accountID: accountID)
            virtualMachines = machines
            WorkspaceExecutionEnvironment.installVirtualMachineRunner(machines.makeRunner())
            let vmHandler: @Sendable (AgentHostCommand) async throws -> Data = { command in
                guard let current = await accountID(), command.accountID == current, let data = command.payload else { throw LocalVirtualMachineError.unauthorized }
                let response = try await machines.handleControl(data)
                guard await accountID() == current else { await machines.shutdown(); throw LocalVirtualMachineError.unauthorized }
                return response
            }
            let ambient = await RuntimeAmbientAudioController(applicationBundle: Bundle.main.bundleURL)
            ambientAudio = ambient
            let peerHandler: @Sendable (AgentHostCommand) async throws -> Data = { [weak self] command in
                guard let self, let current = await authenticatedAccountID(), command.accountID == current, let data = command.payload else { throw RemotePeerError.unauthorized }
                let response = try await self.handlePeerControl(data)
                guard await authenticatedAccountID() == current else { throw RemotePeerError.unauthorized }; return response
            }
            let audioHandler: @Sendable (AgentHostCommand) async throws -> Data = { command in
                guard let current = await accountID(), command.accountID == current, let data = command.payload else { throw RuntimeChannelError.unauthorized }
                let response = try await ambient.handle(data)
                guard await accountID() == current else { await ambient.stop(); throw RuntimeChannelError.unauthorized }
                return response
            }
            let coordinator = RunCoordinator(repository: executions, driver: driver, lease: lease, maximumRoots: maximumRoots,
                authorized: { candidate in
                    guard let current = await accountID(), candidate == current else { return false }
                    return await accountID() == current
                })
            self.coordinator = coordinator
            try await coordinator.start()
            let privacy = RuntimePrivacyOwner(generation: lease.generation, repository: executions)
            privacyOwner = privacy
            await privacy.configure(validateLiveOwner: { [weak self] in
                guard let self else { throw AgentHostTransportError.disconnected }
                try await self.validatePrivacyOwner(lease.generation)
            }, quiesce: { [weak self] in
                guard let self else { throw AgentHostTransportError.disconnected }
                try await self.quiescePrivacy()
            }, release: { [weak self] in await self?.releasePrivacy() }, normalShutdown: { [weak self] in
                guard let self else { throw AgentHostTransportError.disconnected }
                try await self.shutdownIntegrated()
            })
            let channels = try RuntimeChannelRouter(coordinator: coordinator, executions: executions,
                secureStore: dependencies.secureStore, directory: ApplicationPaths().applicationSupport.appending(path: "RuntimeChannels"), accountID: accountID)
            channelRouter = channels; await channels.start()
            let wake = RuntimeWakeMonitor(coordinator: coordinator, repository: executions, owner: lease.generation, scheduler: dependencies.scheduler)
            wakeMonitor = wake; await wake.start()
            if let repository = dependencies.scheduler {
                _ = try await repository.repairInterrupted(at: .now)
                let schedule = DurableScheduleCoordinator(repository: repository, coordinator: coordinator,
                    dependencies: dependencies, owner: lease.generation, accountID: accountID)
                scheduler = schedule
                scheduleMonitor = await RuntimeScheduleMonitor(scheduler: schedule)
                client = EmbeddedAgentHostClient(coordinator: coordinator, onStop: { try await privacy.shutdownNormally() }, onSchedule: { id, command in
                    try await schedule.enqueue(taskID: id, reason: "run now", payload: nil, commandID: command)
                }, onChannels: { command in
                    guard let current = await accountID(), command.accountID == current, let data = command.payload else { throw RuntimeChannelError.unauthorized }
                    return try await channels.handleControl(data)
                }, onAmbientAudio: audioHandler, onVirtualMachine: vmHandler, onPrivacy: { command in try await privacy.handle(command) }, onPeers: peerHandler, onRemote: { [weak self] command in
                guard let self else { throw AgentHostTransportError.disconnected }
                return try await self.handleRemoteControl(command)
            })
            } else { client = EmbeddedAgentHostClient(coordinator: coordinator, onStop: { try await privacy.shutdownNormally() }, onChannels: { command in
                guard let current = await accountID(), command.accountID == current, let data = command.payload else { throw RuntimeChannelError.unauthorized }
                return try await channels.handleControl(data)
            }, onAmbientAudio: audioHandler, onVirtualMachine: vmHandler, onPrivacy: { command in try await privacy.handle(command) }, onPeers: peerHandler, onRemote: { [weak self] command in
                guard let self else { throw AgentHostTransportError.disconnected }
                return try await self.handleRemoteControl(command)
            }) }
            clockTask = Task { [weak self, coordinator] in
                while !Task.isCancelled {
                    do { try await coordinator.suspendUnauthorized(); try await coordinator.tick(at: .now); try await self?.tickSchedule() }
                    catch { await self?.recordFailure(error) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else { try connectHelper() }
    }
    package private(set) var failure: String?
    private func recordFailure(_ error: Error) { failure = String(describing: error) }
    private func tickSchedule() async throws {
        try await wakeMonitor?.tick()
        try await channelRouter?.tick()
        await virtualMachines?.tick()
        await peerService?.tick()
        if await accountID() == nil { await ambientAudio?.stop(); await scheduleMonitor?.stop(); return }
        try await scheduler?.tick()
        if let scheduler { try await scheduleMonitor?.update(scheduler.watchedTasks()) }
    }
    private func connectHelper() throws {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/AIMAgentHost.app")
        client = try XPCBasedAgentHostClient(helperBundle: helper)
    }
    package func send(_ command: AgentHostCommand) async throws -> Data {
        guard let client else { throw AgentHostTransportError.disconnected }; return try await client.send(command)
    }
    package func waitForHelperReadiness() async throws {
        guard coordinator == nil else { throw ExecutionStoreError.invalidTransition }
        let data = try await send(AgentHostCommand(action: .list))
        _ = try JSONDecoder().decode([AgentExecution].self, from: data)
    }
    package func configureRemoteControl(_ handler: @escaping @Sendable (AgentHostCommand) async throws -> Data) {
        remoteControl = handler
    }
    private func handleRemoteControl(_ command: AgentHostCommand) async throws -> Data {
        guard let remoteControl, coordinator != nil, let lease else { throw AgentHostTransportError.disconnected }
        try await executions.requireOwner(lease.generation)
        return try await remoteControl(command)
    }
    package func currentAccountID() async -> UUID? { await accountID() }
    package func integratedCoordinator() -> RunCoordinator? { coordinator }
    package func remoteDelegate(legacy: any RemoteHostDelegate) throws -> any RemoteHostDelegate {
        guard let coordinator else { throw AgentHostTransportError.disconnected }
        return RuntimeRemoteMultiplexer(continuity: ContinuityRemoteBridge(coordinator: coordinator,
            dependencies: dependencies, executions: executions, accountID: authenticatedAccountID), legacy: legacy)
    }
    /// This UUID scopes local storage. Device authorization stays in the direct
    /// endpoint; this path never creates a cloud account or borrows its grant.
    package func directSessionBridge(localProfileID: UUID, authorizeOperation: @escaping @Sendable () throws -> Void) async throws -> RuntimeRemoteSessionBridge {
        guard let coordinator, await accountID() == localProfileID,
              await authenticatedAccountID() == nil else { throw AgentHostTransportError.disconnected }
        return RuntimeRemoteSessionBridge(dependencies: dependencies, coordinator: coordinator, authorizeOperation: authorizeOperation)
    }
    package func remoteJournal(database: AIMDatabase) throws -> SQLiteRemoteCommandJournal {
        guard let lease else { throw AgentHostTransportError.disconnected }
        return SQLiteRemoteCommandJournal(database: database, owner: lease.generation)
    }
    package func configurePeers(relay: (any RemotePeerRelaying)?) async throws {
        let enabled = AIMInstallationContext.sharedPreferences.bool(forKey: "AIMRemoteEnabled") == true
        guard enabled, !RuntimePrivacyPolicy.isApplicationNetworkBlocked, let relay, let coordinator, let lease,
              await authenticatedAccountID() != nil else { await peerService?.stop(); peerService = nil; return }
        if peerService == nil {
            peerService = try await RuntimePeerService.make(relay: relay, dependencies: dependencies,
                executions: executions, coordinator: coordinator, owner: lease.generation, accountID: authenticatedAccountID)
        }
    }
    private func handlePeerControl(_ data: Data) async throws -> Data {
        guard let peerService else { throw RemotePeerError.protocolUnavailable }; return try await peerService.handleControl(data)
    }
    private func validatePrivacyOwner(_ generation: UUID) async throws {
        guard !privacyShutdownInProgress, lease?.generation == generation, let coordinator, await coordinator.isActive else {
            throw AIMNetworkPrivacyTransactionError.ownerChanged
        }
        guard !privacyShutdownInProgress, lease?.generation == generation else {
            throw AIMNetworkPrivacyTransactionError.ownerChanged
        }
    }
    private func quiescePrivacy() async throws {
        await peerService?.stop(); peerService = nil
        await channelRouter?.stop()
        await AgentPluginRegistry.shared.stop()
        await MCPServerManager.shared.closeAll()
        LocalModelRuntime.stopOpaqueServers()
        _ = try await virtualMachines?.privacyQuiesce()
        ProcessSupervisor.shared.beginShutdown()
        try await ProcessSupervisor.shared.waitForPrivacyIdle()
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
    }
    private func releasePrivacy() async {
        _ = ProcessSupervisor.shared.resumeAfterCancelledShutdown()
        await channelRouter?.start()
    }
    package func repository() -> SQLiteAgentExecutionRepository { executions }
    package func transferToHelper() async throws {
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        let privacy = privacyOwner
        try await privacy?.beginNormalShutdown()
        defer { Task { await privacy?.endNormalShutdown() } }
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        privacyShutdownInProgress = true
        defer { privacyShutdownInProgress = false }
        clockTask?.cancel(); clockTask = nil
        await peerService?.stop(); peerService = nil
        await virtualMachines?.shutdown(); virtualMachines = nil
        WorkspaceExecutionEnvironment.installVirtualMachineRunner(nil)
        await ambientAudio?.stop(); ambientAudio = nil
        await channelRouter?.stop(); channelRouter = nil
        await wakeMonitor?.stop(); wakeMonitor = nil
        await scheduleMonitor?.stop(); scheduleMonitor = nil; scheduler = nil
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        try await coordinator?.relinquishForTransfer()
        await AgentPluginRegistry.shared.stop()
        coordinator = nil; client = nil; lease = nil
        try connectHelper()
    }
    package func shutdownIntegrated() async throws {
        guard !AIMNetworkPrivacyAdmission.isPreparing else {
            throw RuntimePrivacyShutdownError.preparationPending
        }
        let privacy = privacyOwner
        try await privacy?.beginNormalShutdown()
        defer { Task { await privacy?.endNormalShutdown() } }
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        // Fence owner validation before teardown awaits. An OS/process emergency
        // exit does not use this normal shutdown path.
        privacyShutdownInProgress = true
        defer { privacyShutdownInProgress = false }
        clockTask?.cancel(); clockTask = nil
        await peerService?.stop(); peerService = nil
        await virtualMachines?.shutdown(); virtualMachines = nil
        WorkspaceExecutionEnvironment.installVirtualMachineRunner(nil)
        await ambientAudio?.stop(); ambientAudio = nil
        await channelRouter?.stop(); channelRouter = nil
        await wakeMonitor?.stop(); wakeMonitor = nil
        await scheduleMonitor?.stop(); scheduleMonitor = nil; scheduler = nil
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        try await coordinator?.shutdown(); await AgentPluginRegistry.shared.stop(); coordinator = nil; client = nil; lease = nil
    }
    package func cancelAllForSessionRevocation() async throws {
        let records = try JSONDecoder().decode([AgentExecution].self, from: await send(AgentHostCommand(action: .list)))
        for record in records where !record.state.isTerminal {
            _ = try await send(AgentHostCommand(action: .cancel, executionID: record.id))
        }
        let remaining = try JSONDecoder().decode([AgentExecution].self, from: await send(AgentHostCommand(action: .list)))
        guard remaining.allSatisfy({ $0.state.isTerminal }) else { throw ExecutionStoreError.invalidTransition }
    }
    package func suspendUnauthorized() async throws { try await coordinator?.suspendUnauthorized() }
    package func becomeIntegrated(database: AIMDatabase, lease: RuntimeLease, maximumRoots: Int) async throws {
        guard coordinator == nil else { throw ExecutionStoreError.invalidTransition }
        client = nil; self.lease = lease
        try await start(database: database, maximumRoots: maximumRoots)
    }
}

package final class CoordinatedTurnRunner: NativeAgentTurnRunning, @unchecked Sendable {
    private let controller: AgentRuntimeController
    private let fallback: any NativeAgentTurnRunning
    package init(controller: AgentRuntimeController, fallback: any NativeAgentTurnRunning) {
        self.controller = controller; self.fallback = fallback
    }
    package func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        guard request.mode != .chat else { return fallback.run(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = self.controller
                    let commandID = request.sourceMessageID ?? UUID()
                    let known = try JSONDecoder().decode([AgentExecution].self, from: await client.send(AgentHostCommand(action: .list)))
                    let existing = known.first { $0.conversationID == request.conversationID && !$0.state.isTerminal }
                    let record: AgentExecution
                    var after: Int64 = 0
                    if let existing, existing.commandID != commandID {
                        after = try JSONDecoder().decode(Int64.self, from: await client.send(AgentHostCommand(action: .eventCursor, executionID: existing.id)))
                        record = try JSONDecoder().decode(AgentExecution.self, from: await client.send(AgentHostCommand(action: .correct,
                            commandID: commandID, executionID: existing.id, text: request.text, sourceMessageID: request.sourceMessageID)))
                    } else {
                        record = try JSONDecoder().decode(AgentExecution.self, from: await client.send(AgentHostCommand(action: .admit,
                            commandID: commandID, accountID: await client.currentAccountID(), request: request)))
                    }
                    while !Task.isCancelled {
                        let events = try JSONDecoder().decode([ExecutionEvent].self, from: await client.send(AgentHostCommand(action: .events, executionID: record.id, after: after)))
                        for event in events {
                            after = max(after, event.sequence)
                            if event.kind == "engine", let value = try? JSONDecoder().decode(EngineEvent.self, from: event.payload) {
                                if case .completed = value { continue }
                                continuation.yield(value)
                            }
                        }
                        let snapshot = try JSONDecoder().decode(AgentExecution?.self, from: await client.send(AgentHostCommand(action: .snapshot, executionID: record.id)))
                        guard let snapshot else { throw ExecutionStoreError.notFound }
                        if events.count < 100, snapshot.state.isTerminal || [.awaitingReview, .paused, .blocked, .waitingUser].contains(snapshot.state) {
                            continuation.finish(); return
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            // Only this observation ends. The coordinator keeps its workers.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    package func cancel(conversationID: UUID) async {
        if let data = try? await controller.send(AgentHostCommand(action: .list)),
           let records = try? JSONDecoder().decode([AgentExecution].self, from: data),
           let record = records.first(where: { $0.conversationID == conversationID && !$0.state.isTerminal }) {
            _ = try? await controller.send(AgentHostCommand(action: .cancel, executionID: record.id))
        } else { await fallback.cancel(conversationID: conversationID) }
    }
    package func decide(approvalID: String, decision: ApprovalDecision) async {
        let pieces = approvalID.split(separator: "/")
        guard pieces.count == 2, let session = UUID(uuidString: String(pieces[0])),
              let data = try? await controller.send(AgentHostCommand(action: .list)),
              let records = try? JSONDecoder().decode([AgentExecution].self, from: data) else { return }
        for record in records where !record.state.isTerminal {
            guard let data = try? await controller.send(AgentHostCommand(action: .interactions, executionID: record.id)),
                  let interactions = try? JSONDecoder().decode(ContinuityInteractions.self, from: data),
                  interactions.approvals.contains(where: { $0.id.uuidString == pieces[1] && $0.sessionID == session }) else { continue }
            _ = try? await controller.send(AgentHostCommand(action: .approve, executionID: record.id,
                interactionID: String(pieces[1]), sessionID: session, decision: decision)); return
        }
    }
}
