import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Connects the Remote host to AIM: which conversations the phone sees, and
/// how its commands run — through the same paths as on-screen actions, so the
/// usual approvals, spending limits and missions apply.
final class RemoteHostBridge: RemoteHostDelegate, @unchecked Sendable {
    private weak var model: AppModel?
    private let catalogCache: ModelCatalogCache
    private let contextIsCurrent: @MainActor @Sendable () -> Bool
    /// Approval level chosen from the phone, per conversation.
    private let lock = NSLock()
    private var remoteApprovalModes: [UUID: ApprovalPolicy] = [:]

    init(model: AppModel, catalogCache: ModelCatalogCache = .shared,
         contextIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.model = model; self.catalogCache = catalogCache; self.contextIsCurrent = contextIsCurrent
    }
    @MainActor private func requireContextOnMain() throws {
        try Task.checkCancellation()
        guard contextIsCurrent() else { throw DirectRemoteError.unauthorized }
    }
    private func requireContext() async throws { try await MainActor.run { try self.requireContextOnMain() } }


    // MARK: Mirror

    func remoteSnapshots() async -> [RemoteHostSessionSnapshot] {
        await MainActor.run { () -> [(Conversation, Bool, PendingToolApproval?, AgentQuestion?, [ConversationMessage]?, Bool)] in
            guard let model else { return [] }
            let recent = model.conversations.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
            let mirrored = recent.filter { $0.mode == .agent }.prefix(RemoteHostMirror.sessionLimit)
                + recent.filter { $0.mode == .chat }.prefix(RemoteHostMirror.sessionLimit)
                + recent.filter { $0.mode == .code }.prefix(RemoteHostMirror.sessionLimit)
            return mirrored
                .map { conversation in
                    let selected = model.selectedConversationID == conversation.id
                    return (conversation, selected && model.isSending,
                            model.pendingToolApprovals.first { model.toolApproval($0, belongsTo: conversation.id) },
                            model.pendingAgentQuestions.first { $0.conversationID == conversation.id },
                            selected ? model.messages : nil, model.status(of: conversation) == .failed)
                }
        }.asyncMap { [weak self] conversation, running, approval, question, live, failed in
            let messages: [ConversationMessage]
            if let live { messages = live }
            else { messages = (try? await self?.model?.conversationRepository.messages(conversationID: conversation.id)) ?? [] }
            let histories = (try? await self?.model?.remoteWorkspaceHistory(conversationID: conversation.id)) ?? []
            let journal = (try? await self?.model?.projectRuntimeActivity(messages)) ?? messages
            let projected = ConversationActionProjection.apply(histories, to: journal)
            var snapshot = Self.snapshot(conversation, running: running, approval: approval, question: question, messages: projected,
                                         approvalMode: self?.mode(for: conversation.id), failed: failed)
            let continuity = await MainActor.run { [weak self] in
                guard let model = self?.model, model.conversationContinuityAccountMatches else { return (nil as [String]?, nil as ConversationResponseVersion?) }
                return (model.conversationExecutionDevices[conversation.id], model.conversationResponseVersions[conversation.id])
            }
            snapshot.executionDeviceIDs = continuity.0; snapshot.latestResponseVersion = continuity.1
            if let pending = await self?.model?.remoteVisualApproval(conversationID: conversation.id) {
                let connected = await self?.model?.connectedProviders ?? []
                var choices: [RemoteJSONValue] = []
                for provider in ChatProvider.allCases where connected.contains(provider) {
                    for item in await self?.catalogCache.cached(provider) ?? [] where item.supportsImageInput == true {
                        choices.append(.object(["provider": .string(provider.rawValue), "model_id": .string(item.id), "name": .string(item.name)]))
                    }
                }
                snapshot.pendingApproval = .object(["messageId": .string(pending.id.uuidString), "toolName": .string("visual_analysis"),
                    "kind": .string("visual"), "summary": .string("Keep the primary model and analyse these media with a visual sub-agent on this Mac. Cost is determined by the chosen route and checked against this Mac’s budget before each request."),
                    "questions": .array(choices)])
                snapshot.status = "waiting_approval"; snapshot.phase = "Choose a visual model and authorize analysis"
            }
            return snapshot
        }
    }

    static func snapshot(_ conversation: Conversation, running: Bool, approval: PendingToolApproval?, question: AgentQuestion?,
                         messages: [ConversationMessage], approvalMode: ApprovalPolicy?, failed: Bool = false) -> RemoteHostSessionSnapshot {
        var pending: RemoteJSONValue?
        if let approval {
            pending = .object(["messageId": .string(approval.id.uuidString), "toolName": .string(approval.toolName),
                               "summary": .string(summary(approval)), "kind": .string("approval")])
        } else if let question {
            pending = .object(["messageId": .string("question:\(question.id)"), "toolName": .string("ask_user"),
                               "summary": .string(question.text), "kind": .string("question"),
                               "questions": .array(question.items.map { item in
                                   .object(["question": .string(item.question), "multi": .bool(item.multi),
                                            "options": .array(item.options.map { .object(["label": .string($0)]) })])
                               })])
        }
        let visible = messages.filter { ($0.role == .user || $0.role == .assistant) && $0.sequence >= 0 }
        let chat = conversation.mode == .chat
        return RemoteHostSessionSnapshot(
            id: conversation.id.uuidString.lowercased(), mode: conversation.mode.rawValue, title: conversation.title,
            workspace: chat ? nil : conversation.workspacePath, modelID: conversation.modelID,
            approvalMode: chat ? nil : remoteName(approvalMode ?? .alwaysAsk), agentSystem: chat ? nil : (conversation.engineID ?? "aim"),
            status: pending != nil ? "waiting_approval" : running ? "running" : failed || visible.last(where: { $0.role == .assistant })?.completionStatus == .failed ? "failed" : "idle",
            phase: approval.map { "Waiting for approval: \($0.toolName)" } ?? (running ? "Working" : nil),
            pendingApproval: pending, interrupted: visible.last?.completionStatus != nil,
            runStartedAt: running ? visible.last(where: { $0.role == .user })?.createdAt : nil,
            updatedAt: conversation.updatedAt,
            messages: visible.map { message in
                RemoteHostMessageSnapshot(id: message.id.uuidString.lowercased(), sequence: message.sequence,
                                          role: message.role == .user ? "user" : "assistant", content: message.content,
                                          model: message.role == .assistant ? conversation.modelID : nil,
                                          timeline: ConversationAction.remoteTimeline(message.actions, content: message.content, sources: message.sources, turn: message.timeline),
                                          createdAt: message.createdAt)
            })
    }

    static func summary(_ approval: PendingToolApproval) -> String {
        approval.remoteSummary
    }

    static func remoteName(_ policy: ApprovalPolicy) -> String {
        switch policy { case .alwaysAsk: "always_ask"; case .smart: "smart"; case .autoApprove: "auto"; case .plan: "plan" }
    }

    private func mode(for conversation: UUID) -> ApprovalPolicy? { lock.withLock { remoteApprovalModes[conversation] } }

    func remoteCapabilities() async -> RemoteCapabilities {
        let connected = await MainActor.run { model?.connectedProviders ?? [] }
        let favorites = await MainActor.run { model?.settings.favoriteModels ?? [] }
        let additions = RemoteModelCatalogMetadata.additions()
        let reference = await catalogCache.cached(.openRouter) ?? []
        var models: [RemoteModelAnnouncement] = []
        let savedRoutes = Set(additions.compactMap { $0.split(separator: ":", maxSplits: 1).first.flatMap { ChatProvider(rawValue: String($0)) } }).union(favorites.map(\.provider))
        for provider in ChatProvider.allCases where (connected.contains(provider) || savedRoutes.contains(provider)) && provider != .perplexity {
            let catalog = connected.contains(provider) ? (await catalogCache.cached(provider) ?? []) : []
            models += RemoteModelCatalogMetadata.announcements(catalog, provider: provider, favorites: favorites, additions: additions, reference: reference, available: connected.contains(provider))
        }
        return RemoteCapabilities(version: 1, models: models,
            engines: await RemoteInstallationService.shared.engines(),
            features: ["attachments": true, "attachmentsAtCreation": true, "effort": false, "chat": true, "goal": false,
                       RemoteCapabilities.Feature.sessionManagement: false, RemoteCapabilities.Feature.history: false,
                       RemoteCapabilities.Feature.macSettings: true, "modelLibrary": true, "modelRouting": true])
    }

    func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws {
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        let ids = conversationIDs.union(commandIDs).compactMap(UUID.init(uuidString:))
        await model.stopRemoteConversations(Set(ids))
    }

    // MARK: Commands

    func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        try await requireContext()
        try Task.checkCancellation()
        if type == "create_session" {
            guard let model, let id = UUID(uuidString: commandID) else { throw RemoteHostCommandFailure("parametres_manquants") }
            let object = payload.objectValue ?? [:]
            guard let mode = object["mode"]?.stringValue.flatMap(AIMMode.init(rawValue:)),
                  let engine = AgentEngineID(rawValue: object["agent_system"]?.stringValue ?? "aim") else { throw RemoteHostCommandFailure("agent_inconnu") }
            if mode == .agent { try await model.requireRemoteAgent(engine, provider: try providerName(object).flatMap(ChatProvider.init(rawValue:))) }
            try await requireContext()
            try await model.prepareRemoteConversation(id: id, mode: mode, engineID: engine)
            try Task.checkCancellation()
            var admittedObject = object
            admittedObject["_admitted_conversation"] = .string(commandID)
            return try await remoteExecute(type: type, sessionID: sessionID, payload: .object(admittedObject), attachments: attachments)
        }
        return try await remoteExecute(type: type, sessionID: sessionID, payload: payload, attachments: attachments)
    }

    func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        try await requireContext()
        let object = payload.objectValue ?? [:]
        if ["get_mac_settings", "set_mac_settings"].contains(type), object["section"]?.stringValue == "downloads" {
            return try await RemoteInstallationService.shared.execute(type: type, payload: payload)
        }
        if type == "set_model_added" {
            guard let model, let providerName = object["provider"]?.stringValue,
                  let provider = ChatProvider(rawValue: providerName), let modelID = object["model_id"]?.stringValue,
                  let added = object["added"]?.boolValue else {
                throw RemoteHostCommandFailure("modele_inconnu")
            }
            if added {
                guard await MainActor.run(body: { model.connectedProviders.contains(provider) }),
                      (await catalogCache.cached(provider) ?? []).contains(where: { $0.id == modelID }) else {
                    throw RemoteHostCommandFailure("modele_inconnu")
                }
            }
            // Removal remains possible for a retired model or disconnected route.
            // It changes only the authenticated account's library, never execution.
            try await model.setAddedModel(modelID: modelID, provider: provider, added: added)
            return .object(["model_id": .string(modelID), "provider": .string(provider.rawValue), "added": .bool(added)])
        }
        if type == "set_mac_settings", payload.objectValue?["section"]?.stringValue == "skills" {
            return try RemoteSkillExport.install(payload)
        }
        if type == "get_mac_settings", object["section"]?.stringValue == "skills" {
            return try RemoteSkillExport.result(payload)
        }
        if type == "get_mac_settings", object["section"]?.stringValue == "connectors" {
            guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
            return try await RemoteConnectorDirectoryReader.result(repository: model.mcpServerRepository)
        }
        if type == "get_mac_settings" || type == "set_mac_settings" {
            guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
            let update = type == "set_mac_settings" ? try RemoteMacSettings(json: payload) : nil
            return try await MainActor.run {
                try self.requireContextOnMain()
                if let update {
                    let appearance = AppearanceMode(rawValue: update.appearance.rawValue) ?? .system
                    UserDefaults.standard.set(appearance.rawValue, forKey: AppearanceMode.storageKey)
                    AppearanceMode.apply(appearance)
                    model.updatePreferences { value in value.notifyRemote = update.notifyRemote; value.notifyApprovals = update.notifyApprovals; value.notifyQuestions = update.notifyQuestions }
                }
                return RemoteMacSettings(appearance: .init(rawValue: AppearanceMode.current.rawValue) ?? .system,
                    notifyRemote: model.preferences.notifyRemote, notifyApprovals: model.preferences.notifyApprovals,
                    notifyQuestions: model.preferences.notifyQuestions).json
            }
        }
        let chat: Bool
        if type == "create_session" {
            chat = object["mode"]?.stringValue == "chat"
        } else {
            let id = try conversation(sessionID)
            chat = await MainActor.run { model?.conversations.first { $0.id == id }?.mode == .chat }
        }
        if chat && !["create_session", "user_message", "set_model", "stop_generation", "approval_response"].contains(type) {
            throw RemoteHostCommandFailure("commande_non_prise_en_charge")
        }
        switch type {
        case "create_session":
            return chat ? try await createChat(object) : try await createSession(object, attachments: attachments)
        case "user_message", "resume_turn":
            let text = type == "resume_turn" ? "Continue where you stopped; first check what was already done."
                : (object["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else { throw RemoteHostCommandFailure("message_vide") }
            try await send(text, to: try conversation(sessionID), attachments: attachments)
            return nil
        case "approval_response":
            try await answer(object, conversation: try conversation(sessionID))
            return nil
        case "stop_generation":
            let id = try conversation(sessionID)
            let stopped = await MainActor.run { () -> Bool in
                guard let model, model.isSending, model.selectedConversationID == id else { return false }
                Task { await model.cancelCurrentTurn() }
                return true
            }
            guard stopped else { throw RemoteHostCommandFailure("aucune_generation_en_cours") }
            return nil
        case "set_model":
            guard let modelID = object["model_id"]?.stringValue, !modelID.isEmpty else { throw RemoteHostCommandFailure("modele_inconnu") }
            try await setModel(modelID, providerName: try providerName(object), conversation: try conversation(sessionID))
            return nil
        case "set_approval_mode":
            let id = try conversation(sessionID)
            let policy: ApprovalPolicy = switch object["mode"]?.stringValue {
            case "always_ask": .alwaysAsk
            case "smart": .smart
            case "auto": .autoApprove
            case "plan": .plan
            default: throw RemoteHostCommandFailure("mode_inconnu")
            }
            lock.withLock { remoteApprovalModes[id] = policy }
            await MainActor.run {
                guard let model, model.selectedConversationID == id else { return }
                model.approvalPolicy = policy == .plan ? .alwaysAsk : policy
                model.workspacePlanOnly = policy == .plan
            }
            return nil
        case "request_diff":
            throw RemoteHostCommandFailure("diff_indisponible_en_mode_agent")
        default:
            throw RemoteHostCommandFailure("commande_non_prise_en_charge")
        }
    }

    private func conversation(_ sessionID: String?) throws -> UUID {
        guard let sessionID, let id = UUID(uuidString: sessionID) else { throw RemoteHostCommandFailure("session_introuvable") }
        return id
    }

    /// Same path as typing on the Mac: open the conversation, then send.
    @MainActor
    private func send(_ text: String, to id: UUID, attachments: [RemoteHostAttachment] = []) async throws {
        try requireContextOnMain()
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        guard let conversation = model.conversations.first(where: { $0.id == id }) else { throw RemoteHostCommandFailure("session_introuvable") }
        guard !model.isSending else { throw RemoteHostCommandFailure("agent_occupe") }
        if conversation.mode == .agent {
            guard let engine = AgentEngineID(rawValue: conversation.engineID ?? "aim") else { throw RemoteHostCommandFailure("agent_inconnu") }
            try await model.requireRemoteAgent(engine, provider: conversation.provider)
        }
        if model.selectedConversationID != id { await model.selectConversation(id) }
        try requireContextOnMain()
        guard model.selectedConversationID == id else { throw RemoteHostCommandFailure("session_introuvable") }
        prepareAgentTurn(model, conversation: id)
        var message = text
        if !attachments.isEmpty {
            model.pendingAttachments = []
            model.pendingImages = []
            let prepared = try attachments.filter { $0.mimeType == PreparedInputTransfer.mimeType }.map { try PreparedInputTransfer.decode($0.data) }
            let ordinary = attachments.filter { $0.mimeType != PreparedInputTransfer.mimeType }
            var toImport: [URL] = []
            if conversation.mode == .chat {
                // Chat: real attachments of the message (images seen by a vision model).
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aim-remote-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { Task.detached { try? FileManager.default.removeItem(at: folder) } }
                for file in ordinary {
                    let url = folder.appendingPathComponent(RemoteHostAttachments.safeName(file.name))
                    do { try file.data.write(to: url) } catch { throw RemoteHostCommandFailure("piece_jointe_non_enregistree") }
                    toImport.append(url)
                }
                await model.importAttachments(toImport)
            } else {
                // Agent: files go to the workspace for the agent's tools; images are also shown to the model.
                guard let workspace = model.workspacePath ?? conversation.workspacePath else { throw RemoteHostCommandFailure("dossier_introuvable") }
                let saved = try RemoteHostAttachments.save(ordinary, workspace: workspace)
                if !ordinary.isEmpty { message = (message.isEmpty ? "" : message + "\n\n") + saved.note }
                toImport = saved.urls.filter { ["png", "jpg", "jpeg", "heic", "heif"].contains($0.pathExtension.lowercased()) }
                if !toImport.isEmpty { await model.importAttachments(toImport) }
            }
            try requireContextOnMain()
            guard model.selectedConversationID == id else { throw RemoteHostCommandFailure("session_introuvable") }
            model.pendingAttachments += prepared.map { TextAttachment(id: $0.id, name: $0.name, content: $0.text ?? "", video: $0.video) }
            guard model.pendingAttachments.count + model.pendingImages.count == toImport.count + prepared.count else {
                model.pendingAttachments = []
                model.pendingImages = []
                throw RemoteHostCommandFailure("piece_jointe_non_enregistree")
            }
        }
        try requireContextOnMain()
        guard model.selectedConversationID == id else { throw RemoteHostCommandFailure("session_introuvable") }
        model.composerText = message
        model.alertMessage = nil
        await model.sendComposer()
        // Submission is safely waiting for explicit, route-scoped consent. The
        // command is admitted once; approval continues the retained exact draft.
        if model.remoteVisualApproval(conversationID: id) != nil { return }
        if model.showProviderSetup || model.showModelPicker || !model.composerText.isEmpty || !model.pendingAttachments.isEmpty || !model.pendingImages.isEmpty {
            throw RemoteHostCommandFailure("remote_admission_failed")
        }
    }

    @MainActor
    private func prepareAgentTurn(_ model: AppModel, conversation: UUID) {
        if model.conversations.first(where: { $0.id == conversation })?.mode == .chat {
            model.mode = .chat
            model.workspaceToolsEnabled = false
            return
        }
        model.mode = model.conversations.first(where: { $0.id == conversation })?.mode ?? .agent
        guard model.workspacePath != nil else { return }
        let policy = mode(for: conversation) ?? .alwaysAsk
        model.workspaceToolsEnabled = true
        model.workspacePlanOnly = policy == .plan
        if policy != .plan {
            model.workspaceEditsEnabled = true
            model.workspaceCommandsEnabled = true
        }
        model.approvalPolicy = policy == .plan ? .alwaysAsk : policy
    }

    @MainActor
    private func answer(_ object: [String: RemoteJSONValue], conversation id: UUID) async throws {
        try requireContextOnMain()
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        if let visual = model.remoteVisualApproval(conversationID: id) {
            guard object["messageId"]?.stringValue == visual.id.uuidString else { throw RemoteHostCommandFailure("approbation_expiree") }
            guard object["approved"] == .bool(true) else { model.refuseVisualInput(visual.id); return }
            guard let rawProvider = object["visual_provider"]?.stringValue, let provider = ChatProvider(rawValue: rawProvider),
                  let modelID = object["visual_model"]?.stringValue, !modelID.isEmpty,
                  model.connectedProviders.contains(provider) else { throw RemoteHostCommandFailure("modele_inconnu") }
            let succeeded = await model.analyseVisualInput(visual, choice: .init(provider: provider, modelID: modelID), remember: object["remember"] == .bool(true))
            guard succeeded else { throw RemoteHostCommandFailure("visual_analysis_failed") }
            return
        }
        let approvals = model.pendingToolApprovals.filter { model.toolApproval($0, belongsTo: id) }
        let questions = model.pendingAgentQuestions.filter { $0.conversationID == id }
        let messageID = object["messageId"]?.stringValue
        if let approvalID = messageID.flatMap(UUID.init(uuidString:)),
           let approval = approvals.first(where: { $0.id == approvalID }) {
            guard object["approved"]?.boolValue != nil else { throw RemoteHostCommandFailure("approbation_invalide") }
            // Only a strict true is consent; retain the exact approval's session and allowOnce.
            await model.decideToolApproval(approval, allow: object["approved"] == .bool(true))
            return
        }
        if let question = questions.first(where: { messageID == "question:" + $0.id }) {
            guard let text = object["answers"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteHostCommandFailure("reponse_invalide") }
            guard await model.answerAgentQuestion(question, answer: String(text.prefix(20_000))) else {
                throw RemoteHostCommandFailure("approbation_expiree")
            }
            return
        }
        if !approvals.isEmpty || !questions.isEmpty { throw RemoteHostCommandFailure("approbation_expiree") }
        throw RemoteHostCommandFailure("aucune_approbation_en_attente")
    }

    @MainActor
    private func setModel(_ modelID: String, providerName: String?, conversation id: UUID) async throws {
        try requireContextOnMain()
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        guard !model.isSending || model.selectedConversationID != id else { throw RemoteHostCommandFailure("agent_occupe") }
        let provider = try await selectedProvider(modelID, providerName: providerName, connected: model.connectedProviders)
        if model.selectedConversationID != id { await model.selectConversation(id) }
        try requireContextOnMain()
        guard model.selectedConversationID == id else { throw RemoteHostCommandFailure("session_introuvable") }
        model.selectedProvider = provider
        model.selectedModelID = modelID
    }

    /// A relayed Chat (§6.13): created by its first message, on the Mac's own keys.
    @MainActor
    private func createChat(_ object: [String: RemoteJSONValue]) async throws -> RemoteJSONValue {
        try requireContextOnMain()
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        guard let text = object["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || object["pieces_a_suivre"] == .bool(true) else {
            throw RemoteHostCommandFailure("parametres_manquants")
        }
        guard !model.isSending else { throw RemoteHostCommandFailure("agent_occupe") }
        let selection = try await creationSelection(object, in: model)
        try requireContextOnMain()
        if object["_admitted_conversation"] == nil { await model.newGeneralConversation() }
        try requireContextOnMain()
        model.mode = .chat
        model.workspaceToolsEnabled = false
        if let selection { model.selectedProvider = selection.provider; model.selectedModelID = selection.modelID }
        model.composerText = text
        try Task.checkCancellation()
        if object["pieces_a_suivre"] != .bool(true) { await model.sendComposer() }
        guard let id = model.selectedConversationID else { throw RemoteHostCommandFailure("erreur_interne") }
        return .object(["session_id": .string(id.uuidString.lowercased())])
    }

    @MainActor
    private func creationSelection(_ object: [String: RemoteJSONValue], in model: AppModel) async throws -> (provider: ChatProvider, modelID: String)? {
        let provider = try providerName(object)
        guard object["model_id"] != nil || provider != nil else { return nil }
        let modelID = object["model_id"]?.stringValue ?? (object["model_id"] == nil ? model.selectedModelID : nil)
        guard let modelID, !modelID.isEmpty else { throw RemoteHostCommandFailure("modele_inconnu") }
        return (try await selectedProvider(modelID, providerName: provider, connected: model.connectedProviders), modelID)
    }

    private func providerName(_ object: [String: RemoteJSONValue]) throws -> String? {
        guard let value = object["provider"] else { return nil }
        guard let name = value.stringValue, ChatProvider(rawValue: name) != nil else { throw RemoteHostCommandFailure("modele_inconnu") }
        return name
    }

    private func selectedProvider(_ modelID: String, providerName: String?, connected: Set<ChatProvider>) async throws -> ChatProvider {
        do { return try await RemoteModelSelection.resolve(modelID: modelID, providerName: providerName, connected: connected, cache: catalogCache) }
        catch let error as RemoteModelSelectionError { throw RemoteHostCommandFailure(error.rawValue) }
    }

    @MainActor
    private func createSession(_ object: [String: RemoteJSONValue], attachments: [RemoteHostAttachment] = []) async throws -> RemoteJSONValue {
        try requireContextOnMain()
        guard let model else { throw RemoteHostCommandFailure("interface_indisponible") }
        guard ["agent", "code"].contains(object["mode"]?.stringValue ?? "") else { throw RemoteHostCommandFailure("mode_inconnu") }
        guard let workspace = object["workspace"]?.stringValue, let text = object["text"]?.stringValue,
              (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || object["pieces_a_suivre"] == .bool(true)) else { throw RemoteHostCommandFailure("parametres_manquants") }
        guard !model.isSending else { throw RemoteHostCommandFailure("agent_occupe") }
        guard RemoteHostFolders.allowed(workspace) != nil else { throw RemoteHostCommandFailure("chemin_refuse") }
        let selection = try await creationSelection(object, in: model)
        try requireContextOnMain()
        if object["_admitted_conversation"] == nil { await model.newGeneralConversation() }
        try requireContextOnMain()
        model.mode = object["mode"]?.stringValue == "code" ? .code : .agent
        guard await model.chooseWorkspace(workspace) else { throw RemoteHostCommandFailure("chemin_refuse") }
        try requireContextOnMain()
        if let selection { model.selectedProvider = selection.provider; model.selectedModelID = selection.modelID }
        model.workspaceToolsEnabled = true
        model.workspaceEditsEnabled = true
        model.workspaceCommandsEnabled = true
        model.approvalPolicy = .alwaysAsk
        guard let id = model.selectedConversationID else { throw RemoteHostCommandFailure("erreur_interne") }
        let policy: ApprovalPolicy? = switch object["approval_mode"]?.stringValue {
        case "smart": .smart
        case "auto": .autoApprove
        case "plan": .plan
        default: nil
        }
        if let policy { lock.withLock { remoteApprovalModes[id] = policy } }
        try Task.checkCancellation()
        if object["pieces_a_suivre"] != .bool(true) { try await send(text, to: id, attachments: attachments) }
        return .object(["session_id": .string(id.uuidString.lowercased())])
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        for element in self { results.append(await transform(element)) }
        return results
    }
}
