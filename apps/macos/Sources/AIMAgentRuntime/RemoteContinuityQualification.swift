#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Only for this isolated test process. The account is not a live Keychain view.
package final class QualificationAccountSnapshot: SecureStoring, @unchecked Sendable {
    private let source: any SecureStoring
    private let lock = NSLock()
    private var loaded: Set<String> = []
    private var values: [String: Data] = [:]
    package init(source: any SecureStoring = KeychainSecureStore(service: "com.aimai.macos.auth")) { self.source = source }
    package func readData(forKey key: String) throws -> Data? {
        try lock.withLock {
            if loaded.contains(key) { return values[key] }
            let value = try source.readData(forKey: key)
            loaded.insert(key); values[key] = value; return value
        }
    }
    package func store(_ data: Data, forKey key: String) throws { lock.withLock { loaded.insert(key); values[key] = data } }
    package func removeData(forKey key: String) throws { lock.withLock { loaded.insert(key); values.removeValue(forKey: key) } }
}

/// Physical-phone qualification of the real encrypted relay and coordinator.
/// The only driver is a fixture: no provider runner or desktop tools are created.
package enum RemoteContinuityQualification {
    package static let model = "aim-continuity-simulated-only"
    private final class Secrets: SecureStoring, @unchecked Sendable {
        func readData(forKey key: String) throws -> Data? { key == ChatProvider.openRouter.rawValue ? Data("qualification-not-a-provider-key".utf8) : nil }
        func store(_ data: Data, forKey key: String) throws { throw ExecutionStoreError.invalidTransition }
        func removeData(forKey key: String) throws { throw ExecutionStoreError.invalidTransition }
    }
    private actor Settings: SettingsRepository {
        func load() -> AppSettings {
            var value = AppSettings(selectedMode: .agent, selectedModelID: RemoteContinuityQualification.model)
            value.selectedProvider = .openRouter; value.memoryEnabled = false
            return value
        }
        func save(_ settings: AppSettings) throws { throw ExecutionStoreError.invalidTransition }
    }
    private actor Driver: ContinuityTurnDriving {
        let approvals: ToolApprovalBroker
        let questions: AgentQuestionBroker
        var roots: [UUID: UUID] = [:]
        init(interactions: AgentInteractionStore) {
            approvals = ToolApprovalBroker(persistence: interactions); questions = AgentQuestionBroker(persistence: interactions)
        }
        func run(_ request: AgentRequest, context: RuntimeExecutionContext,
                 event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
            guard request.modelID == RemoteContinuityQualification.model else { throw ExecutionStoreError.invalidTransition }
            roots[request.conversationID] = context.executionID
            let inputs = try await context.repository.pendingUserInputs(executionID: context.executionID, owner: context.owner)
            let calls = try await context.repository.latestEvents(context.executionID, kind: "fixtureRemoteTurn", limit: 1000)
            var checkpoint = ExecutionCheckpoint(conversation: ModelConversationCheckpoint(codec: "remote-qualification-fixture",
                provider: .openRouter, modelID: request.modelID, transcript: Data(), pendingIDs: [], seenIDs: [],
                finished: true, usage: TokenUsage()), turn: ModelToolTurn(text: "", calls: []), effects: [], ordinal: calls.count, seenCallIDs: [])
            checkpoint.deliveredMissionInputIDs = inputs.map(\.id)
            try await RunCheckpointWriter(repository: context.repository, executionID: context.executionID, owner: context.owner).prepare(checkpoint)
            try await context.repository.recordEvent(context.executionID, owner: context.owner, kind: "fixtureRemoteTurn", payload: Data())
            if calls.isEmpty {
                return .wait(WakeCondition(executionID: context.executionID, kind: .deadline, key: "phone-qualification",
                    dueAt: .now.addingTimeInterval(60)))
            }
            let question = AgentQuestion(id: "qualification-\(context.executionID)", conversationID: request.conversationID,
                text: "Test de continuité : quel résultat souhaites-tu ?", options: ["Rapport court", "Rapport détaillé"])
            guard let answer = await questions.ask(question) else { throw CancellationError() }
            try Task.checkCancellation()
            await approvals.reopen(sessionID: context.executionID)
            let approved = await approvals.request(ToolRequest(id: "qualification-approval", name: "qualification_receipt",
                arguments: ["action": "Enregistrer le résultat simulé ; aucune action sur le bureau"], risk: .localMutation,
                workspacePath: request.workspacePath), sessionID: context.executionID, allowsSessionDecision: false)
            try Task.checkCancellation()
            let result = "Qualification simulée terminée. Réponse : \(answer). Approbation : \(approved ? "accordée" : "refusée"). Corrections reçues : \(inputs.count). Aucun modèle payant ni outil système exécuté. Résultat en attente de ta validation."
            return .completed(result: Data(result.utf8))
        }
        func cancel(conversationID: UUID) async {
            if let root = roots[conversationID] { await approvals.close(sessionID: root) }
            for question in await questions.snapshot() where question.conversationID == conversationID { await questions.cancel(question.id) }
        }
        func interactions(_ execution: AgentExecution, children: [DurableSubagent]) async -> ContinuityInteractions {
            await ContinuityInteractions(approvals: approvals.snapshot().filter { $0.sessionID == execution.id },
                questions: questions.snapshot().filter { $0.conversationID == execution.conversationID })
        }
        func approve(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool { await approvals.decide(id: id, sessionID: sessionID, decision: decision) }
        func answer(id: String, text: String) async -> Bool { await questions.answer(id, text: text) }
        func approvalReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool { await approvals.matchesReceipt(id: id, sessionID: sessionID, decision: decision) }
        func questionReceipt(id: String, conversationID: UUID, text: String) async -> Bool { await questions.matchesReceipt(id: id, conversationID: conversationID, text: text) }
    }
    private actor Delegate: RemoteHostDelegate {
        let bridge: ContinuityRemoteBridge
        init(bridge: ContinuityRemoteBridge) { self.bridge = bridge }
        func remoteSnapshots() async -> [RemoteHostSessionSnapshot] { await bridge.remoteSnapshots() }
        func remoteCapabilities() -> RemoteCapabilities {
            RemoteCapabilities(version: 1, models: [RemoteModelAnnouncement(id: RemoteContinuityQualification.model,
                name: "Agent simulé — qualification gratuite", provider: ChatProvider.openRouter.rawValue)],
                engines: [RemoteEngineAnnouncement(id: "aim", state: "ready")],
                features: [RemoteCapabilities.Feature.continuity: true, "goal": true, "chat": false,
                    "attachments": false, "attachmentsAtCreation": false,
                    RemoteCapabilities.Feature.sessionManagement: false, RemoteCapabilities.Feature.history: false])
        }
        func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue, attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
            throw RemoteHostCommandFailure("identifiant_commande_requis")
        }
        func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                           attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
            if ["create_session", "goal_start", "user_message"].contains(type),
               let model = payload.objectValue?["model_id"]?.stringValue, model != RemoteContinuityQualification.model {
                throw RemoteHostCommandFailure("qualification_modele_simule_uniquement")
            }
            return try await bridge.remoteExecute(commandID: commandID, type: type, sessionID: sessionID, payload: payload, attachments: attachments)
        }
    }
    @MainActor package static func run(directory: URL) async throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = FileManager.default.temporaryDirectory.appending(path: "aim-qualification", directoryHint: .isDirectory).resolvingSymlinksInPath().path
        guard directory.path.hasPrefix(root + "/Continuity Remote Qualification ") else { throw ExecutionStoreError.invalidTransition }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lease = try RuntimeLease(url: directory.appending(path: "runtime.lock"))
        let database = try AIMDatabase(path: directory.appending(path: "qualification.sqlite").path)
        let repository = SQLiteAgentExecutionRepository(database: database,
            artifacts: try ExecutionArtifactStore(directory: directory.appending(path: "artifacts")))
        let account = MacAccountController(infoDictionary: HostBundleResources.applicationBundle.infoDictionary ?? [:],
            secureStoreOverride: QualificationAccountSnapshot())
        await account.start()
        guard account.accessUser != nil, let client = account.supabaseClient else {
            try write(["status": "sign_in_required", "limitation": "No model or live runtime started"], directory: directory)
            throw ExecutionStoreError.invalidTransition
        }
        let dependencies = AgentRuntimeDependencies(conversations: SQLiteConversationRepository(database: database),
            missions: SQLiteAgentMissionRepository(database: database), runs: SQLiteWorkspaceRunRepository(database: database),
            secureStore: Secrets(), memory: nil, settings: Settings(), plans: nil,
            ledger: SQLiteGlobalSpendLedger(database: database), cuaQualifications: nil, mcpServers: nil)
        let driver = Driver(interactions: AgentInteractionStore(database: database, owner: lease.generation))
        let coordinator = RunCoordinator(repository: repository, driver: driver, lease: lease, authorized: { id in
            await MainActor.run { id != nil && id == account.accessUser?.id }
        })
        try await coordinator.start()
        let bridge = ContinuityRemoteBridge(coordinator: coordinator, dependencies: dependencies, executions: repository,
            qualified: true, accountID: { await MainActor.run { account.accessUser?.id } })
        let host = RemoteHost(backend: SupabaseRemoteHostBackend(client: client),
            store: RemoteHostIdentityStore(store: KeychainSecureStore(service: "com.aimai.macos.remote.continuityqualification.v2")),
            delegate: Delegate(bridge: bridge), machineName: "AIM Continuité — TEST SIMULÉ V2", appVersion: "continuity-qualification-2",
            heartbeat: .seconds(15), poll: .seconds(1), journal: SQLiteRemoteCommandJournal(database: database, owner: lease.generation))
        await host.start()
        guard case .online = await host.status else { throw ExecutionStoreError.invalidTransition }
        let pairing = try await host.pairingCode()
        var report: [String: String] = ["status": "online", "machineName": "AIM Continuité — TEST SIMULÉ V2",
            "pairingCode": pairing.code, "pairingExpiresAt": ISO8601DateFormatter().string(from: pairing.expiresAt),
            "limitation": "Real encrypted relay and coordinator; simulated driver; account snapshot in RAM; no live-app logout, provider or desktop qualification"]
        try write(report, directory: directory)
        while !Task.isCancelled, !FileManager.default.fileExists(atPath: directory.appending(path: "STOP").path) {
            guard account.accessUser != nil else { break }
            try await coordinator.tick(at: .now)
            await host.mirrorChanged()
            let records = try await coordinator.list()
            report["executions"] = String(records.count)
            report["states"] = records.map { $0.state.rawValue }.joined(separator: ",")
            report["sampledAt"] = ISO8601DateFormatter().string(from: .now)
            try write(report, directory: directory)
            try await Task.sleep(for: .seconds(1))
        }
        await host.stop(); try await coordinator.shutdown()
        report["status"] = "stopped"; report.removeValue(forKey: "pairingCode")
        try write(report, directory: directory)
    }
    private static func write(_ report: [String: String], directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let path = directory.appending(path: "report.json")
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
#endif
