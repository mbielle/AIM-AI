import AIMCore
import AIMApplication
import AIMAgentKit
import AIMMacPlatform
import Foundation

/// Single runtime owner for relay, native admission and the origin spend broker.
package actor RuntimePeerService {
    private var router: RuntimePeerRouter?
    private let coordinator: RunCoordinator
    private let executions: SQLiteAgentExecutionRepository
    private let owner: UUID
    private let accountID: @Sendable () async -> UUID?
    private let hostID: UUID
    private let broker: RuntimePeerSpendBroker
    private let artifacts: RuntimePeerArtifactEndpoint
    private var recoveryTask: Task<Void, Never>?
    private let workspaces: RuntimePeerWorkspaceBridge
    private init(coordinator: RunCoordinator, executions: SQLiteAgentExecutionRepository, owner: UUID,
        accountID: @escaping @Sendable () async -> UUID?, hostID: UUID, broker: RuntimePeerSpendBroker,
        artifacts: RuntimePeerArtifactEndpoint, workspaces: RuntimePeerWorkspaceBridge) {
        self.coordinator = coordinator; self.executions = executions; self.owner = owner
        self.accountID = accountID; self.hostID = hostID; self.broker = broker; self.artifacts = artifacts; self.workspaces = workspaces
    }
    package static func make(relay: any RemotePeerRelaying, dependencies: AgentRuntimeDependencies,
        executions: SQLiteAgentExecutionRepository, coordinator: RunCoordinator, owner: UUID,
        accountID: @escaping @Sendable () async -> UUID?) async throws -> RuntimePeerService {
        let paths = try ApplicationPaths()
        guard let current = await accountID(), let host = try RemoteHostIdentityStore(accountID: current).load(),
              await accountID() == current else { throw RemotePeerError.unavailable("remote_identity_registration_required") }
        let accountDirectory = current.uuidString.lowercased()
        func directory(_ name: String) throws -> URL {
            let base = paths.applicationSupport.appending(path: name)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try RemotePeerPrivateDirectory.ensureChild(parent: base, name: accountDirectory)
        }
        guard let id = UUID(uuidString: host.machineID), let ledger = dependencies.ledger as? SQLiteGlobalSpendLedger else {
            throw RemotePeerError.invalidConfiguration
        }
        let broker = try RuntimePeerSpendBroker(ledger: ledger, executions: executions, owner: owner,
            directory: try directory("RemotePeerSpend"))
        let artifacts = RuntimePeerArtifactEndpoint(store: try RemotePeerArtifactStore(directory: try directory("RemotePeerArtifacts")))
        let workspaces = try RuntimePeerWorkspaceBridge(artifacts: artifacts, directory: try directory("RemotePeerWorkspaces"))
        let service = RuntimePeerService(coordinator: coordinator, executions: executions, owner: owner,
            accountID: accountID, hostID: id, broker: broker, artifacts: artifacts, workspaces: workspaces)
        let endpoint = RuntimePeerExecutionEndpoint(coordinator: coordinator, executions: executions,
            workspace: { grant in try await service.workspace(grant) }, requestProvider: { grant, data, workspace in
                let payload = try RemotePeerCoding.decode(RuntimePeerStartPayload.self, data)
                var request = payload.request
                request.allowedToolNames = grant.allowedToolNames.sorted()
                request.anthropicOutputTokens = nil; request.openAIReasoningEffort = nil
                request.providerPluginID = nil; request.customAgentProfileID = nil; request.customAgentInstructions = nil
                request.activitySettings = nil; request.memoryEnabled = false; request.personalization = nil
                request.contextLength = nil; request.modelSupportsImages = nil
                request.workspaceToolsEnabled = true; request.workspaceEditsEnabled = grant.writer
                request.workspaceCommandsEnabled = false; request.workspaceTextToolProtocol = false
                request.workspacePlanOnly = false; request.approvalPolicy = .alwaysAsk
                request.continuityMaximumTurns = nil
                request.initialMissionScope = nil
                request.continuationMessage = nil; request.sourceMessageID = nil
                guard payload.workspaceTransfer == grant.workspaceArtifact else { throw RemotePeerError.unauthorized }
                if grant.writer {
                    guard let transfer = payload.workspaceTransfer else { throw RemotePeerError.unauthorized }
                    request.workspacePath = try await workspaces.materialize(transfer, grant: grant)
                } else if let transfer = payload.workspaceTransfer {
                    request.workspacePath = try await workspaces.materialize(transfer, grant: grant)
                } else { request.workspacePath = workspace }
                request.conversationID = grant.childConversationID
                if grant.writer, let path = request.workspacePath {
                    request.initialMissionScope = [try MissionAuthorizationRule(resource: MissionResource(kind: .directory, identifier: path), operations: [.observe, .edit])]
                }
                request.continuityMaximumSpendUSD = nil
                return request
            }, budget: { request, grant, _ in
                try await broker.handle(request.payload, parentExecutionID: grant.parentExecutionID,
                    childID: grant.childExecutionID, expectedProvider: grant.provider, expectedModelID: grant.modelID,
                    authorized: { await service.authorized(request, grant) })
            }, artifact: artifacts.handle, workspaceResult: { grant, record in
                try await service.exportFinal(grant, record: record)
            })
        let router = try RuntimePeerRouter(relay: relay, hostIdentity: host,
            secureStore: KeychainSecureStore(service: AIMInstallationContext.keychainService("com.aimai.macos.remote")),
            directory: try directory("RemotePeers"), accountID: accountID,
            authority: { request, grant in await service.authorized(request, grant) }, handler: endpoint.handle,
            onRevocation: endpoint.revoke)
        guard await accountID() == current else { throw RemoteHostError.accountChanged }
        await service.install(router)
        await RuntimePeerSpendRegistry.shared.install(router: router)
        await RuntimePeerWorkerRegistry.shared.install(router: router, executions: executions, owner: owner, workspaces: workspaces, coordinator: coordinator)
        await router.start()
        guard await accountID() == current else { await service.stop(); throw RemoteHostError.accountChanged }
        return service
    }
    private func install(_ router: RuntimePeerRouter) { self.router = router }
    package func tick() async {
        await router?.tick()
        if recoveryTask == nil {
            recoveryTask = Task { [weak self] in
                await RuntimePeerWorkerRegistry.shared.recoverControls()
                await self?.finishRecovery()
            }
        }
    }
    private func finishRecovery() { recoveryTask = nil }
    package func stop() async {
        recoveryTask?.cancel(); await recoveryTask?.value; recoveryTask = nil
        await router?.stop(); router = nil
        await RuntimePeerSpendRegistry.shared.clear(); await RuntimePeerWorkerRegistry.shared.clear()
    }
    package func handleControl(_ data: Data) async throws -> Data {
        guard let router else { throw RemotePeerError.protocolUnavailable }; return try await router.handleControl(data)
    }
    private func exportFinal(_ grant: RemotePeerGrant, record: AgentExecution) async throws -> RemotePeerArtifactCommit? {
        guard let router, let request = try? RemotePeerCoding.decode(AgentRequest.self, record.request),
              let data = request.remoteSpendGrantData else { throw RemotePeerError.unauthorized }
        guard grant.writer else { return nil }
        guard let workspace = request.workspacePath else { throw RemotePeerError.unauthorized }
        let signed = try RemotePeerCoding.decode(RemotePeerSignedGrant.self, data)
        return try await coordinator.withRemoteResources(workspace: workspace, desktop: false) { [workspaces] in
            try await workspaces.exportFinal(grant: signed, record: record, transport: router)
        }
    }
    private func workspace(_ grant: RemotePeerGrant) async throws -> String {
        guard let router else { throw RemotePeerError.protocolUnavailable }; return try await router.workspace(for: grant)
    }
    private func authorized(_ request: RemotePeerRequest, _ grant: RemotePeerGrant) async -> Bool {
        guard !RuntimePrivacyPolicy.isEnabled, await accountID() == grant.accountID else { return false }
        if hostID == grant.originMachineID {
            guard let parent = try? await executions.execution(grant.parentExecutionID), parent.accountID == grant.accountID,
                  let child = try? await executions.child(grant.childExecutionID),
                  child.parentExecutionID == parent.id, let placement = child.remoteAssignment,
                  placement.pairID == grant.pairID, placement.grantID == grant.id,
                  placement.workerMachineID == grant.workerMachineID, placement.remoteExecutionID == grant.childExecutionID,
                  placement.remoteConversationID == grant.childConversationID,
                  placement.provider == grant.provider, placement.modelID == grant.modelID,
                  placement.workspaceArtifactID == grant.workspaceArtifact?.transferID,
                  placement.workspaceDigest == grant.workspaceArtifact?.manifestSHA256 else { return false }
            if [.pause, .cancel].contains(request.action) {
                do {
                    try await executions.requireOwner(owner)
                    if request.action == .pause {
                        let pause = try await executions.latestEvents(parent.id, kind: "control:pause", limit: 1).first?.sequence
                        let transfer = try await executions.latestEvents(parent.id, kind: "transferRequested", limit: 1).first?.sequence
                        let resume = try await executions.latestEvents(parent.id, kind: "control:resume", limit: 1).first?.sequence
                        // A delayed outbox pause cannot undo a later user resume.
                        if let resume, ([pause, transfer].compactMap { $0 }.max() ?? 0) < resume { return false }
                    }
                    try await executions.requireOwner(owner)
                    return true
                } catch { return false }
            }
            guard parent.ownerGeneration == owner else { return false }
            if request.action == .budget { return true } // Broker differentiates admission from late finalization.
            if [.snapshot, .events, .interactions].contains(request.action) { return true }
            return [.running, .waitingEvent, .waitingNetwork].contains(parent.state) && parent.boundaryPauseReason == nil
        }
        guard hostID == grant.workerMachineID else { return false }
        if [.start, .artifactManifest, .artifactChunk, .artifactCommit].contains(request.action) { return true }
        guard let child = try? await executions.execution(grant.childExecutionID), child.accountID == grant.accountID,
              child.conversationID == grant.childConversationID,
              let admitted = try? RemotePeerCoding.decode(AgentRequest.self, child.request),
              let data = admitted.remoteSpendGrantData,
              let signed = try? RemotePeerCoding.decode(RemotePeerSignedGrant.self, data), signed.grant == grant else { return false }
        return true
    }
}
