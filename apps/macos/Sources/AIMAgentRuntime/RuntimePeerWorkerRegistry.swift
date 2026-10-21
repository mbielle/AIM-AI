import AIMCore
import AIMApplication
import AIMMacPlatform
import AIMAgentKit
import Foundation

/// Origin-side durable child driver. Placement/grant/start IDs persist before
/// Pool admission; restoration loads them exactly and never changes the worker.
package actor RuntimePeerWorkerRegistry {
    package static let shared = RuntimePeerWorkerRegistry()
    private struct Plan: Codable { let version: Int; let grant: RemotePeerSignedGrant; let startCommandID: UUID; let baseline: RemotePeerArtifactCommit?; let destination: String? }
    private var router: RuntimePeerRouter?
    private var generation = UUID()
    private var executions: SQLiteAgentExecutionRepository?
    private var owner: UUID?
    private var coordinator: RunCoordinator?
    private var workspaces: RuntimePeerWorkspaceBridge?
    package func install(router: RuntimePeerRouter, executions: SQLiteAgentExecutionRepository, owner: UUID, workspaces: RuntimePeerWorkspaceBridge, coordinator: RunCoordinator) {
        self.router = router; self.executions = executions; self.owner = owner; self.workspaces = workspaces; self.coordinator = coordinator; generation = UUID()
    }
    package func clear() { router = nil; executions = nil; owner = nil; workspaces = nil; coordinator = nil; generation = UUID() }
    package func prepare(context: RuntimeExecutionContext, childID: UUID, machineID: UUID, workspace: String,
        provider: ChatProvider, modelID: String, writerWorkspace: String? = nil) async throws -> DistributedSubagentAssignment {
        guard let router, context.owner == owner, let parent = try await context.repository.execution(context.executionID),
              parent.ownerGeneration == owner, [.running, .waitingEvent, .waitingNetwork].contains(parent.state) else {
            throw RemotePeerError.unauthorized
        }
        struct BudgetScope: Encodable { let version: Int; let accountID: UUID?; let parentExecutionID: UUID; let ownerGeneration: UUID; let childID: UUID; let provider: String; let modelID: String }
        let scope = BudgetScope(version: 1, accountID: parent.accountID, parentExecutionID: parent.id,
            ownerGeneration: context.owner, childID: childID, provider: provider.rawValue, modelID: modelID)
        var grant = try await router.prepareGrant(parent: parent, childID: childID, conversationID: UUID(),
            machineID: machineID, workspace: workspace, provider: provider.rawValue, modelID: modelID, writer: writerWorkspace != nil,
            budgetAuthorization: RemotePeerCoding.encode(scope))
        var baseline: RemotePeerArtifactManifest?
        let paths = await router.transferPaths(for: grant.grant)
        if writerWorkspace != nil || paths != nil {
            guard let workspaces else { throw RemotePeerError.protocolUnavailable }
            baseline = try await workspaces.prepare(root: writerWorkspace ?? workspace, transferID: UUID(), grant: grant.grant,
                paths: writerWorkspace == nil ? paths : nil)
            if let baseline {
                let commit = RemotePeerArtifactCommit(transferID: baseline.transferID,
                    manifestSHA256: RemotePeerArtifactManifest.hash(try RemotePeerCoding.encode(baseline)))
                grant = try await router.bindWorkspace(grant, commit: commit)
            }
        }
        let plan = Plan(version: 1, grant: grant, startCommandID: UUID(), baseline: grant.grant.workspaceArtifact, destination: writerWorkspace)
        try save(plan, childID: childID)
        return DistributedSubagentAssignment(pairID: grant.grant.pairID, grantID: grant.grant.id,
            workerMachineID: machineID, remoteExecutionID: childID, remoteConversationID: grant.grant.childConversationID,
            provider: provider.rawValue, modelID: modelID, workspaceArtifactID: baseline?.transferID,
            workspaceDigest: grant.grant.workspaceArtifact?.manifestSHA256)
    }
    package func run(_ child: DurableSubagent, prompt: String) async throws -> String {
        let expected = generation
        guard let router, let placement = child.remoteAssignment else { throw RemotePeerError.protocolUnavailable }
        let plan = try load(child.id); try validate(plan, child: child)
        guard let provider = ChatProvider(rawValue: placement.provider) else { throw RemotePeerError.invalidConfiguration }
        var request = AgentRequest(conversationID: placement.remoteConversationID, text: prompt, modelID: placement.modelID,
            mode: .code, provider: provider, workspaceToolsEnabled: true, workspaceEditsEnabled: plan.grant.grant.writer, memoryEnabled: false)
        request.allowedToolNames = plan.grant.grant.allowedToolNames.sorted()
        request.remoteSpendGrantData = try RemotePeerCoding.encode(plan.grant)
        request.continuityMaximumSpendUSD = nil
        guard generation == expected else { throw RemotePeerError.unauthorized }
        var workspaceTransfer: RemotePeerArtifactCommit?
        if let baseline = plan.baseline {
            guard let workspaces else { throw RemotePeerError.protocolUnavailable }
            let manifest = try await workspaces.manifest(baseline, grant: plan.grant.grant)
            workspaceTransfer = try await workspaces.send(manifest, grant: plan.grant, transport: router)
        }
        let start = RuntimePeerStartPayload(request: request, workspaceTransfer: workspaceTransfer)
        _ = try await router.request(.init(commandID: plan.startCommandID, action: .start, grant: plan.grant,
            payload: RemotePeerCoding.encode(start)), timeout: 30)
        while generation == expected {
            try Task.checkCancellation()
            let result = try RemotePeerCoding.decode(RuntimePeerExecutionSnapshot.self, await router.request(
                .init(commandID: UUID(), action: .snapshot, grant: plan.grant, payload: Data()), timeout: 30))
            guard result.execution.id == placement.remoteExecutionID,
                  result.execution.conversationID == placement.remoteConversationID else { throw RemotePeerError.invalidEnvelope }
            if [.verified, .accepted, .awaitingReview].contains(result.execution.state) {
                guard let data = result.result, let text = String(data: data, encoding: .utf8) else { throw RemotePeerError.invalidEnvelope }
                if plan.grant.grant.writer {
                    guard let final = result.workspaceTransfer, let baseline = plan.baseline, let destination = plan.destination,
                          let workspaces else { throw RemotePeerError.outcomeUnknown }
                    let manifest = try await workspaces.manifest(baseline, grant: plan.grant.grant)
                    guard let coordinator else { throw RemotePeerError.unauthorized }
                    try await coordinator.withRemoteResources(workspace: destination, desktop: false) {
                        try await workspaces.applyFinal(final, baseline: manifest, destination: destination, grant: plan.grant.grant)
                    }
                }
                return text
            }
            if result.execution.state == .waitingUser { throw ExecutionManagedWait(kind: .subagent, key: "peer:" + child.id.uuidString) }
            if [.failed, .cancelled, .blocked, .paused].contains(result.execution.state) {
                throw RemotePeerError.rejected(result.execution.reason ?? result.execution.state.rawValue)
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw RemotePeerError.unauthorized
    }
    package func control(_ child: DurableSubagent, action: RemotePeerAction, text: String? = nil, messageID: UUID? = nil) async throws {
        guard [.pause, .resume, .cancel, .correction].contains(action), let router else { throw RemotePeerError.protocolUnavailable }
        let plan = try load(child.id); try validate(plan, child: child)
        var payload = Data()
        if action == .correction {
            guard let text, let messageID else { throw RemotePeerError.invalidEnvelope }
            struct Correction: Encodable { let text: String; let sourceMessageID: UUID }
            payload = try RemotePeerCoding.encode(Correction(text: text, sourceMessageID: messageID))
        }
        let key = try await controlKey(child, action: action, messageID: messageID)
        let commandID = RemotePeerCommandIdentity.derive(key)
        _ = try await router.request(.init(commandID: commandID, action: action, grant: plan.grant, payload: payload), timeout: 30)
    }
    /// Reconstruct only durable stop intents, including terminal parents omitted
    /// from normal mission restoration. Starts/resumes are never replayed here.
    package func recoverControls() async {
        guard let executions, let owner, let router, !RuntimePrivacyPolicy.isEnabled else { return }
        let expected = generation
        do {
            try await executions.requireOwner(owner)
            for parent in try await executions.list() {
                try Task.checkCancellation()
                guard generation == expected else { return }
                let children = try await executions.children(parentExecutionID: parent.id)
                for child in children where child.remoteAssignment != nil {
                    let action: RemotePeerAction?
                    if parent.state == .cancelled || child.state == .cancelled { action = .cancel }
                    else if !child.state.isTerminal && (parent.state == .paused || parent.boundaryPauseReason != nil) { action = .pause }
                    else { action = nil }
                    guard let action else { continue }
                    // Isolate an expired/revoked/unavailable peer from other children.
                    do {
                        try await executions.requireOwner(owner)
                        guard generation == expected else { return }
                        let plan = try load(child.id); try validate(plan, child: child)
                        let key = try await controlKey(child, action: action, messageID: nil)
                        try await router.enqueueControl(.init(commandID: RemotePeerCommandIdentity.derive(key),
                            action: action, grant: plan.grant, payload: Data()))
                    } catch { if Task.isCancelled { return } }
                }
            }
        } catch { return }
    }
    private func controlKey(_ child: DurableSubagent, action: RemotePeerAction, messageID: UUID?) async throws -> String {
        var epoch = action == .cancel ? "terminal" : "child:" + String(child.revision)
        if [.pause, .cancel].contains(action), let executions, let owner {
            try await executions.requireOwner(owner)
            if action == .pause {
                let pause = try await executions.latestEvents(child.parentExecutionID, kind: "control:pause", limit: 1).first?.sequence
                let transfer = try await executions.latestEvents(child.parentExecutionID, kind: "transferRequested", limit: 1).first?.sequence
                if let sequence = [pause, transfer].compactMap({ $0 }).max() { epoch = "parent:" + String(sequence) }
            }
        }
        return child.id.uuidString + ":" + epoch + ":" + action.rawValue + ":" + (messageID?.uuidString ?? "")
    }
    package func authorized(_ child: DurableSubagent) async -> Bool {
        guard let router, let plan = try? load(child.id), (try? validate(plan, child: child)) != nil else { return false }
        return await router.authorizeGrant(plan.grant)
    }
    package func interactions(_ child: DurableSubagent) async throws -> ContinuityInteractions {
        guard let router else { throw RemotePeerError.protocolUnavailable }
        let plan = try load(child.id); try validate(plan, child: child)
        return try RemotePeerCoding.decode(ContinuityInteractions.self, await router.request(
            .init(commandID: UUID(), action: .interactions, grant: plan.grant, payload: Data()), timeout: 30))
    }
    package func approve(_ child: DurableSubagent, id: UUID, sessionID: UUID, decision: ApprovalDecision) async throws {
        guard let router, decision != .allowForSession, decision != .allowAlways, sessionID == child.id else { throw RemotePeerError.unauthorized }
        let plan = try load(child.id); try validate(plan, child: child)
        struct Approval: Encodable { let id: UUID; let sessionID: UUID; let decision: ApprovalDecision }
        let command = RemotePeerCommandIdentity.derive("approval:" + child.id.uuidString + ":" + id.uuidString + ":" + decision.rawValue)
        _ = try await router.request(.init(commandID: command, action: .approval, grant: plan.grant,
            payload: RemotePeerCoding.encode(Approval(id: id, sessionID: sessionID, decision: decision))), timeout: 30)
    }
    package func answer(_ child: DurableSubagent, id: String, text: String) async throws {
        guard let router else { throw RemotePeerError.protocolUnavailable }
        let plan = try load(child.id); try validate(plan, child: child)
        struct Answer: Encodable { let id: String; let text: String }
        let command = RemotePeerCommandIdentity.derive("answer:" + child.id.uuidString + ":" + id + ":" + RemotePeerArtifactManifest.hash(Data(text.utf8)))
        _ = try await router.request(.init(commandID: command, action: .answer, grant: plan.grant,
            payload: RemotePeerCoding.encode(Answer(id: id, text: text))), timeout: 30)
    }
    package func message(_ child: DurableSubagent, text: String, sourceID: String) async throws {
        try await control(child, action: .correction, text: text, messageID: RemotePeerCommandIdentity.derive("message:" + child.id.uuidString + ":" + sourceID))
    }
    private func validate(_ plan: Plan, child: DurableSubagent) throws {
        guard plan.version == 1, let assignment = child.remoteAssignment, plan.grant.grant.id == assignment.grantID,
              plan.grant.grant.childExecutionID == child.id, plan.grant.grant.parentExecutionID == child.parentExecutionID,
              plan.grant.grant.workerMachineID == assignment.workerMachineID,
              plan.grant.grant.childConversationID == assignment.remoteConversationID,
              plan.grant.grant.pairID == assignment.pairID,
              plan.grant.grant.workspaceArtifact?.transferID == assignment.workspaceArtifactID,
              plan.grant.grant.workspaceArtifact?.manifestSHA256 == assignment.workspaceDigest else { throw RemotePeerError.unauthorized }
    }
    private func directory() throws -> URL {
        let directory = try ApplicationPaths().applicationSupport.appending(path: "RemotePeerAssignments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidConfiguration }; return directory
    }
    private func save(_ plan: Plan, childID: UUID) throws {
        let file = try directory().appendingPathComponent(childID.uuidString.lowercased() + ".json")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw RemotePeerError.conflictingCommand }
        try RemotePeerCoding.encode(plan).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func load(_ childID: UUID) throws -> Plan {
        let file = try directory().appendingPathComponent(childID.uuidString.lowercased() + ".json")
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 65536 else { throw RemotePeerError.invalidConfiguration }
        return try RemotePeerCoding.decode(Plan.self, Data(contentsOf: file))
    }
}
