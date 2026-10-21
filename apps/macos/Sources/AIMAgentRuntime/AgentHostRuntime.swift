import AIMCore
import AIMApplication
import AIMAgentKit
import AIMMacPlatform
import Foundation

/// Bootstrap for the signed background helper. No SwiftUI view is constructed.
@MainActor
package final class AgentHostRuntime {
    package let coordinator: RunCoordinator
    package let dependencies: AgentRuntimeDependencies
    private let accountRelay: HostAccountRelay
    package var account: MacAccountController { accountRelay.account }
    private var reloadedAccountID: UUID?
    private let server: AgentHostXPCServer
    private let executions: SQLiteAgentExecutionRepository
    private let ownerGeneration: UUID
    private let privacyOwner: RuntimePrivacyOwner
    private var privacyShutdownInProgress = false
    private let settings: UserDefaultsSettingsRepository
    private let wakeAssertion = AgentHostWakeAssertion()
    private let remoteBridge: ContinuityRemoteBridge
    private let remoteJournal: SQLiteRemoteCommandJournal
    private var remoteHost: RemoteHost?
    private var remoteAccountID: UUID?
    private var updatingRemote = false
    private let scheduler: DurableScheduleCoordinator
    private let scheduleMonitor: RuntimeScheduleMonitor
    private let activityTracker: ActivityTracker
    private var nextActivityPurge = Date.distantPast
    private var nextAccountSync = Date.distantPast
    private let notificationReadyAt = Date()
    private var sentNotificationEvents: Set<UUID> = []
    private let virtualMachines: RuntimeVirtualMachineController
    private let ambientAudio = RuntimeAmbientAudioController(applicationBundle: HostBundleResources.applicationBundle.bundleURL)
    private let channelRouter: RuntimeChannelRouter
    private let wakeMonitor: RuntimeWakeMonitor
    package private(set) var stopped = false
    private var awaitingServiceRemoval = false

    package init() async throws {
        guard Bundle.main.bundleIdentifier == AgentHostXPCServer.serviceName else { throw AgentHostTransportError.wrongIdentity }
        let paths = try ApplicationPaths()
        let lease = try RuntimeLease(url: paths.applicationSupport.appending(path: "agent-runtime.lock"))
        let database = try AIMDatabase(path: paths.database.path)
        settings = UserDefaultsSettingsRepository(defaults: AIMInstallationContext.sharedPreferences)
        let saved = try await settings.load().continuity ?? ContinuitySettings()
        guard saved.permanent else { throw ExecutionStoreError.invalidTransition }
        let vault = try ExecutionArtifactStore(directory: paths.applicationSupport.appending(path: "AgentArtifacts"))
        let repository = SQLiteAgentExecutionRepository(database: database, artifacts: vault)
        executions = repository; ownerGeneration = lease.generation
        privacyOwner = RuntimePrivacyOwner(generation: lease.generation, repository: repository)
        let account = MacAccountController(infoDictionary: HostBundleResources.applicationBundle.infoDictionary ?? [:])
        let relay = HostAccountRelay(account: account)
        accountRelay = relay
        let memory = AccountMemoryRepository(legacy: SQLiteMemoryRepository(database: database), binding: {
            try await MainActor.run {
                guard let id = relay.account.accessUser?.id else { return nil }
                // Signed in but without a connection: this Mac's copy of the account's memory is used.
                guard let client = relay.account.supabaseClient else { return AccountMemoryBinding(accountID: id, service: UnreachableAccountContent()) }
                return AccountMemoryBinding(accountID: id, service: AccountContentSyncService(client: client))
            }
        }, cache: SQLiteAccountMemoryCache(database: database))
        // The permanent host runs agents itself: it adopts the release's background-control
        // qualification for its own key, as the app does at launch.
        let cuaQualifications = SQLiteCuaQualificationRepository(database: database)
        Task.detached(priority: .utility) { _ = await CuaRuntimeIdentity.adoptReleaseManifest(into: cuaQualifications) }
        dependencies = AgentRuntimeDependencies(conversations: SQLiteConversationRepository(database: database),
            missions: SQLiteAgentMissionRepository(database: database), runs: SQLiteWorkspaceRunRepository(database: database),
            secureStore: ProfileScopedCredentialStore(backing: MacProviderKeyStore(), scope: account.credentialScope), memory: memory, settings: settings,
            plans: SQLiteAgentPlanRepository(database: database), ledger: SQLiteGlobalSpendLedger(database: database),
            cuaQualifications: cuaQualifications, mcpServers: SQLiteMCPServerRepository(database: database),
            projects: SQLiteProjectRepository(database: database), documents: SQLiteProjectDocumentRepository(database: database),
            sourceIndex: SQLiteProjectSourceIndex(database: database), activity: SQLiteActivityRepository(database: database),
            compaction: SQLiteSessionCompactionRepository(database: database), jobs: SQLiteSubagentJobRepository(database: database),
            workspaces: SQLiteSubagentWorkspaceRepository(database: database), scheduler: SQLiteSchedulerRepository(database: database))
        activityTracker = ActivityTracker(sampler: MacActivitySampler(), repository: dependencies.activity!)
        virtualMachines = try RuntimeVirtualMachineController(directory: paths.applicationSupport.appending(path: "VirtualMachines"), accountID: { await MainActor.run { relay.account.identity?.storageID } })
        WorkspaceExecutionEnvironment.installVirtualMachineRunner(virtualMachines.makeRunner())
        let interactions = AgentInteractionStore(database: database, owner: lease.generation)
        coordinator = RunCoordinator(repository: repository, driver: NativeContinuityDriver(dependencies: dependencies,
            approvals: ToolApprovalBroker(persistence: interactions), questions: AgentQuestionBroker(persistence: interactions), accountID: { await MainActor.run { relay.account.identity?.storageID } }),
            lease: lease, maximumRoots: saved.maximumRoots, authorized: { id in
                await MainActor.run { id != nil && id == relay.account.identity?.storageID }
            })
        remoteBridge = ContinuityRemoteBridge(coordinator: coordinator, dependencies: dependencies,
            executions: repository, accountID: { await MainActor.run { relay.account.accessUser?.id } })
        remoteJournal = SQLiteRemoteCommandJournal(database: database, owner: lease.generation)
        scheduler = DurableScheduleCoordinator(repository: dependencies.scheduler!, coordinator: coordinator, dependencies: dependencies,
            owner: lease.generation, accountID: { await MainActor.run { relay.account.identity?.storageID } })
        scheduleMonitor = RuntimeScheduleMonitor(scheduler: scheduler)
        wakeMonitor = RuntimeWakeMonitor(coordinator: coordinator, repository: repository, owner: lease.generation, scheduler: dependencies.scheduler)
        channelRouter = try RuntimeChannelRouter(coordinator: coordinator, executions: repository,
            secureStore: dependencies.secureStore, directory: paths.applicationSupport.appending(path: "RuntimeChannels"),
            accountID: { await MainActor.run { relay.account.identity?.storageID } })
        let scheduler = self.scheduler
        let channels = channelRouter
        let ambient = ambientAudio
        let machines = virtualMachines
        let privacy = privacyOwner
        server = try AgentHostXPCServer(client: EmbeddedAgentHostClient(coordinator: coordinator, onStop: { try await privacy.shutdownNormally() }, onLogout: { await relay.stopPeers(); await ambient.stop(); await machines.shutdown(); await relay.account.signOut() },
            onSchedule: { id, command in try await scheduler.enqueue(taskID: id, reason: "run now", payload: nil, commandID: command) }, onChannels: { command in
                guard let current = await MainActor.run(body: { relay.account.identity?.storageID }), command.accountID == current,
                      let data = command.payload else { throw RuntimeChannelError.unauthorized }
                return try await channels.handleControl(data)
            }, onAmbientAudio: { command in
                guard let current = await MainActor.run(body: { relay.account.identity?.storageID }), command.accountID == current, let data = command.payload else { throw RuntimeChannelError.unauthorized }
                let response = try await ambient.handle(data)
                guard await MainActor.run(body: { relay.account.identity?.storageID }) == current else { await ambient.stop(); throw RuntimeChannelError.unauthorized }
                return response
            }, onVirtualMachine: { command in
                guard let current = await MainActor.run(body: { relay.account.identity?.storageID }), command.accountID == current, let data = command.payload else { throw LocalVirtualMachineError.unauthorized }
                let response = try await machines.handleControl(data)
                guard await MainActor.run(body: { relay.account.identity?.storageID }) == current else { await machines.shutdown(); throw LocalVirtualMachineError.unauthorized }
                return response
            }, onPrivacy: { command in try await privacy.handle(command) }, onPeers: { command in
                guard let current = await MainActor.run(body: { relay.account.accessUser?.id }), command.accountID == current,
                      let data = command.payload else { throw RemotePeerError.unauthorized }
                guard let peers = await MainActor.run(body: { relay.peers }) else { throw RemotePeerError.unavailable("peer_runtime_unavailable") }
                let response = try await peers.handleControl(data)
                guard await MainActor.run(body: { relay.account.accessUser?.id }) == current else { throw RemotePeerError.unauthorized }; return response
            }, onRemote: { command in try await relay.handleRemote(command) }),
                                        applicationBundle: HostBundleResources.applicationBundle.bundleURL, initiallyReady: false)
        relay.remoteControl = { [weak self] command in
            guard let self else { throw AgentHostTransportError.disconnected }
            return try await self.handleRemoteControl(command)
        }
        await privacy.configure(validateLiveOwner: { [weak self] in
            guard let self else { throw AgentHostTransportError.disconnected }
            try await self.validatePrivacyOwner()
        }, quiesce: { [weak self] in
            guard let self else { throw AgentHostTransportError.disconnected }
            try await self.quiescePrivacy()
        }, release: { [weak self] in await self?.releasePrivacy() }, normalShutdown: { [weak self] in
            guard let self else { throw AgentHostTransportError.disconnected }
            try await self.stop(keepTransportForReply: true)
        })
        server.start()
        do {
            // Listen during account initialization, but refuse commands until
            // ownership/recovery is ready. Recovery still sees the loaded account.
            await account.start()
            try await coordinator.start()
            try wakeAssertion.setEnabled(saved.keepAwake)
            await wakeMonitor.start()
            await channelRouter.start()
            await updateRemote()
            await server.markReady()
        } catch { server.stop(); throw error }
    }
    package func tick() async throws {
        if awaitingServiceRemoval {
            // The stop RPC must remain deliverable. Unregister/settings false,
            // or an explicit OS termination, performs final listener shutdown.
            if try await settings.load().continuity?.permanent != true { try await stop() }
            return
        }
        guard !privacyShutdownInProgress, !stopped else { return }
        guard await coordinator.isActive else { try await stop(); return }
        // A later login to the same account must reload the controller too.
        if account.sharedSessionSuspended || account.accessUser != nil { reloadedAccountID = nil }
        if let expected = MacAccountController.sharedActiveAccountID, expected != account.user?.id,
           reloadedAccountID != expected, !account.isBusy {
            reloadedAccountID = expected
            let replacement = MacAccountController(infoDictionary: HostBundleResources.applicationBundle.infoDictionary ?? [:])
            accountRelay.account = replacement
            let scope = (dependencies.secureStore as? ProfileScopedCredentialStore)?.scope
            replacement.onAccessChange = { [weak replacement] _ in scope?.activate(replacement?.identity?.storageID) }
            await replacement.start()
            scope?.activate(replacement.identity?.storageID)
        }
        // Dependencies retain the original scope holder when the account controller reloads.
        if let scoped = dependencies.secureStore as? ProfileScopedCredentialStore { scoped.scope.activate(account.identity?.storageID) }
        let currentSettings = try await settings.load()
        let saved = currentSettings.continuity ?? ContinuitySettings()
        guard saved.permanent else { try await stop(); return }
        if account.identity != nil, currentSettings.activity.isEnabled {
            if Date() >= nextActivityPurge {
                _ = try await dependencies.activity?.purge(olderThan: Date().addingTimeInterval(-Double(currentSettings.activity.retentionDays) * 86400))
                nextActivityPurge = Date().addingTimeInterval(3600)
            }
            try await activityTracker.tick(settings: currentSettings.activity)
        } else { await activityTracker.discard() }
        try wakeAssertion.setEnabled(saved.keepAwake)
        try await coordinator.configure(maximumRoots: saved.maximumRoots)
        await SubagentConcurrencyGate.shared.configure(saved.maximumChildren)
        try await coordinator.suspendUnauthorized()
        try await coordinator.tick(at: .now)
        try await wakeMonitor.tick()
        try await channelRouter.tick()
        await virtualMachines.tick()
        await accountRelay.peers?.tick()
        await synchronizeAccountActivity()
        if account.identity != nil {
            try await scheduler.tick(); try scheduleMonitor.update(try await scheduler.watchedTasks())
        } else { await ambientAudio.stop(); scheduleMonitor.stop() }
        await updateRemote()
    }
    private func synchronizeAccountActivity() async {
        guard Date() >= nextAccountSync, let owner = account.accessUser?.id, let client = account.supabaseClient else { return }
        nextAccountSync = Date().addingTimeInterval(30)
        let activity = await executions.activity
        do { _ = try await activity.synchronize(accountID: owner, service: AccountContentSyncService(client: client)) }
        catch { /* The local records stay available for a later sync. */ }
        guard account.accessUser?.id == owner else { return }
        let push = AccountNotificationService(client: client)
        guard let roots = try? await executions.list() else { return }
        for root in roots where root.accountID == owner && root.updatedAt >= notificationReadyAt {
            guard let measured = try? await activity.existing(root.id), measured.accountID == owner else { continue }
            var events: [(String, AIMNotificationCategory)] = []
            if [.verified, .accepted].contains(root.state), measured.completedAt != nil { events.append(("completed", .task)) }
            else if root.state == .failed || root.state == .blocked { events.append(("intervention:\(root.revision)", .failure)) }
            if let interactions = try? await coordinator.interactions(root.id) {
                if let approval = interactions.approvals.first { events.append(("approval:\(approval.id)", .approval)) }
                if let question = interactions.questions.first { events.append(("question:\(question.id)", .question)) }
            }
            for (key, category) in events {
                let eventID = AccountRuntimeActivity.stableID(root.id, "notification:" + key)
                guard !sentNotificationEvents.contains(eventID), account.accessUser?.id == owner else { continue }
                do {
                    try await push.notify(accountID: owner, event: eventID, task: root.id, conversation: root.conversationID, category: category)
                    sentNotificationEvents.insert(eventID)
                } catch { /* Stable event IDs make the next tick an idempotent retry. */ }
            }
        }
    }
    package func stop(keepTransportForReply: Bool = false) async throws {
        guard !stopped else { return }
        guard !AIMNetworkPrivacyAdmission.isPreparing else {
            throw RuntimePrivacyShutdownError.preparationPending
        }
        if awaitingServiceRemoval {
            if !keepTransportForReply { server.stop(); stopped = true }
            return
        }
        let privacy = privacyOwner
        try await privacy.beginNormalShutdown()
        defer { Task { await privacy.endNormalShutdown() } }
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        privacyShutdownInProgress = true
        defer { privacyShutdownInProgress = false }
        await accountRelay.stopPeers()
        await remoteHost?.stop(); remoteHost = nil; remoteAccountID = nil
        scheduleMonitor.stop()
        await virtualMachines.shutdown()
        WorkspaceExecutionEnvironment.installVirtualMachineRunner(nil)
        await ambientAudio.stop()
        try await activityTracker.stop()
        await channelRouter.stop()
        await wakeMonitor.stop()
        guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
        try await coordinator.shutdown()
        await AgentPluginRegistry.shared.stop()
        try wakeAssertion.setEnabled(false)
        if keepTransportForReply { awaitingServiceRemoval = true }
        else { server.stop(); stopped = true }
    }
    private func validatePrivacyOwner() async throws {
        guard !privacyShutdownInProgress, !stopped, await coordinator.isActive else { throw AIMNetworkPrivacyTransactionError.ownerChanged }
        guard !privacyShutdownInProgress, !stopped else { throw AIMNetworkPrivacyTransactionError.ownerChanged }
    }
    private func quiescePrivacy() async throws {
        await accountRelay.stopPeers()
        await remoteHost?.stop(); remoteHost = nil; remoteAccountID = nil
        await channelRouter.stop()
        await AgentPluginRegistry.shared.stop()
        await MCPServerManager.shared.closeAll()
        LocalModelRuntime.stopOpaqueServers()
        _ = try await virtualMachines.privacyQuiesce()
        await account.applyNetworkPrivacy()
        ProcessSupervisor.shared.beginShutdown()
        try await ProcessSupervisor.shared.waitForPrivacyIdle()
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
    }
    private func releasePrivacy() async {
        _ = ProcessSupervisor.shared.resumeAfterCancelledShutdown()
        await channelRouter.start()
        await account.applyNetworkPrivacy()
        await updateRemote()
    }
    private func handleRemoteControl(_ command: AgentHostCommand) async throws -> Data {
        guard !stopped, !awaitingServiceRemoval, !privacyShutdownInProgress,
              command.accountID == account.accessUser?.id, let payload = command.payload else {
            throw RuntimeRemoteControlError.unauthorized
        }
        try await executions.requireOwner(ownerGeneration)
        let control = try JSONDecoder().decode(RuntimeRemoteControl.self, from: payload)
        try control.validate()
        let current = account.accessUser?.id
        if control.action != .status && control.action != .diagnostics && !(control.action == .setEnabled && control.enabled == false) {
            guard current != nil else { throw RemoteHostError.notSignedIn }
            try AIMNetworkPrivacyPolicy.requireNetwork()
        }
        var devices: [RemoteHostDevice] = [], code: RemotePairingCode?, diagnosticReport: RemoteDiagnosticReport?
        switch control.action {
        case .status: break
        case .setEnabled:
            AIMInstallationContext.sharedPreferences.set(control.enabled!, forKey: "AIMRemoteEnabled")
            AIMInstallationContext.sharedPreferences.synchronize()
            await updateRemote()
        case .pairingCode:
            guard let remoteHost else { throw RuntimeRemoteControlError.unavailable }
            code = try await remoteHost.pairingCode()
        case .devices:
            guard let remoteHost else { throw RuntimeRemoteControlError.unavailable }
            devices = try await remoteHost.devices()
        case .revoke:
            guard let remoteHost else { throw RuntimeRemoteControlError.unavailable }
            try await remoteHost.revoke(deviceID: control.deviceID!)
        case .diagnostics:
            guard let remoteHost else { throw RuntimeRemoteControlError.unavailable }
            diagnosticReport = await remoteHost.diagnosticReport()
        }
        guard account.accessUser?.id == current else {
            await updateRemote(); throw RuntimeRemoteControlError.unauthorized
        }
        try await executions.requireOwner(ownerGeneration)
        let enabled = AIMInstallationContext.sharedPreferences.bool(forKey: "AIMRemoteEnabled")
        let status: RemoteHost.Status
        if let remoteHost { status = await remoteHost.status }
        else if enabled && RuntimePrivacyPolicy.isApplicationNetworkBlocked { status = .failed(AIMNetworkPrivacyError.networkDisabled.localizedDescription) }
        else if enabled && current == nil { status = .failed(RemoteHostError.notSignedIn.localizedDescription) }
        else { status = .stopped }
        return try JSONEncoder().encode(RuntimeRemoteState(accountID: current, enabled: enabled,
            hostAvailable: remoteHost != nil, status: status, devices: devices, pairingCode: code, diagnosticReport: diagnosticReport))
    }
    private func updateRemote() async {
        guard !updatingRemote, !privacyShutdownInProgress, !awaitingServiceRemoval, !stopped else { return }
        let user = account.accessUser?.id
        updatingRemote = true
        defer {
            updatingRemote = false
            if account.accessUser?.id != user, !stopped {
                Task { [weak self] in await self?.updateRemote() }
            }
        }
        let enabled = AIMInstallationContext.sharedPreferences.bool(forKey: "AIMRemoteEnabled") == true && !RuntimePrivacyPolicy.isApplicationNetworkBlocked
        if !enabled || user == nil || user != remoteAccountID {
            let oldHost = remoteHost
            remoteHost = nil; remoteAccountID = nil
            await oldHost?.stop()
            await accountRelay.stopPeers()
        }
        guard !privacyShutdownInProgress, !awaitingServiceRemoval, !stopped,
              account.accessUser?.id == user, enabled, let user, let client = account.supabaseClient else { return }
        let relay = accountRelay
        if remoteHost == nil {
            let host = RemoteHost(backend: SupabaseRemoteHostBackend(client: client),
                store: RemoteHostIdentityStore(accountID: user),
                currentAccountID: { await MainActor.run { relay.account.accessUser?.id } }, delegate: remoteBridge,
                machineName: HostBundleResources.remoteMachineName,
                appVersion: HostBundleResources.applicationBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                journal: remoteJournal)
            remoteHost = host; remoteAccountID = user
            await host.start()
            guard account.accessUser?.id == user, !privacyShutdownInProgress, !awaitingServiceRemoval, !stopped else {
                await host.stop(); return
            }
        } else { await remoteHost?.mirrorChanged() }
        guard let remoteHost, case .online = await remoteHost.status,
              account.accessUser?.id == user, accountRelay.peers == nil, accountRelay.peerFailure == nil else { return }
        do {
            let peers = try await RuntimePeerService.make(relay: SupabaseRemotePeerRelay(client: client),
                dependencies: dependencies, executions: executions, coordinator: coordinator,
                owner: ownerGeneration, accountID: { await MainActor.run { relay.account.accessUser?.id } })
            guard account.accessUser?.id == user, !privacyShutdownInProgress, !awaitingServiceRemoval, !stopped else { await peers.stop(); return }
            accountRelay.peers = peers
        } catch {
            if account.accessUser?.id == user { accountRelay.peerFailure = "peer_runtime_initialization_failed" }
        }
    }
}

@MainActor private final class HostAccountRelay {
    var account: MacAccountController
    var peers: RuntimePeerService?
    var peerFailure: String?
    var remoteControl: (@MainActor (AgentHostCommand) async throws -> Data)?
    func handleRemote(_ command: AgentHostCommand) async throws -> Data {
        guard let remoteControl else { throw AgentHostTransportError.disconnected }
        return try await remoteControl(command)
    }
    func stopPeers() async { await peers?.stop(); peers = nil; peerFailure = nil }
    init(account: MacAccountController) { self.account = account }
}
