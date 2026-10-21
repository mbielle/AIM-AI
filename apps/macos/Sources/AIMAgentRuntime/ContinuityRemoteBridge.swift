import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Headless Remote adapter. Commands target persisted missions, never the selected view.
package actor ContinuityRemoteBridge: RemoteHostDelegate {
    private let coordinator: RunCoordinator
    private let dependencies: AgentRuntimeDependencies
    private let executions: SQLiteAgentExecutionRepository
    private let accountID: @Sendable () async -> UUID?
    private let qualifiedFixture: Bool?
    private let catalogCache: ModelCatalogCache
    private let sessions: RuntimeRemoteSessionBridge
    private var lastSnapshots: [RemoteHostSessionSnapshot] = []
    private let continuityStore: any SecureStoring
    private var lastSnapshotReadSucceeded = false
    package init(coordinator: RunCoordinator, dependencies: AgentRuntimeDependencies,
                 executions: SQLiteAgentExecutionRepository, qualified: Bool? = nil, catalogCache: ModelCatalogCache = .shared,
                 accountID: @escaping @Sendable () async -> UUID?, continuityStore: (any SecureStoring)? = nil) {
        self.coordinator = coordinator; self.dependencies = dependencies; self.executions = executions
        self.qualifiedFixture = qualified; self.accountID = accountID
        self.catalogCache = catalogCache
        self.continuityStore = continuityStore ?? (qualified != nil ? dependencies.secureStore : KeychainSecureStore(service: (HostBundleResources.applicationBundle.bundleIdentifier ?? "com.aimai.macos") + ".chat-sync"))
        self.sessions = RuntimeRemoteSessionBridge(dependencies: dependencies, coordinator: coordinator)
    }
    package func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws {
        let records = try await coordinator.list()
        let selected = records.filter { commandIDs.contains($0.commandID.uuidString.lowercased()) || conversationIDs.contains($0.conversationID.uuidString.lowercased()) }
        for record in selected where !record.state.isTerminal { try await coordinator.cancel(record.id) }
        await sessions.stop(conversationIDs: Set(selected.map { $0.conversationID }).union(conversationIDs.compactMap(UUID.init(uuidString:))))
    }
    package func remoteSessionLimit() async -> Int? { nil }
    package func remoteCapabilities() async -> RemoteCapabilities {
        let settings = try? await dependencies.settings?.load()
        let additions = RemoteModelCatalogMetadata.additions(defaults: AIMInstallationContext.sharedPreferences)
        let reference = await catalogCache.cached(.openRouter) ?? []
        var models: [RemoteModelAnnouncement] = []
        for provider in ChatProvider.allCases where provider != .perplexity && provider != .local {
            guard (try? dependencies.secureStore.readData(forKey: provider.rawValue)) != nil else { continue }
            models += RemoteModelCatalogMetadata.announcements(await catalogCache.cached(provider) ?? [],
                provider: provider, favorites: settings?.favoriteModels ?? [], additions: additions, reference: reference)
        }
        var features = ContinuityRemoteAvailability.current().features
        if let qualifiedFixture { features[RemoteCapabilities.Feature.continuity] = qualifiedFixture }
        features.merge(["goal": features[RemoteCapabilities.Feature.continuity] == true,
            "attachments": false, "attachmentsAtCreation": false, "chat": false, "modelLibrary": true, "modelRouting": true,
            RemoteCapabilities.Feature.sessionManagement: true, RemoteCapabilities.Feature.history: true,
            RemoteCapabilities.Feature.agentTerminal: true, "terminal": true, "code_terminal": true,
            RemoteCapabilities.Feature.agentDiff: true, "diff": true, RemoteCapabilities.Feature.structuredDiff: true,
            RemoteCapabilities.Feature.agentBrowser: AgentBrowserToolService.isBundled, "browser": AgentBrowserToolService.isBundled]) { _, value in value }
        let records = (try? await coordinator.list()) ?? []
        let worker = RemoteWorkerAnnouncement(modes: ["agent", "code"], maximumRoots: settings?.continuity?.maximumRoots ?? 2,
            runningRoots: records.filter { $0.state == .running }.count, queuedRoots: records.filter { $0.state == .queued }.count)
        return RemoteCapabilities(version: 1, models: models, engines: await RemoteInstallationService.shared.engines(),
            features: features, worker: worker)
    }
    package func remoteSnapshots() async -> [RemoteHostSessionSnapshot] {
        lastSnapshotReadSucceeded = false
        guard let owner = await accountID() else { lastSnapshots = []; return [] }
        var continuity = (try? RuntimeConversationContinuity.load(accountID: owner, store: continuityStore)) ?? .init()
        if let saved = try? AccountChatSync.cachedContinuityState(accountID: owner, secureStore: continuityStore) {
            for (id, devices) in saved.executionDeviceIDs { continuity.executionDeviceIDs[id] = Array(Set((continuity.executionDeviceIDs[id] ?? []) + devices)).sorted() }
            for (id, response) in saved.responseVersions where continuity.responseVersions[id] == nil || continuity.responseVersions[id]!.completedAt <= response.completedAt { continuity.responseVersions[id] = response }
        }
        let originalContinuity = continuity
        let machineID = qualifiedFixture == nil ? (try? RemoteHostIdentityStore(accountID: owner).load()?.machineID) : nil
        guard let records = try? await coordinator.list(),
              let conversations = try? await dependencies.conversations.list(includeArchived: true) else { return lastSnapshots }
        var seen: Set<UUID> = []
        var result: [RemoteHostSessionSnapshot] = []
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) where seen.insert(conversation.id).inserted {
            let record = records.filter { $0.conversationID == conversation.id }.max { $0.createdAt < $1.createdAt }
            guard let record else {
                guard let originalMessages = try? await dependencies.conversations.messages(conversationID: conversation.id) else { return lastSnapshots }
                let histories = (try? await dependencies.runs.history(conversationID: conversation.id, limit: 100)) ?? []
                let messages = ConversationActionProjection.apply(histories, to: (try? await coordinator.projectActivity(originalMessages)) ?? originalMessages)
                result.append(RemoteHostSessionSnapshot(id: conversation.id.uuidString.lowercased(), mode: conversation.mode.rawValue,
                    title: conversation.title, workspace: conversation.workspacePath, modelID: conversation.modelID,
                    approvalMode: conversation.mode == .chat ? nil : "always_ask", agentSystem: conversation.mode == .chat ? nil : (conversation.engineID ?? "aim"),
                    status: messages.last(where: { $0.role == .assistant })?.completionStatus == .failed ? "failed" : "idle",
                    updatedAt: conversation.updatedAt, messages: messages.filter { ($0.role == .user || $0.role == .assistant) && $0.sequence >= 0 }.map {
                        RemoteHostMessageSnapshot(id: $0.id.uuidString.lowercased(), sequence: $0.sequence, role: $0.role.rawValue,
                            content: $0.content, model: conversation.modelID, timeline: ConversationAction.remoteTimeline($0.actions, content: $0.content, sources: $0.sources, turn: $0.timeline), createdAt: $0.createdAt)
                    }, archivedAt: conversation.isArchived ? conversation.updatedAt : nil,
                    executionDeviceIDs: continuity.executionDeviceIDs[conversation.id], latestResponseVersion: continuity.responseVersions[conversation.id]))
                continue
            }
            guard let pending = try? await coordinator.interactions(record.id),
                  let messages = try? await dependencies.conversations.messages(conversationID: record.conversationID) else { return lastSnapshots }
            if continuity.trackedExecutions[record.id] == conversation.id, record.accountID == owner {
                if let machineID, [.running, .awaitingReview, .verified, .accepted].contains(record.state) || (record.completedTurns ?? 0) > 0 {
                    continuity.executionDeviceIDs[conversation.id] = Array(Set((continuity.executionDeviceIDs[conversation.id] ?? []) + [machineID])).sorted()
                }
                if [.awaitingReview, .verified, .accepted].contains(record.state),
                   let answer = messages.last(where: { $0.role == .assistant && $0.completionStatus == nil && !$0.content.isEmpty }),
                   continuity.responseVersions[conversation.id]?.id != answer.id.uuidString.lowercased() {
                    continuity.responseVersions[conversation.id] = .init(id: answer.id.uuidString, completedAt: answer.createdAt)
                }
            }
            let approval = pending.approvals.first.map { item in RemoteJSONValue.object([
                "messageId": .string(item.id.uuidString), "sessionId": .string(item.sessionID.uuidString),
                "executionId": .string(record.id.uuidString), "toolName": .string(item.toolName),
                "summary": .string(item.remoteSummary), "kind": .string("approval")]) }
            let question = pending.questions.first.map { item in RemoteJSONValue.object([
                "messageId": .string("question:" + item.id), "executionId": .string(record.id.uuidString),
                "toolName": .string("ask_user"), "summary": .string(item.text), "kind": .string("question"),
                "questions": .array(item.items.map { .object(["question": .string($0.question), "multi": .bool($0.multi),
                    "options": .array($0.options.map { .object(["label": .string($0)]) })]) })]) }
            result.append(RemoteHostSessionSnapshot(id: conversation.id.uuidString.lowercased(), mode: conversation.mode.rawValue,
                title: conversation.title, workspace: conversation.workspacePath, modelID: conversation.modelID,
                approvalMode: "always_ask", agentSystem: conversation.engineID ?? "aim", status: approval != nil || question != nil || record.state == .waitingUser ? "waiting_approval" : record.state == .failed ? "failed" : [.running, .queued, .waitingEvent, .waitingNetwork].contains(record.state) ? "running" : "idle",
                phase: record.reason, pendingApproval: approval ?? question,
                runStartedAt: record.state == .running ? record.createdAt : nil, updatedAt: max(record.updatedAt, conversation.updatedAt),
                messages: ConversationActionProjection.apply((try? await dependencies.runs.history(conversationID: conversation.id, limit: 100)) ?? [], to: (try? await coordinator.projectActivity(messages)) ?? messages).filter { $0.role == .user || $0.role == .assistant }.map {
                    RemoteHostMessageSnapshot(id: $0.id.uuidString.lowercased(), sequence: $0.sequence,
                        role: $0.role.rawValue, content: $0.content, model: conversation.modelID, timeline: ConversationAction.remoteTimeline($0.actions, content: $0.content, sources: $0.sources, turn: $0.timeline), createdAt: $0.createdAt)
                }, archivedAt: conversation.isArchived ? conversation.updatedAt : nil,
                executionDeviceIDs: continuity.executionDeviceIDs[conversation.id], latestResponseVersion: continuity.responseVersions[conversation.id]))
        }
        guard await accountID() == owner else { return [] }
        if originalContinuity != continuity { try? continuity.save(accountID: owner, store: continuityStore) }
        lastSnapshots = result; lastSnapshotReadSucceeded = true
        return result
    }
    package func remoteSnapshotReadSucceeded() async -> Bool { lastSnapshotReadSucceeded }
    package func durableSessionIDs() async -> Set<String> {
        Set(((try? await coordinator.list()) ?? []).map { $0.conversationID.uuidString.lowercased() })
    }
    package func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue,
                               attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        throw RemoteHostCommandFailure("identifiant_commande_requis")
    }
    package func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                               attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        do { return try await executeAuthorized(commandID: commandID, type: type, sessionID: sessionID, payload: payload, attachments: attachments) }
        catch let error as ExecutionStoreError {
            switch error {
            case .staleOwner, .staleRevision: throw error
            default: throw RemoteHostCommandFailure("continuity_\(String(describing: error))")
            }
        }
    }
    private func executeAuthorized(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                                   attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        guard let command = UUID(uuidString: commandID), let account = await accountID() else {
            throw RemoteHostCommandFailure("connexion_requise")
        }
        if ["get_mac_settings", "set_mac_settings"].contains(type), payload.objectValue?["section"]?.stringValue == "downloads" {
            return try await RemoteInstallationService.shared.execute(type: type, payload: payload)
        }
        if type == "set_mac_settings", payload.objectValue?["section"]?.stringValue == "skills" {
            return try RemoteSkillExport.install(payload)
        }
        if type == "get_mac_settings", payload.objectValue?["section"]?.stringValue == "skills" {
            return try RemoteSkillExport.result(payload)
        }
        if type == "get_mac_settings", payload.objectValue?["section"]?.stringValue == "connectors" {
            guard let repository = dependencies.mcpServers else { throw RemoteHostCommandFailure("interface_indisponible") }
            return try await RemoteConnectorDirectoryReader.result(repository: repository)
        }
        if type == "set_model_added" {
            let object = payload.objectValue ?? [:]
            guard let providerName = object["provider"]?.stringValue, let provider = ChatProvider(rawValue: providerName),
                  let modelID = object["model_id"]?.stringValue, let added = object["added"]?.boolValue,
                  try RuntimeProviderCredentials.hasCredential(provider: provider, store: dependencies.secureStore),
                  (await catalogCache.cached(provider) ?? []).contains(where: { $0.id == modelID }) else {
                throw RemoteHostCommandFailure("modele_inconnu")
            }
            try RemoteModelCatalogMetadata.setAdded(modelID: modelID, provider: provider, added: added,
                defaults: AIMInstallationContext.sharedPreferences)
            return .object(["model_id": .string(modelID), "provider": .string(provider.rawValue), "added": .bool(added)])
        }
        if RuntimeRemoteSessionBridge.commands.contains(type) {
            return try await sessions.execute(commandID: commandID, type: type, sessionID: sessionID, payload: payload)
        }
        let available = qualifiedFixture == true || ContinuityRemoteAvailability.current().isQualified
            || ContinuityRemoteAvailability.current().experimentalOptIn
        guard available else { throw RemoteHostCommandFailure("continuity_non_activee") }
        let object = payload.objectValue ?? [:]
        let action = RemoteContinuityAction(rawValue: type)
        if action == .start || (["create_session", "user_message"].contains(type) && object["goal"]?.objectValue?["continuous"] == .bool(true)) {
            guard attachments.isEmpty, object["attachments"]?.arrayValue?.isEmpty != false else {
                throw RemoteHostCommandFailure("pieces_jointes_continues_non_qualifiees")
            }
            let goal = object["goal"]?.objectValue ?? [:]
            guard goal["version"]?.numberValue == 1, goal["continuous"] == .bool(true),
                  let text = object["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteHostCommandFailure("objectif_invalide")
            }
            let maximumTurns: Int?
            if let number = goal["max_turns"]?.numberValue {
                guard number.isFinite, number > 0, number < Double(Int.max), number.rounded() == number else {
                    throw RemoteHostCommandFailure("limite_invalide")
                }
                maximumTurns = Int(number)
            } else { maximumTurns = nil }
            let cap = goal["max_spend_usd"]?.stringValue
            guard RemoteContinuousGoalConfiguration(maximumTurns: maximumTurns, maximumSpendUSD: cap).isValid else {
                throw RemoteHostCommandFailure("limite_invalide")
            }
            let conversation: Conversation
            if type == "create_session" {
                guard object["mode"]?.stringValue.map({ $0 == "agent" || $0 == "code" }) ?? true else {
                    throw RemoteHostCommandFailure("mode_continu_invalide")
                }
                guard let workspace = object["workspace"]?.stringValue, RemoteHostFolders.allowed(workspace) != nil else {
                    throw RemoteHostCommandFailure("chemin_refuse")
                }
                let explicitProvider: String?
                if let value = object["provider"] {
                    guard let name = value.stringValue, ChatProvider(rawValue: name) != nil else { throw RemoteHostCommandFailure("modele_inconnu") }
                    explicitProvider = name
                } else { explicitProvider = nil }
                if let existing = try await dependencies.conversations.conversation(id: command) {
                    guard object["model_id"].map({ $0.stringValue == existing.modelID }) ?? true,
                          explicitProvider.map({ $0 == existing.provider?.rawValue }) ?? true else { throw ExecutionStoreError.commandConflict }
                    conversation = existing
                }
                else {
                    let settings = try await dependencies.settings?.load()
                    let modelID = object["model_id"]?.stringValue ?? settings?.selectedModelID
                    guard let modelID else { throw RemoteHostCommandFailure("modele_inconnu") }
                    let providerName = explicitProvider ?? (object["model_id"] == nil ? settings?.selectedProvider?.rawValue : nil)
                    let provider = try await providerFor(modelID, providerName: providerName)
                    guard let engine = AgentEngineID(rawValue: object["agent_system"]?.stringValue ?? "aim"),
                          engine == .aim else { throw RemoteHostCommandFailure("external_goal_not_supported") }
                    let mode = object["mode"]?.stringValue.flatMap(AIMMode.init(rawValue:)) ?? .agent
                    conversation = Conversation(id: command, title: String(text.prefix(80)), mode: mode, engineID: "aim",
                        provider: provider, modelID: modelID, workspacePath: workspace)
                    try await dependencies.conversations.save(conversation)
                }
            } else {
                guard let raw = sessionID, let id = UUID(uuidString: raw),
                      let saved = try await dependencies.conversations.conversation(id: id), saved.mode != .chat else {
                    throw RemoteHostCommandFailure("session_introuvable")
                }
                conversation = saved
            }
            guard let model = conversation.modelID, let provider = conversation.provider,
                  let workspace = conversation.workspacePath else { throw RemoteHostCommandFailure("session_non_configuree") }
            // Recover admission before reconstructing mutable personalization/settings.
            // The original immutable request remains the source of truth for this command.
            if let admitted = try await coordinator.list().first(where: { $0.commandID == command }) {
                guard admitted.accountID == account, admitted.conversationID == conversation.id,
                      let original = try? JSONDecoder().decode(AgentRequest.self, from: admitted.request),
                      original.text == text, original.continuityMaximumTurns == maximumTurns,
                      original.continuityMaximumSpendUSD == cap else { throw ExecutionStoreError.commandConflict }
                return try await snapshot(admitted)
            }
            let settings = try await dependencies.settings?.load()
            var request = AgentRequest(conversationID: conversation.id, text: text, modelID: model,
                mode: conversation.mode, workspacePath: workspace, provider: provider, workspaceToolsEnabled: true,
                workspaceEditsEnabled: true, workspaceCommandsEnabled: true, approvalPolicy: .alwaysAsk,
                personalization: settings?.personalization, memoryEnabled: settings?.memoryEnabled ?? true,
                activitySettings: settings?.activity)
            request.continuityMaximumTurns = maximumTurns; request.continuityMaximumSpendUSD = cap
            let admitted = try await coordinator.admit(commandID: command, accountID: account, request: request)
            if var continuity = try? RuntimeConversationContinuity.load(accountID: account, store: continuityStore) {
                continuity.trackedExecutions[admitted.id] = admitted.conversationID
                try? continuity.save(accountID: account, store: continuityStore)
            }
            return try await snapshot(admitted)
        }
        guard let action else { throw RemoteHostCommandFailure("commande_non_prise_en_charge") }
        let record = try await target(object, sessionID: sessionID)
        switch action {
        case .status: break
        case .pause, .resume, .cancel, .correct, .accept:
            let mapped = action.rawValue.replacingOccurrences(of: "goal_", with: "")
            _ = try await coordinator.control(commandID: command, id: record.id, action: mapped, text: object["text"]?.stringValue)
        case .approval:
            guard let id = object["messageId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let session = object["sessionId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let approved = object["approved"]?.boolValue else { throw RemoteHostCommandFailure("approbation_invalide") }
            try await coordinator.approve(executionID: record.id, id: id, sessionID: session,
                                          decision: approved ? .allowOnce : .deny)
        case .question:
            guard let id = object["messageId"]?.stringValue, let text = object["answers"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteHostCommandFailure("reponse_invalide") }
            try await coordinator.answer(executionID: record.id, id: id.hasPrefix("question:") ? String(id.dropFirst(9)) : id, text: text)
        case .start: throw RemoteHostCommandFailure("objectif_invalide")
        }
        guard let updated = try await coordinator.snapshot(record.id) else { throw ExecutionStoreError.notFound }
        return try await snapshot(updated)
    }
    private func providerFor(_ model: String, providerName: String?) async throws -> ChatProvider {
        var connected: Set<ChatProvider> = []
        for provider in ChatProvider.allCases where provider != .local && provider != .perplexity {
            if try RuntimeProviderCredentials.hasCredential(provider: provider, store: dependencies.secureStore) { connected.insert(provider) }
        }
        do { return try await RemoteModelSelection.resolve(modelID: model, providerName: providerName, connected: connected, cache: catalogCache) }
        catch let error as RemoteModelSelectionError { throw RemoteHostCommandFailure(error.rawValue) }
    }
    private func target(_ object: [String: RemoteJSONValue], sessionID: String?) async throws -> AgentExecution {
        guard let raw = sessionID, let conversation = UUID(uuidString: raw) else { throw RemoteHostCommandFailure("session_introuvable") }
        if let raw = object["execution_id"]?.stringValue, let id = UUID(uuidString: raw),
           let record = try await coordinator.snapshot(id), record.conversationID == conversation { return record }
        guard object["execution_id"] == nil,
              let record = try await coordinator.list().filter({ $0.conversationID == conversation }).max(by: { $0.createdAt < $1.createdAt }) else {
            throw RemoteHostCommandFailure("mission_introuvable")
        }
        return record
    }
    private func snapshot(_ record: AgentExecution) async throws -> RemoteJSONValue {
        var value: [String: RemoteJSONValue] = ["version": .number(1), "execution_id": .string(record.id.uuidString),
            "conversation_id": .string(record.conversationID.uuidString), "session_id": .string(record.conversationID.uuidString.lowercased()),
            "state": .string(record.state.rawValue), "revision": .string(String(record.revision))]
        if let reason = record.reason { value["waiting_reason"] = .string(reason) }
        if let data = try await executions.latestDelivery(executionID: record.id), let text = String(data: data, encoding: .utf8) { value["result"] = .string(text) }
        if let ledger = dependencies.ledger as? SQLiteGlobalSpendLedger {
            let spend = try await ledger.executionSnapshot(record.id)
            value["counted_usd"] = .string(spend.countedUSD); value["unknown_spend_attempts"] = .number(Double(spend.unknownAttempts))
        }
        return .object(value)
    }
}
