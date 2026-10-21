import AIMCore
import CryptoKit
import AVFoundation
import Foundation
import Observation
import UIKit
import UserNotifications

enum NativeChatErrorNoticeKind: Equatable {
    case webSearchBudget
}

@MainActor @Observable final class NativeChatStore {
    var pendingSettingsDestination: SettingsDestination?
    @ObservationIgnored lazy var connectors = AIMWebConnectorStore(accountID: accountID)
    var provider: ChatProvider = .openRouter
    var modelID = ""
    var preferences = AccountChatPreferences()
    var profileInstructions = ""
    var models: [ChatModel] = []
    var catalogModels: [ChatProvider: [ChatModel]] = [:]
    // Public reference facts are presentation data. Keep the original route's
    // prices and limits separately for admission and request accounting.
    private var nativeCatalogModels: [ChatProvider: [ChatModel]] = [:]
    private var publicModelCatalog: [ChatModel]?
    private var publicModelCatalogTask: Task<[ChatModel]?, Never>?
    var favorites: Set<String> = []
    var pinnedModels: Set<String> = []
    private var pinnedBase: Set<String> = []
    private var pinsDirty = false
    var customOutputTokenLimit: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: "aim.chat.output-tokens")
            return value > 0 ? value : nil
        }
        set { if let newValue, newValue > 0 { UserDefaults.standard.set(newValue, forKey: "aim.chat.output-tokens") } else { UserDefaults.standard.removeObject(forKey: "aim.chat.output-tokens") } }
    }
    let projectDocuments: AIMProjectDocumentLibrary
    var projects: [NativeChatProject] = []
    var selectedProjectID: UUID?
    var conversations: [NativeChatConversation] = []
    var selectedID: UUID?
    var executionTarget: ChatExecutionTarget = .thisDevice { didSet { if !loadingSnapshot && executionTarget != oldValue { persist() } } }
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var responseGenerations: [UUID: UUID] = [:]
    private var newDraftID = UUID()
    private var generalDraftID = UUID()
    private var drafts: [UUID: String] = [:]
    var subagentTargetID: String { "iphone:" + deviceID }
    func subagentPreferences(target: String? = nil) -> SubagentPreferences {
        let target = target ?? subagentTargetID
        return preferences.subagentDefaults?[target] ?? SubagentPreferenceStore.load(accountID: accountID, target: target)
    }
    func setSubagentPreferences(_ value: SubagentPreferences, target: String? = nil) {
        let target = target ?? subagentTargetID
        preferences.subagentDefaults = (preferences.subagentDefaults ?? [:]).merging([target: value]) { _, new in new }
        try? SubagentPreferenceStore.save(value, accountID: accountID, target: target)
        preferencesChanged()
    }
    var pendingVisualApproval: NativeVisualApproval?
    var preparingVisualAnalysis = false
    func runVisualApproval(_ pending: NativeVisualApproval, choice: SubagentModelChoice, remember: Bool) async -> Bool {
        guard !preparingVisualAnalysis, pending.target == .thisDevice else { return false }
        preparingVisualAnalysis = true; defer { preparingVisualAnalysis = false }
        do {
            guard !UserDefaults.standard.bool(forKey: "aim.budget.enabled") else {
                errorMessage = "Visual input cost has no verified upper bound. Review this iPhone’s budget before authorizing analysis."; return false
            }
            let owner = accountID
            guard try key(for: pending.primaryProvider)?.isEmpty == false else { throw ChatServiceError.missingKey }
            let catalog = try await catalog(for: choice.provider)
            guard let model = catalog.first(where: { $0.id == choice.modelID && $0.supportsImageInput == true }),
                  let credential = try key(for: choice.provider) else { throw NativeImageSnapshotError.unsupportedProvider }
            var preferences = subagentPreferences()
            preferences.visual = choice; if remember { preferences.permanentVisualConsents.insert(choice) }
            setSubagentPreferences(preferences)
            let taskID = UUID(), started = Date()
            activityRecords.append(.init(id: taskID, accountID: owner, deviceID: deviceID, deviceName: UIDevice.current.name,
                conversationID: pending.conversationID, provider: choice.provider.rawValue, modelID: choice.modelID,
                mode: "visual_analysis", startedAt: started, costState: .unknown)); persist()
            let report = try await VisualAnalysisService.analyse(pending.sources, choice: choice, model: model, key: credential, transport: transport, checkBudget: { [weak self] requestID in
                try Task.checkCancellation()
                try await MainActor.run {
                    guard let self, self.accountID == owner else { throw CancellationError() }
                    guard !UserDefaults.standard.bool(forKey: "aim.budget.enabled") else { throw NativeDocumentError.limit }
                    self.activityRecords.append(.init(id: requestID, accountID: owner, deviceID: self.deviceID, deviceName: UIDevice.current.name, conversationID: pending.conversationID, parentTaskID: taskID, provider: choice.provider.rawValue, modelID: choice.modelID, mode: "visual_analysis", startedAt: .now, costState: .unknown))
                    if let index = self.activityRecords.firstIndex(where: { $0.id == taskID }) { self.activityRecords[index].costTrackedSeparately = true }
                    guard self.persist() else { throw CancellationError() }
                }
            }, observed: { [weak self] requestID, usage in
                await MainActor.run {
                    guard let self, self.accountID == owner else { return }
                    let cost = ChatCostRules.estimateUSD(usage: usage, pricing: model.pricing, webSearch: nil)
                    if let index = self.activityRecords.firstIndex(where: { $0.id == requestID }) {
                        self.activityRecords[index].completedAt = .now
                        self.activityRecords[index].costUSD = cost
                        self.activityRecords[index].costState = cost == nil ? .unknown : .estimated
                    }
                    self.persist()
                }
            })
            guard accountID == owner, executionTarget == pending.target, !Task.isCancelled else { throw CancellationError() }
            visualDraftReports[pending.conversationID] = report
            guard persist() else { return false }
            pendingVisualApproval = nil
            return await send(pending.text, conversationID: pending.conversationID, projectID: pending.projectID,
                provider: pending.primaryProvider, modelID: pending.primaryModel, catalog: pending.catalog,
                target: pending.target, selectConversation: pending.selectConversation, attachments: pending.attachments, visualReport: report)
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private var inputDrafts: [UUID: [NativeChatAttachment]] = [:]
    /// Presence means that no provider request has crossed the durable admission gate.
    private struct PendingSubmission: Codable, Sendable {
        var conversationID: UUID; var user: NativeChatMessage; var assistant: NativeChatMessage
        var projectID: UUID?; var provider: ChatProvider; var model: ChatModel
        var history: [NativeChatMessage]; var instructions: String; var maxOutput: Int?; var catalogMaximum: Int?
        var webSearch: Bool; var skills: [NativeSkill]; var bound: Double?; var startedAt: Date
        var permissionFingerprint: String; var captureMemory: Bool
        // Older queued requests and captured voice callers never acquire new source access implicitly.
        var projectSourcesAllowed: Bool? = nil
        var researchMode: AIMResearchMode? = nil
    }
    private var pendingSubmissions: [UUID: PendingSubmission] = [:]
    private var cancelledSubmissionKey: String { "aim.chat.cancelled-unsent.v1." + accountID.uuidString.lowercased() }
    // Independent of the history snapshot: cancellation must survive a failed history write.
    private var cancelledSubmissionIDs: Set<String> { Set(UserDefaults.standard.stringArray(forKey: cancelledSubmissionKey) ?? []) }
    private func submissionFingerprint(projectID: UUID?) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let skills = AIMSkillsStore.shared.accountID == accountID ? AIMSkillsStore.shared.installed.filter { $0.enabled && $0.modelInvocable }.sorted { $0.name < $1.name } : []
        let project = projects.first { $0.id == projectID }
        var bytes = (try? encoder.encode(preferences)) ?? Data()
        bytes.append((try? encoder.encode(skills)) ?? Data())
        bytes.append(Data(String(UserDefaults.standard.integer(forKey: researchCredentialRevisionKey)).utf8))
        bytes.append(Data((accountID.uuidString + (projectID?.uuidString ?? "none") + (project?.memoryScope.rawValue ?? "missing-project") + profileInstructions + (project?.instructions ?? "") + String(memory.revision ?? 0) + String(describing: customOutputTokenLimit)).utf8))
        bytes.append(Data((String(UserDefaults.standard.bool(forKey: "aim.budget.enabled")) + String(UserDefaults.standard.double(forKey: "aim.budget.limit")) + String(requiresVerifiedWebSearchBudget)).utf8))
        if let projectID {
            do {
                guard let sourceStore = projectDocuments.sourceStore else { return "unreadable-project-sources" }
                let sources = try sourceStore.records(projectID: projectID).sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    ["id": $0.id.uuidString, "enabled": String($0.useInChat), "bytes": String($0.textBytes), "name": $0.name]
                }
                bytes.append(try encoder.encode(sources))
            } catch { return "unreadable-project-sources" }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// Called only with a live account session, in the unlocked foreground.
    func resumePendingSubmissions() {
        guard canPersist, executionTarget == .thisDevice else { return }
        for pending in pendingSubmissions.values where responseTasks[pending.conversationID] == nil {
            guard pending.permissionFingerprint == submissionFingerprint(projectID: pending.projectID),
                  let catalogModel = nativeCatalogModels[pending.provider]?.first(where: { $0.id == pending.model.id && $0.isChatModel }),
                  executionModel(catalogModel, provider: pending.provider) == pending.model,
                  let apiKey = try? key(for: pending.provider), !apiKey.isEmpty else {
                setResponseError("The unsent request is preserved. Review its provider, model, permissions and budget before resuming.", conversationID: pending.conversationID)
                continue
            }
            beginSubmission(pending, apiKey: apiKey)
        }
    }
    /// Concealment suspends unsent work without discarding the user's queued request.
    func suspendForProtection() {
        memoryCaptureGeneration = UUID()
        for id in Array(responseTasks.keys) {
            responseGenerations.removeValue(forKey: id); responseTasks[id]?.cancel()
        }
    }
    private var visualDraftReports: [UUID: VisualAnalysisReport] = [:]
    func inputAttachments(_ id: UUID) -> [NativeChatAttachment] { inputDrafts[id] ?? [] }
    func inputReferences(_ id: UUID) -> [RemoteAttachmentReference] { inputAttachments(id).map(\.reference) }
    func setInputReferences(_ values: [RemoteAttachmentReference], id: UUID) {
        let prior = inputDrafts[id]
        inputDrafts[id] = inputAttachments(id).filter { value in values.contains { $0.transferID == value.id.uuidString } }
        if !persist() { inputDrafts[id] = prior }
    }
    func prepareInput(_ data: Data, name: String, mimeType: String, draftID: UUID, options: VideoPreparationOptions = .init()) async -> RemoteAttachmentReference? {
        guard canPersist || usesNativeUITestFixture, inputAttachments(draftID).count < 4, data.count <= (["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) ? 250_000_000 : RemoteAttachmentRules.maximumSize) else { return nil }
        let parent = usesNativeUITestFixture ? URL.temporaryDirectory.appending(path: "aim-ui-inputs") : url.deletingLastPathComponent()
        let sourceDevice = deviceID, sourceName = UIDevice.current.name, owner = accountID
        let destination = parent.appending(path: "Inputs/" + UUID().uuidString, directoryHint: .isDirectory)
        do {
            let preparation = Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: destination) }
                try Task.checkCancellation()
                let source = destination.appendingPathComponent((name as NSString).lastPathComponent)
                try data.write(to: source, options: [.atomic, .completeFileProtection])
                if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                    let video = try await VideoPreparationService.prepare(source, mode: options.mode, range: try options.range(), originDeviceID: sourceDevice, originDeviceName: sourceName)
                    _ = try PrivateInputMedia.retain(source, root: parent, accountID: owner, attachmentID: video.id)
                    return NativeChatAttachment(id: video.id, name: name, kind: .document, mimeType: "text/plain", text: video.context, video: video)
                }
                let input = try NativeChatAttachment.prepare(source)
                _ = try PrivateInputMedia.retain(source, root: parent, accountID: owner, attachmentID: input.id)
                return input
            }
            let value = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            try NativeChatAttachment.validate(inputAttachments(draftID) + [value])
            let previous = inputDrafts[draftID]
            inputDrafts[draftID, default: []].append(value)
            guard persist() else { inputDrafts[draftID] = previous; try? FileManager.default.removeItem(at: destination); return nil }
            return value.reference
        } catch { errorMessage = error.localizedDescription; try? FileManager.default.removeItem(at: destination); return nil }
    }
    func originalInputURL(_ id: UUID) -> URL? { PrivateInputMedia.original(root: url.deletingLastPathComponent(), accountID: accountID, attachmentID: id) }
    var isSending: Bool { selectedID.map { responseTasks[$0] != nil || pendingSubmissions[$0] != nil } ?? false }
    var isAnySending: Bool { !responseTasks.isEmpty || !pendingSubmissions.isEmpty }
    func isSending(conversationID: UUID) -> Bool { responseTasks[conversationID] != nil || pendingSubmissions[conversationID] != nil }
    var draftText: String {
        get { draftText(conversationID: selectedID) }
        set { setDraftText(newValue, conversationID: selectedID) }
    }
    func draftIdentifier(conversationID: UUID?) -> UUID { conversationID ?? newDraftID }
    /// Read-only identity for an interactive navigation preview. Never changes the active draft.
    func draftIdentifier(projectID: UUID) -> UUID { projectDraftIDs[projectID] ?? projectID }
    func draftText(conversationID: UUID?) -> String { drafts[draftIdentifier(conversationID: conversationID)] ?? "" }
    func setDraftText(_ text: String, conversationID: UUID?) { drafts[conversationID ?? newDraftID] = text; persist() }
    var requiresVerifiedWebSearchBudget: Bool { UserDefaults.standard.bool(forKey: "aim.budget.strict-web-search") }
    var completedUnknownBudgetCharges: Int {
        DeviceBudgetRules.completedUnknownCostCount(records: activityRecords, accountID: accountID, deviceID: deviceID)
    }
    var isLoadingModels = false
    // A new error always invalidates its previous recovery action; localized text is never matched.
    var errorMessage: String? { didSet { errorNoticeKind = nil } }
    private(set) var errorNoticeKind: NativeChatErrorNoticeKind?
    private var responseErrors: [UUID: String] = [:]
    var syncMessage: String?
    private(set) var readReceipts = ConversationReadReceipts()
    var readReceiptRevision = 0
    private var syncingReadReceipts = false
    var connectedProviders: Set<ChatProvider> = []
    private let credentials: any SecureStoring
    private let transport: NativeChatTransport
    private let skillTransport: NativeSkillChatTransport
    private let researchEstimateDate: @Sendable () -> Date
    private let researchPerform: AIMResearchSession.Perform
    private let publicCatalogTimeout: Duration
    private let sync: (any AccountContentSyncing)?
    private let notifyCompletion: @MainActor (UUID, UUID, UUID, UUID, AIMNotificationCategory) async -> Void
    let accountID: UUID
    var activityRecords: [AccountActivityRecord] = []
    var memory = AccountMemorySnapshot()
    var lastActivitySync: Date?
    var accountDataError: String?
    var memoryCaptureMessage: String?
    private var memoryCaptureIDs: Set<UUID> = []
    var isCapturingMemory: Bool { !memoryCaptureIDs.isEmpty }
    var notificationService: AccountNotificationService?
    private var activityService: AccountActivityService?
    private var memoryService: AccountMemoryService?
    let deviceID: String = {
        let key = "aim.activity.installation"; if let id = UserDefaults.standard.string(forKey: key) { return id }; let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: key); return id
    }()
    var summary: AccountActivitySummary { .init(records: activityRecords, accountID: accountID) }
    private let url: URL
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    private var speechGeneration = UUID()
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var speechPlayer: AVAudioPlayer?
    @ObservationIgnored private var voiceInstance: AIMVoiceController?
    var voiceController: AIMVoiceController { if let voiceInstance { return voiceInstance }; let value = AIMVoiceController(chat: self); voiceInstance = value; return value }
    private var modelGeneration = UUID()
    private var memoryCaptureGeneration = UUID()
    private var loadingSnapshot = true
    private var canPersist = true
    var usesNativeUITestFixture = false
    private var savingPreferences = false
    private var syncing = false
    private var syncRequested = false
    private var syncingAccountData = false
    private var revisions: [UUID: Int] = [:]
    private var dirty: Set<UUID> = []
    private var favoritesBase: Set<String> = []
    private var projectDirty: Set<UUID> = []
    private var deletedProjects: Set<UUID> = []
    private var projectDraftIDs: [UUID: UUID] = [:]
    private var favoritesDirty = false
    private var preferencesDirty = false
    private let preferencesID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C102")!
    private let favoritesID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C101")!
    private let pinsID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C103")!
    init(accountID: UUID, sync: (any AccountContentSyncing)? = nil, credentials: (any SecureStoring)? = nil,
         transport: NativeChatTransport? = nil,
         publicCatalogTimeout: Duration = .seconds(10),
         skillTransport: NativeSkillChatTransport? = nil,
         researchPerform: AIMResearchSession.Perform? = nil,
         researchEstimateDate: @escaping @Sendable () -> Date = { .now },
         notifyCompletion: @escaping @MainActor (UUID, UUID, UUID, UUID, AIMNotificationCategory) async -> Void = { owner, event, task, conversation, category in
             await AIMNotificationCenter.shared.notify(accountID: owner, event: event, task: task, conversation: conversation, category: category)
         }) {
        self.accountID = accountID; self.sync = sync
        self.notifyCompletion = notifyCompletion
        notificationService = (sync as? AccountContentSyncService)?.notifications
        if let sync { activityService = AccountActivityService(accountID: accountID, service: sync); memoryService = AccountMemoryService(accountID: accountID, service: sync) }
        self.credentials = credentials ?? KeychainSecureStore(service: (Bundle.main.bundleIdentifier ?? "com.aimai.ios") + ".providers")
        self.transport = transport ?? NativeChatTransport()
        self.skillTransport = skillTransport ?? NativeSkillChatTransport()
        let researchClient = AIMResearchHTTPClient()
        self.researchPerform = researchPerform ?? { try await researchClient.perform($0) }
        self.researchEstimateDate = researchEstimateDate
        self.publicCatalogTimeout = publicCatalogTimeout
        let directory = URL.applicationSupportDirectory.appending(path: "Chat/\(accountID.uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: "conversations.json")
        projectDocuments = AIMProjectDocumentLibrary(directory: directory)
        // Both names must identify the same initial general draft before the first snapshot is written.
        generalDraftID = newDraftID
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
                activityRecords = snapshot.activityRecords ?? []; memory = snapshot.memory ?? .init(); lastActivitySync = snapshot.lastActivitySync
                pendingSubmissions = (snapshot.pendingSubmissions ?? [:]).filter { !cancelledSubmissionIDs.contains($0.value.assistant.id.uuidString) }
                visualDraftReports = snapshot.visualDraftReports ?? [:]
                inputDrafts = snapshot.inputDrafts ?? [:]; drafts = snapshot.drafts ?? [:]
                generalDraftID = snapshot.generalDraftID ?? snapshot.newDraftID ?? newDraftID
                // Older builds could persist an unused general UUID alongside the real initial draft.
                // Recover only an occupied, unscoped draft; never borrow a project's or a chat's draft.
                if let legacyDraftID = snapshot.newDraftID, legacyDraftID != generalDraftID,
                   !(snapshot.projectDraftIDs?.values.contains(legacyDraftID) ?? false),
                   !snapshot.conversations.contains(where: { $0.id == legacyDraftID }),
                   (drafts[generalDraftID] ?? "").isEmpty, (inputDrafts[generalDraftID] ?? []).isEmpty,
                   !(drafts[legacyDraftID] ?? "").isEmpty || !(inputDrafts[legacyDraftID] ?? []).isEmpty {
                    generalDraftID = legacyDraftID
                }
                newDraftID = generalDraftID
                readReceipts = snapshot.readReceipts ?? .init()
                executionTarget = snapshot.executionTarget ?? .thisDevice
                conversations = snapshot.conversations; favorites = snapshot.favorites; revisions = snapshot.revisions
                dirty = snapshot.dirty; favoritesDirty = snapshot.favoritesDirty
                projects = snapshot.projects ?? []; projectDirty = snapshot.projectDirty ?? []
                deletedProjects = snapshot.deletedProjects ?? []; projectDraftIDs = snapshot.projectDraftIDs ?? [:]
                projects.removeAll { deletedProjects.contains($0.id) }
                favoritesBase = snapshot.favoritesBase ?? snapshot.favorites
                pinnedModels = snapshot.pinnedModels ?? []; pinnedBase = snapshot.pinnedBase ?? pinnedModels; pinsDirty = snapshot.pinsDirty ?? false
                preferences = snapshot.preferences ?? .init(); preferencesDirty = snapshot.preferencesDirty ?? false
            }
        } catch { canPersist = false; errorMessage = "Saved Chat data could not be read. It has been preserved; export or recover it before adding new data." }
        for index in conversations.indices {
            guard let turn = conversations[index].turns.last, cancelledSubmissionIDs.contains(turn.id.uuidString) else { continue }
            conversations[index].lastTurnStatus = "cancelled"
            if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == turn.id }) {
                conversations[index].messages[messageIndex].actions = conversations[index].messages[messageIndex].actions?.map { action in
                    var value = action
                    if value.name == "network" { value.state = .cancelled; value.finishedAt = value.finishedAt ?? .now }
                    return value
                }
            }
        }
        for index in conversations.indices where pendingSubmissions[conversations[index].id] == nil {
            guard conversations[index].lastTurnStatus == "running", let turn = conversations[index].turns.last,
                  turn.completedAt == nil,
                  activityRecords.contains(where: { $0.id == turn.id && $0.deviceID == deviceID && $0.completedAt == nil }),
                  let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == turn.id }) else { continue }
            let action = ConversationAction(id: turn.id.uuidString + ":interrupted", conversationID: conversations[index].id,
                turnID: turn.id, ordinal: Int.max, name: "Provider result uncertain · review before retrying", state: .needsReview,
                detail: "AIM was interrupted after submission began. The partial response is preserved and this request will not be submitted again automatically.")
            conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, [action])
            conversations[index].lastTurnStatus = "failed"; dirty.insert(conversations[index].id)
        }
        for cachedProvider in ChatProvider.allCases {
            let cacheURL = url.deletingLastPathComponent().appendingPathComponent("catalog-" + cachedProvider.rawValue + ".json")
            if let bytes = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([ChatModel].self, from: bytes) {
                nativeCatalogModels[cachedProvider] = cached; catalogModels[cachedProvider] = cached
            }
        }
        for provider in ChatProvider.allCases where provider != .local && provider != .chatgpt {
            do { if try key(for: provider)?.isEmpty == false { connectedProviders.insert(provider) } }
            catch { if canPersist { errorMessage = Self.providerFailure(error) } }
        }
        if let first = ChatProvider.allCases.first(where: { connectedProviders.contains($0) }) { provider = first }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AIM_UI_TEST_NATIVE_CHAT"] == "1" {
            usesNativeUITestFixture = true; canPersist = false
            // Deliberately synthetic facts for UI qualification; never a live catalog.
            func fixtureModel(_ id: String, _ name: String) -> ChatModel {
                var model = ChatModel(id: id, name: name, contextLength: 128_000, inputModalities: ["text", "image"], created: 1_704_067_200, maxOutputTokens: 64_000)
                model.summary = "Synthetic UI test metadata. These example prices, dates and capacities do not describe the real provider model."
                model.pricing = .init(prompt: "0.00000125", completion: "0.000005", inputCacheRead: "0.00000025")
                model.architecture = .init(inputModalities: ["text", "image"], outputModalities: ["text"])
                model.supportedParameters = ["tools", "reasoning"]
                model.reasoning = .init(mandatory: false, defaultEnabled: false, supportedEfforts: ["low", "medium", "high"], defaultEffort: "medium")
                return model
            }
            let routed = [fixtureModel("openai/gpt-4.1", "GPT-4.1"), fixtureModel("anthropic/claude-sonnet-4-6", "Claude Sonnet 4.6")]
            let direct = [fixtureModel("claude-sonnet-4-6", "Claude Sonnet 4.6")]
            connectedProviders = [.openRouter, .anthropic]; catalogModels = [.openRouter: routed, .anthropic: direct]
            provider = .openRouter; modelID = routed[0].id; models = routed
            favorites = Set([ChatProvider.openRouter.rawValue + ":" + routed[0].id,
                             ChatProvider.openRouter.rawValue + ":" + routed[1].id,
                             ChatProvider.anthropic.rawValue + ":" + direct[0].id])
            pinnedModels = [ChatProvider.openRouter.rawValue + ":" + routed[1].id]
            var conversation = NativeChatConversation(id: UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C201")!,
                title: "Native Chat fixture", provider: provider, modelID: modelID, messages: [
                    .init(role: .user, text: "Can you help me plan the next AIM update?"),
                    .init(role: .assistant, text: "Yes. Let’s start with the settings, then check the conversations and model picker.\n\nYour current provider and execution target stay selected when you open another conversation.")])
            if ProcessInfo.processInfo.environment["AIM_UI_TEST_LONG_NATIVE_CHAT"] == "1" {
                conversation.messages += (1...30).map { index in
                    NativeChatMessage(role: .assistant, text: "Reading marker \(index). Keep this paragraph in place while opening the composer. This synthetic conversation verifies scrolling behind the floating controls.")
                }
            }
            if ProcessInfo.processInfo.environment["AIM_UI_TEST_SOURCES_ACTIONS"] == "1", let index = conversation.messages.indices.last {
                let turn = conversation.messages[index].id
                conversation.messages[index].text = "A short answer [1]."
                conversation.messages[index].sources = [ConversationSource(url: "https://example.com/page", title: "Example source", references: [1])!]
                conversation.messages[index].actions = [.init(id: "fixture:search", conversationID: conversation.id, turnID: turn, ordinal: 0, name: "web_search", state: .completed, startedAt: .now.addingTimeInterval(-2), finishedAt: .now, input: "actual search query", output: "actual search output")]
            }
            if ProcessInfo.processInfo.environment["AIM_UI_TEST_TIMELINE"] == "1", let index = conversation.messages.indices.last {
                let turn = conversation.messages[index].id, start = Date.now.addingTimeInterval(-90)
                let intermediate = "I’ll check the official announcements first.\n\n", final = "GPT-6 Luna powers the Decisions API, billed per input token [1]."
                var builder = TurnTimelineBuilder(startedAt: start)
                builder.reasoning("**Finding reliable sources**\n\nThis is a recent announcement: official documentation first.", at: start)
                builder.text(intermediate, at: start.addingTimeInterval(6))
                var actions: [ConversationAction] = []
                for (offset, query) in ["Decisions API", "gpt-6-luna pricing", "Decisions public beta", "Luna latency", "Decisions schema", "OpenRouter Luna", "Luna release notes"].enumerated() {
                    builder.action("web:fixture\(offset)", at: start.addingTimeInterval(Double(8 + offset * 3)))
                    actions.append(.init(id: "web:fixture\(offset)", conversationID: conversation.id, turnID: turn, ordinal: offset, name: "web_search", state: .completed,
                                         startedAt: start.addingTimeInterval(Double(8 + offset * 3)), finishedAt: start.addingTimeInterval(Double(10 + offset * 3)), input: query, output: "3 results"))
                }
                builder.text(final, at: start.addingTimeInterval(48)); builder.finish(at: start.addingTimeInterval(72))
                conversation.messages[index].text = intermediate + final
                conversation.messages[index].actions = actions
                conversation.messages[index].sources = [ConversationSource(url: "https://developers.openai.com/api/docs/guides/decisions", title: "Decisions", references: [1])!]
                conversation.messages[index].timeline = builder.timeline
            }
            conversations = [conversation]; selectedID = conversation.id; executionTarget = .thisDevice
            if ProcessInfo.processInfo.environment["AIM_UI_TEST_PROJECT_HOME"] == "1" {
                let project = NativeChatProject(id: UUID(uuidString: "E16A719B-AFE5-4B99-8198-6CD3C3A71421")!, name: "Project Home Fixture", updatedAt: .now.addingTimeInterval(-125))
                var scoped = conversation; scoped.id = UUID(uuidString: "E16A719B-AFE5-4B99-8198-6CD3C3A71422")!
                scoped.title = "Project scoped conversation"; scoped.projectID = project.id.uuidString; scoped.updatedAt = .now.addingTimeInterval(-125)
                if let index = scoped.messages.lastIndex(where: { $0.role == .assistant }) {
                    scoped.messages[index].text = "test 45\n\nLa suite de la réponse reste lisible."
                }
                if ProcessInfo.processInfo.environment["AIM_UI_TEST_PROJECT_CITATION"] == "1" {
                    let sourceID = UUID(uuidString: "A47BF229-11FD-4725-93EE-625256D13400")!
                    scoped.messages[0].attachments = [.init(id: sourceID, name: "Test.txt", kind: .document, mimeType: "text/plain",
                        text: "[source:a47bf229-11fd-4725-93ee-625256d13400#1]\nSynthetic project reference", projectSourceID: sourceID)]
                    scoped.messages[scoped.messages.count - 1].text = "Reference: source:a47bf229-11fd-4725-93ee-625256d13400#1 (Test.txt, chunk 0)"
                    scoped.messages[scoped.messages.count - 1].webSearchUsage = .init()
                }
                var outside = conversation; outside.title = "Outside project conversation"; outside.projectID = nil
                projects = [project]; conversations = [scoped, outside]; selectedID = nil
            }
            if ProcessInfo.processInfo.environment["AIM_UI_TEST_WEB_BUDGET_ERROR"] == "1" || ProcessInfo.processInfo.environment["AIM_UI_TEST_ESTIMATED_WEB_BUDGET"] == "1" {
                // Process-only defaults: fixture qualification must never alter a saved device budget.
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments["aim.budget.enabled"] = true
                arguments["aim.budget.limit"] = 5.0
                arguments["aim.budget.strict-web-search"] = ProcessInfo.processInfo.environment["AIM_UI_TEST_WEB_BUDGET_ERROR"] == "1"
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                let glm = fixtureModel("z-ai/glm-5.3", "GLM 5.3")
                provider = .openRouter; modelID = glm.id; models = [glm]; catalogModels[.openRouter] = [glm]
                preferences.automaticWebSearch = true
                drafts[selectedID ?? newDraftID] = "Synthetic budgeted question"
                if ProcessInfo.processInfo.environment["AIM_UI_TEST_WEB_BUDGET_ERROR"] == "1" {
                    errorMessage = String(localized: "chat.error.web_budget.message")
                    errorNoticeKind = .webSearchBudget
                }
            }
        }
        #endif
        loadingSnapshot = false
    }
    var selected: NativeChatConversation? { conversations.first(where: { $0.id == selectedID }) }
    var modelName: String { models.first(where: { $0.id == modelID })?.name ?? (modelID.isEmpty ? "Choose model" : modelID) }
    var totalTurns: Int { Set(conversations.flatMap { $0.turns.filter { $0.completedAt != nil }.map(\.id) }).count }
    private var uniqueTurns: [NativeChatTurn] {
        var seen: Set<UUID> = []
        return conversations.flatMap(\.turns).filter { seen.insert($0.id).inserted }
    }
    var estimatedUSD: Double { uniqueTurns.compactMap(\.estimatedUSD).reduce(0, +) }
    var activity: [Date: Int] {
        Dictionary(uniqueTurns.compactMap(\.completedAt).map { (Calendar.current.startOfDay(for: $0), 1) }, uniquingKeysWith: +)
    }
    func catalog(for provider: ChatProvider, force: Bool = false) async throws -> [ChatModel] {
        if usesNativeUITestFixture { return catalogModels[provider] ?? [] }
        let cacheURL = url.deletingLastPathComponent().appendingPathComponent("catalog-" + provider.rawValue + ".json")
        if let bytes = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([ChatModel].self, from: bytes) {
            nativeCatalogModels[provider] = cached
            if catalogModels[provider] == nil { catalogModels[provider] = cached }
            let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if !force && Date.now.timeIntervalSince(modified) < 3_600 { return cached }
        }
        if provider != .openRouter && provider != .local && provider != .chatgpt { startPublicModelCatalog() }
        let direct = try await transport.models(provider: provider, key: provider == .openRouter ? nil : key(for: provider))
        if let bytes = try? JSONEncoder().encode(direct) { try? bytes.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen]) }
        return await cacheCatalog(direct, provider: provider)
    }
    private func startPublicModelCatalog() {
        guard publicModelCatalog == nil, publicModelCatalogTask == nil else { return }
        let transport = transport, timeout = publicCatalogTimeout
        // One optional public GET per store session. Its deadline never limits
        // a generation or changes the provider's own model-list timeout.
        publicModelCatalogTask = Task { await Self.fetchPublicModelCatalog(transport: transport, timeout: timeout) }
    }
    private nonisolated static func fetchPublicModelCatalog(transport: NativeChatTransport, timeout: Duration) async -> [ChatModel]? {
        await withTaskGroup(of: [ChatModel]?.self) { group in
            group.addTask { try? await transport.models(provider: .openRouter, key: nil) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
    private func cacheCatalog(_ direct: [ChatModel], provider: ChatProvider) async -> [ChatModel] {
        nativeCatalogModels[provider] = direct
        if provider == .openRouter {
            publicModelCatalog = direct; catalogModels[provider] = direct; return direct
        }
        // This GET sends no credential. Cache failures for the session too, so
        // an unavailable reference service does not delay every navigation.
        startPublicModelCatalog()
        let reference: [ChatModel]?
        if let publicModelCatalog { reference = publicModelCatalog }
        else { reference = await publicModelCatalogTask?.value }
        if let reference { publicModelCatalog = reference }
        let enriched = reference.map { ModelCatalogDetails.enrich(direct, provider: provider, publicModels: $0) } ?? direct
        catalogModels[provider] = enriched
        return enriched
    }
    private func executionModel(_ model: ChatModel, provider: ChatProvider) -> ChatModel {
        nativeCatalogModels[provider]?.first(where: { $0.id == model.id }) ?? model
    }
    func modelPricingIsReference(provider: ChatProvider, modelID: String) -> Bool {
        guard provider != .openRouter,
              let native = nativeCatalogModels[provider]?.first(where: { $0.id == modelID }) else { return false }
        return native.pricing == nil && catalogModels[provider]?.first(where: { $0.id == modelID })?.pricing != nil
    }
    func loadModelCatalogs(force: Bool = false) async {
        for connected in ChatProvider.allCases where connectedProviders.contains(connected) {
            do { _ = try await catalog(for: connected, force: force) }
            catch { errorMessage = Self.providerFailure(error) }
        }
    }
    func preferredRoute(_ canonical: String) -> String? {
        UserDefaults.standard.string(forKey: CanonicalModelRouting.preferenceKey(account: accountID, target: subagentTargetID, model: canonical))
    }
    func rememberRoute(provider: String, modelID: String) {
        UserDefaults.standard.set(provider, forKey: CanonicalModelRouting.preferenceKey(account: accountID, target: subagentTargetID, model: CanonicalModelRouting.identity(modelID, provider: provider)))
    }
    @discardableResult func selectModel(provider: ChatProvider, modelID: String) async -> Bool {
        guard connectedProviders.contains(provider) else { errorMessage = ChatServiceError.missingKey.localizedDescription; return false }
        let generation = UUID(); modelGeneration = generation
        do {
            let catalog = try await self.catalog(for: provider)
            guard modelGeneration == generation else { return false }
            guard catalog.contains(where: { $0.id == modelID }) else { errorMessage = "This model is no longer available from the selected provider."; return false }
            self.provider = provider; self.modelID = modelID; models = catalog; modelGeneration = UUID(); isLoadingModels = false; errorMessage = nil; rememberRoute(provider: provider.rawValue, modelID: modelID); return true
        } catch { errorMessage = Self.providerFailure(error); return false }
    }
    func syncAccountData() async {
        guard canPersist, !syncingAccountData else { return }; syncingAccountData = true
        defer { syncingAccountData = false }
        do {
            if let activityService { let synced = try await activityService.synchronize(activityRecords, deviceID: deviceID); activityRecords = AccountActivityRecord.merge(synced + activityRecords, accountID: accountID); lastActivitySync = .now }
            if let memoryService {
                let loaded = try await memoryService.load()
                // A refresh may have started before a concurrent edit completed.
                if (loaded.revision ?? 0) >= (memory.revision ?? 0) { memory = loaded }
            }
            accountDataError = nil; persist()
        } catch { accountDataError = error.localizedDescription }
    }
    func saveMemory(_ value: AccountMemorySnapshot) async -> Bool {
        guard canPersist else { accountDataError = AccountServiceError.unavailable.localizedDescription; return false }
        if value.enabled != memory.enabled { memoryCaptureGeneration = UUID() }
        do {
            let saved = try await storeMemory(value)
            if (saved.revision ?? 0) >= (memory.revision ?? 0) { memory = saved }
            persist(); accountDataError = nil; return true
        }
        catch { accountDataError = error.localizedDescription; return false }
    }
    private func loadStoredMemory() async throws -> AccountMemorySnapshot {
        if let memoryService { return try await memoryService.load() }
        return memory
    }
    private func storeMemory(_ value: AccountMemorySnapshot) async throws -> AccountMemorySnapshot {
        if let memoryService { return try await memoryService.save(value) }
        guard canPersist, value.entries.count <= 2000,
              Set(value.entries.map(\.id)).count == value.entries.count,
              value.entries.allSatisfy({ !$0.subject.isEmpty && $0.subject.count <= 128 && !$0.content.isEmpty && $0.content.utf8.count <= 8192 && ($0.confidence == nil || ($0.confidence!.isFinite && (0...1).contains($0.confidence!))) }) else { throw AccountServiceError.unavailable }
        guard (value.revision ?? 0) == (memory.revision ?? 0) else { throw AccountServiceError.conflict }
        let previous = memory
        var saved = value; saved.revision = (memory.revision ?? 0) + 1
        memory = saved
        guard persist() else { memory = previous; throw AccountServiceError.unavailable }
        return saved
    }
    func importActivity(_ rows: [AccountActivityRecord]) async -> Bool {
        guard canPersist, !syncingAccountData, rows.allSatisfy({ $0.accountID == accountID && $0.valid }) else {
            accountDataError = "This activity could not be imported into the current account. The original history is preserved."
            return false
        }
        let prior = activityRecords
        activityRecords = AccountActivityRecord.merge(activityRecords + rows, accountID: accountID)
        guard persist() else { activityRecords = prior; accountDataError = errorMessage; return false }
        await syncAccountData()
        return accountDataError == nil
    }
    @ObservationIgnored lazy var media = AIMMediaStore(accountID: accountID, sync: (sync as? AccountContentSyncService)?.media,
        key: { [weak self] route in try route == .openRouter ? self?.key(for: .openRouter) : self?.bflKey() },
        admission: { [weak self] job in
            guard let self, let bound = MediaCostPolicy.upperBound(for: job), self.budgetAdmits(bound) else { throw MediaGenerationError.strictBudgetUnavailable }
            try self.reserveMedia(job, bound: bound)
        },
        completion: { [weak self] job, asset in self?.appendMedia(job, asset: asset) },
        activity: { [weak self] job in self?.recordMedia(job) })
    var bflConnected: Bool { ((try? bflKey()) ?? nil)?.isEmpty == false }
    var bflStatus: String?
    func bflKey() throws -> String? {
        try credentials.readData(forKey: "\(accountID.uuidString).blackForestLabs").flatMap { String(data: $0, encoding: .utf8) }
    }
    func saveBFLKey(_ value: String) async -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { bflStatus = "Enter a valid API key."; return false }
        do {
            var request = URLRequest(url: URL(string: "https://api.bfl.ai/v1/credits")!)
            request.setValue(key, forHTTPHeaderField: "x-key")
            let data = try await MediaTransport().data(request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["credits"] is NSNumber else { throw MediaGenerationError.invalidResponse }
            try credentials.store(Data(key.utf8), forKey: "\(accountID.uuidString).blackForestLabs")
            bflStatus = "Validated on this iPhone"; return true
        } catch { bflStatus = error.localizedDescription; return false }
    }
    func disconnectBFL() {
        do { try credentials.removeData(forKey: "\(accountID.uuidString).blackForestLabs"); bflStatus = "Disconnected" }
        catch { bflStatus = "The key could not be removed." }
    }
    private func reserveMedia(_ job: MediaJob, bound: Double) throws {
        let previous = activityRecords
        let record = AccountActivityRecord(id: job.id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
            conversationID: job.conversationID, parentTaskID: job.id, provider: job.model.route.rawValue, modelID: job.model.id, mode: "chat",
            startedAt: job.createdAt, costUSD: bound, costState: .reserved, toolName: "media_" + job.model.kind.rawValue)
        activityRecords = AccountActivityRecord.merge(activityRecords + [record], accountID: accountID)
        guard persist() else { activityRecords = previous; throw MediaGenerationError.strictBudgetUnavailable }
    }
    private func recordMedia(_ job: MediaJob) {
        guard job.accountID == accountID else { return }
        if job.costUSD == nil, activityRecords.contains(where: { $0.id == job.id && $0.costState == .reserved }) { return }
        let finished = job.status == .completed || job.status == .failed
        let record = AccountActivityRecord(id: job.id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
            conversationID: job.conversationID, parentTaskID: job.id, provider: job.model.route.rawValue, modelID: job.model.id, mode: "chat",
            startedAt: job.createdAt, completedAt: finished ? job.updatedAt : nil, costUSD: job.costUSD,
            costState: job.costUSD == nil ? .unknown : (job.costConfirmed ? .confirmed : .estimated), toolName: "media_" + job.model.kind.rawValue)
        activityRecords = AccountActivityRecord.merge(activityRecords + [record], accountID: accountID)
        persist(); Task { await syncAccountData() }
    }
    private func appendMedia(_ job: MediaJob, asset: MediaAsset) {
        guard job.accountID == accountID, asset.accountID == accountID else { return }
        let id = job.conversationID ?? job.id
        var conversation = conversations.first { $0.id == id } ?? .init(id: id, title: String(job.prompt.prefix(80)), provider: .openRouter, modelID: job.model.id)
        guard !conversation.messages.contains(where: { $0.mediaAssetIDs?.contains(asset.id) == true }) else { return }
        conversation.messages.append(.init(id: job.id, role: .user, text: job.prompt, createdAt: job.createdAt))
        conversation.messages.append(.init(id: asset.id, role: .assistant, text: "", createdAt: asset.createdAt, mediaAssetIDs: [asset.id]))
        conversation.updatedAt = .now
        update(conversation); dirty.insert(id); persist(); Task { await synchronize() }
        if selectedID == nil { selectedID = id }
    }

    func key(for provider: ChatProvider) throws -> String? {
        guard let data = try credentials.readData(forKey: "\(accountID.uuidString).\(provider.rawValue)") else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private var researchCredentialRevisionKey: String { "aim.research.credentials.revision." + accountID.uuidString.lowercased() }
    private func researchKey(for mode: AIMResearchMode) throws -> String? {
        guard mode.isOrchestrated, let data = try credentials.readData(forKey: accountID.uuidString + "." + mode.credentialKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Saves only this profile's selected search key. No validation request or model call is made.
    func saveResearchKey(_ value: String, mode: AIMResearchMode) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode.isOrchestrated, !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: \.isWhitespace), !key.contains("\0") else { throw AIMResearchError.missingKey }
        try credentials.store(Data(key.utf8), forKey: accountID.uuidString + "." + mode.credentialKey)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: researchCredentialRevisionKey) + 1, forKey: researchCredentialRevisionKey)
    }
    func removeResearchKey(mode: AIMResearchMode) throws {
        guard mode.isOrchestrated else { return }
        try credentials.removeData(forKey: accountID.uuidString + "." + mode.credentialKey)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: researchCredentialRevisionKey) + 1, forKey: researchCredentialRevisionKey)
    }
    /// Every real search API attempt has its own attributed cost record. Cache hits and direct page
    /// reads do not manufacture billable API calls. An absent receipt stays nil or an explicit estimate.
    private func performResearchHTTP(_ operation: AIMResearchHTTPRequest, conversationID: UUID, parentID: UUID,
                                     generation: UUID, fingerprint: String) async throws -> AIMResearchHTTPResponse {
        guard responseGenerations[conversationID] == generation,
              submissionFingerprint(projectID: conversations.first { $0.id == conversationID }?.projectID.flatMap(UUID.init(uuidString:))) == fingerprint else { throw CancellationError() }
        if operation.kind == .page {
            let value = try await researchPerform(operation)
            guard responseGenerations[conversationID] == generation else { throw CancellationError() }
            return value
        }
        let estimate = AIMResearchPricing.searchEstimateUSD(mode: operation.mode, at: researchEstimateDate()), attempt = UUID()
        if UserDefaults.standard.bool(forKey: "aim.budget.enabled") {
            guard !requiresVerifiedWebSearchBudget, let estimate else { throw AIMResearchError.strictBudget }
            if let failure = budgetFailure(estimate) { throw ResearchAdmissionFailure(message: budgetFailureMessage(failure)) }
        }
        let before = activityRecords
        activityRecords.append(.init(id: attempt, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
            conversationID: conversationID, parentTaskID: parentID, kind: .cost, provider: operation.mode.credentialKey,
            modelID: "search", mode: "research", startedAt: .now, costUSD: estimate, costState: .reserved, toolName: "web_search"))
        guard persist() else { activityRecords = before; throw NativeDocumentError.limit }
        do {
            let value = try await researchPerform(operation)
            if let index = activityRecords.firstIndex(where: { $0.id == attempt }) {
                let reported = value.externalAPICostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                activityRecords[index].costUSD = reported ?? estimate
                activityRecords[index].costState = reported != nil ? .confirmed : estimate != nil ? .estimated : .unknown
                activityRecords[index].costEstimateBasis = reported == nil && estimate != nil ? "published-search-rate-2026-10-17" : nil
                activityRecords[index].completedAt = .now; activityRecords[index].updatedAt = .now
                _ = persist()
            }
            guard responseGenerations[conversationID] == generation else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        } catch {
            if let index = activityRecords.firstIndex(where: { $0.id == attempt }), activityRecords[index].completedAt == nil {
                activityRecords[index].costUSD = nil; activityRecords[index].costState = .unknown
                activityRecords[index].completedAt = .now; activityRecords[index].updatedAt = .now
                _ = persist()
            }
            throw error
        }
    }
    private struct ResearchAdmissionFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
    func saveKey(_ value: String, provider: ChatProvider) async -> Bool {
        guard provider != .local && provider != .chatgpt else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { errorMessage = ChatServiceError.missingKey.localizedDescription; return false }
        do {
            try await transport.validateKey(provider: provider, key: key)
            if provider != .openRouter { startPublicModelCatalog() }
            let direct = try await transport.models(provider: provider, key: provider == .openRouter ? nil : key)
            let catalog = await cacheCatalog(direct, provider: provider)
            try credentials.store(Data(key.utf8), forKey: "\(accountID.uuidString).\(provider.rawValue)")
            connectedProviders.insert(provider); catalogModels[provider] = catalog
            if self.provider == provider { models = catalog; if !catalog.contains(where: { $0.id == modelID }) { modelID = "" } }
            errorMessage = nil; return true
        } catch { errorMessage = Self.providerFailure(error); return false }
    }
    func removeKey(_ provider: ChatProvider) {
        do {
            try credentials.removeData(forKey: "\(accountID.uuidString).\(provider.rawValue)"); connectedProviders.remove(provider); catalogModels.removeValue(forKey: provider); nativeCatalogModels.removeValue(forKey: provider)
            if self.provider == provider { models = []; modelID = "" }; errorMessage = nil
        } catch { errorMessage = "The provider key could not be removed." }
    }
    func loadModels() async {
        if usesNativeUITestFixture { models = catalogModels[provider] ?? []; return }
        let generation = UUID(); modelGeneration = generation
        isLoadingModels = true; errorMessage = nil
        let selectedProvider = provider
        defer { if modelGeneration == generation { isLoadingModels = false } }
        do {
            let catalog = try await self.catalog(for: selectedProvider)
            guard provider == selectedProvider, modelGeneration == generation else { return }; models = catalog
            reconcileLegacyBudgetEstimates()
        } catch { if provider == selectedProvider, modelGeneration == generation { models = []; errorMessage = Self.providerFailure(error) } }
    }
    private static func providerFailure(_ error: Error) -> String {
        if error is KeychainStoreError { return "The provider key could not be accessed securely. Unlock your iPhone and try again." }
        if let error = error as? ChatServiceError { return error.localizedDescription }
        if error is URLError { return "The provider could not be reached. Check your connection and try again." }
        return "The provider connection could not be checked. Try again or update its key."
    }
    func selectProvider(_ provider: ChatProvider) async {
        guard self.provider != provider else { return }
        self.provider = provider; modelID = ""; models = []; await loadModels()
    }
    var searchSessions: [RemoteSession] {
        conversations.map { item in
            RemoteSession(id: item.id.uuidString, machineID: "this-device", mode: .chat, title: item.title, workspace: nil,
                modelID: item.modelID, approvalMode: nil, status: pendingSubmissions[item.id] != nil ? "queued" : responseTasks[item.id] != nil ? "running" : (responseErrors[item.id] != nil && item.lastTurnStatus != "cancelled") || item.lastTurnStatus == "failed" || item.lastTurnStatus == "running" ? "failed" : "idle", messageCount: item.messages.count,
                updatedAt: item.updatedAt, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: item.turns.last?.completedAt == nil,
                projectID: item.projectID, executionDeviceIDs: item.executionDeviceIDs, latestResponseVersion: item.latestResponseVersion)
        }
    }
    func conversationStatus(session: RemoteSession) -> ConversationActivityState {
        ConversationActivityState.resolve(status: session.status, latestResponse: session.latestResponseVersion, read: readReceipts.contains(conversationID: session.id, response: session.latestResponseVersion))
    }
    func acknowledge(session: RemoteSession, loadedResponseIDs: Set<String>) {
        guard !session.readState.blocksReading, let response = session.latestResponseVersion,
              Set(loadedResponseIDs.map(AccountConversationIdentity.normalized)).contains(response.id),
              !readReceipts.contains(conversationID: session.id, response: response) else { return }
        readReceipts.acknowledge(conversationID: session.id, response: response); readReceiptRevision += 1
        persist(); Task { await synchronizeReadReceipts() }
    }
    func synchronizeReadReceipts() async {
        guard let sync, !usesNativeUITestFixture, !syncingReadReceipts else { return }
        syncingReadReceipts = true; defer { syncingReadReceipts = false }
        do {
            let owner = accountID
            let incoming = try await ConversationReadReceiptSync.synchronize(readReceipts, accountID: owner, service: sync, currentAccount: { owner })
            let merged = readReceipts.merging(incoming)
            if merged != readReceipts { readReceipts = merged; readReceiptRevision += 1; persist() }
        } catch { syncMessage = "Read state is saved on this iPhone and will sync when the account connection returns." }
    }
    func search(_ query: String) -> [RemoteSession] {
        let ids = Set(conversations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) } }.map { $0.id.uuidString })
        return searchSessions.filter { ids.contains($0.id) }
    }
    func newConversation() {
        if selectedProjectID == nil { generalDraftID = newDraftID }
        selectedID = nil; selectedProjectID = nil; newDraftID = generalDraftID; errorMessage = nil
        persist()
    }
    func open(_ conversation: NativeChatConversation) async {
        // Opening history never changes the user's last execution/provider/model choice.
        selectedID = conversation.id; errorMessage = responseErrors[conversation.id]
    }
    var preferencesRevision: Int { revisions[preferencesID] ?? 0 }
    /// Save against the revision captured when the editor opened, without a refresh advancing it.
    func savePreferences(_ value: AccountChatPreferences, baseline: AccountChatPreferences, revision: Int) async -> Bool {
        guard canPersist, !savingPreferences, !syncing, preferences == baseline,
              preferencesRevision == revision else { syncMessage = "Preferences changed or synchronization is busy. Your draft is kept."; return false }
        savingPreferences = true; defer { savingPreferences = false }
        guard let sync else {
            let previous = preferences, previousRevision = revisions[preferencesID]
            preferences = value; revisions[preferencesID] = revision + 1
            guard persist() else {
                preferences = previous; revisions[preferencesID] = previousRevision
                syncMessage = "Preferences could not be saved. Your draft is kept."
                return false
            }
            syncMessage = nil; return true
        }
        do {
            let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let saved = try await sync.save(.init(id: preferencesID, kind: "preferences", payload: payload, revision: revision), accountID: accountID)
            preferences = value; revisions[preferencesID] = saved.revision; preferencesDirty = false; syncMessage = nil; persist(); return true
        } catch { syncMessage = "Preferences could not be saved. Your draft is kept; refresh before resolving a concurrent edit."; return false }
    }
    /// Explicit local preference change only. The caller must send again; this never resumes a request.
    @discardableResult
    func disableAutomaticWebSearch() async -> Bool {
        guard canPersist || usesNativeUITestFixture, !savingPreferences, !syncing else { return false }
        let previous = preferences, wasDirty = preferencesDirty
        preferences.automaticWebSearch = false
        preferencesDirty = true
        guard persist() else {
            preferences = previous; preferencesDirty = wasDirty
            return false
        }
        if errorNoticeKind == .webSearchBudget { errorMessage = nil }
        Task { await synchronize() }
        return true
    }
    func preferencesChanged() { preferencesDirty = true; persist(); Task { await synchronize() } }
    func toggleMediaFavorite(_ id: String) {
        let key = "blackForestLabs:" + id
        if !favorites.insert(key).inserted { favorites.remove(key) }
        favoritesDirty = true; persist(); Task { await synchronize() }
    }
    func toggleMediaPinned(_ id: String) {
        let key = "blackForestLabs:" + id
        if !pinnedModels.insert(key).inserted { pinnedModels.remove(key) }
        pinsDirty = true; persist(); Task { await synchronize() }
    }
    func toggleFavorite(_ id: String) { toggleFavorite(modelID: id, provider: provider) }
    func toggleFavorite(modelID: String, provider: ChatProvider) {
        let identifier = provider.rawValue + ":" + modelID
        if !favorites.insert(identifier).inserted { favorites.remove(identifier) }
        favoritesDirty = true; persist(); Task { await synchronize() }
    }
    func togglePinned(modelID: String, provider: ChatProvider) {
        let identifier = provider.rawValue + ":" + modelID
        if !pinnedModels.insert(identifier).inserted { pinnedModels.remove(identifier) }
        pinsDirty = true; persist(); Task { await synchronize() }
    }
    /// Recalculated for every Chat/voice turn; a captured project never inherits another project's memory.
    func voiceContextInstructions(query: String, projectID: UUID?) -> String {
        let project = projects.first { $0.id == projectID }
        let includeGlobal = project?.memoryScope != .projectOnly
        return [includeGlobal ? preferences.instructions : "", includeGlobal ? profileInstructions : "",
                project?.instructions ?? "",
                AccountMemoryService.context(memory, query: query, projectID: projectID, includeGlobal: includeGlobal)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    func send(_ text: String, attachments: [NativeChatAttachment] = []) async -> Bool {
        let conversationID = selectedID ?? newDraftID, selection = selectedID, projectSelection = selectedProjectID
        let projectID = selected.map { $0.projectID.flatMap(UUID.init(uuidString:)) } ?? selectedProjectID
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else {
            errorMessage = "This project is no longer available. Review the conversation’s project before sending."; return false
        }
        let owner = accountID, generation = memoryCaptureGeneration, selectedProvider = provider, selectedModel = modelID
        let catalog = models, target = executionTarget, fingerprint = submissionFingerprint(projectID: projectID)
        guard fingerprint != "unreadable-project-sources" else { errorMessage = "Project sources could not be read safely. They have been preserved."; return false }
        let knownSourceIDs = Set(projectDocuments.documents.map(\.id))
        let inputs = attachments.filter { $0.projectSourceID == nil && !knownSourceIDs.contains($0.id) }
        let canUseTools = projectID != nil && NativeSkillToolRuntime.supports(selectedProvider)
            && catalog.first(where: { $0.id == selectedModel })?.capabilities.contains(.tools) == true
            && !UserDefaults.standard.bool(forKey: "aim.budget.enabled")
        var context: [NativeChatAttachment] = []
        if !canUseTools && projectID != nil && inputs.count < 4 {
            do {
                context = Array(try await projectDocuments.attachments(for: projectID, query: text).filter { document in !inputs.contains { $0.id == document.id } }.prefix(max(0, 4 - inputs.count)))
            } catch {
                if !Task.isCancelled { errorMessage = "Project sources could not be searched safely. Your message and sources have been preserved." }
                return false
            }
        }
        guard !Task.isCancelled, accountID == owner, memoryCaptureGeneration == generation,
              selectedID == selection, selectedProjectID == projectSelection,
              provider == selectedProvider, modelID == selectedModel, executionTarget == target,
              submissionFingerprint(projectID: projectID) == fingerprint else { return false }
        return await send(text, conversationID: conversationID, projectID: projectID,
                          provider: selectedProvider, modelID: selectedModel, catalog: catalog,
                          target: target, selectConversation: true, attachments: inputs + context, allowProjectSources: true)
    }
    /// Voice and other captured callers use this without changing the user's
    /// current selection while their asynchronous work is in progress.
    func send(_ text: String, conversationID id: UUID, projectID: UUID?, provider selectedProvider: ChatProvider,
              modelID selectedModel: String, catalog: [ChatModel], target selectedTarget: ChatExecutionTarget,
              selectConversation: Bool, attachments: [NativeChatAttachment] = [], visualReport: VisualAnalysisReport? = nil,
              allowProjectSources: Bool = false) async -> Bool {
        let visualReport = visualReport ?? visualDraftReports[id]
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else {
            errorMessage = "This project is no longer available. Review the conversation’s project before sending."
            return false
        }
        guard responseTasks[id] == nil, pendingSubmissions[id] == nil else { return false }
        guard canPersist, selectedTarget == .thisDevice,
              let model = catalog.first(where: { $0.id == selectedModel && $0.isChatModel }),
              (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) else {
            errorMessage = responseTasks[id] != nil ? "This conversation already has a response in progress." : "Choose a connected provider and a text model before sending."; return false
        }
        do { try NativeChatAttachment.validate(attachments) }
        catch { errorMessage = error.localizedDescription; return false }
        let priorMessages = conversations.first(where: { $0.id == id })?.messages ?? []
        let existingInputs = VisualAnalysisService.primaryHistory(priorMessages).flatMap { $0.attachments ?? [] }
        let hasImages = (existingInputs + attachments).contains { $0.containsVisualContent }
        let needsVideoBatches = (existingInputs + attachments).contains { ($0.video?.frames.count ?? 0) > 4 }
        if hasImages && (model.supportsImageInput != true || needsVideoBatches) && visualReport == nil {
            let pending = NativeVisualApproval(conversationID: id, projectID: projectID, text: text, primaryProvider: selectedProvider,
                primaryModel: selectedModel, catalog: catalog, target: selectedTarget, selectConversation: selectConversation,
                attachments: attachments, sources: existingInputs + attachments)
            if model.supportsImageInput == true { return await runVisualApproval(pending, choice: .init(provider: selectedProvider, modelID: selectedModel), remember: false) }
            let preferences = subagentPreferences()
            if let choice = preferences.visual, preferences.permanentVisualConsents.contains(choice) {
                return await runVisualApproval(pending, choice: choice, remember: false)
            }
            pendingVisualApproval = pending; return false
        }
        let apiKey: String
        do { guard let saved = try key(for: selectedProvider), !saved.isEmpty else { throw ChatServiceError.missingKey }; apiKey = saved }
        catch { errorMessage = error.localizedDescription; return false }
        guard reconcileLegacyBudgetEstimates() else { return false }
        // Keep the search preference. Budget coverage is explicit: estimated by default, verified-only if selected.
        let webSearch = preferences.usesAutomaticWebSearch
        let researchMode = webSearch ? preferences.resolvedResearchMode : .hosted
        let usesResearch = researchMode.isOrchestrated
        let budgetEnabled = UserDefaults.standard.bool(forKey: "aim.budget.enabled")
        let attachedSkillInstructions = AIMSkillsStore.shared.accountID == accountID ? AIMSkillsStore.shared.attachedInstructions : nil
        let enabledSkills = attachedSkillInstructions == nil && AIMSkillsStore.shared.accountID == accountID ? AIMSkillsStore.shared.installed.filter { $0.enabled && $0.modelInvocable } : []
        if !enabledSkills.isEmpty && (!NativeSkillToolRuntime.supports(selectedProvider) || !model.capabilities.contains(.tools)) {
            errorMessage = "Enabled skills need a model with tools. Choose a compatible model, or explicitly attach selected instructions from Personalization."; return false
        }
        if !enabledSkills.isEmpty && budgetEnabled { errorMessage = "Skill tool rounds have no verified upper cost within the strict device budget. Review the budget or disable skills explicitly."; return false }
        if usesResearch {
            guard NativeSkillToolRuntime.supports(selectedProvider), model.capabilities.contains(.tools) else {
                errorMessage = AIMResearchError.unsupportedModel.localizedDescription; return false
            }
            if budgetEnabled && requiresVerifiedWebSearchBudget { errorMessage = AIMResearchError.strictBudget.localizedDescription; return false }
            do { guard try researchKey(for: researchMode)?.isEmpty == false else { throw AIMResearchError.missingKey } }
            catch { errorMessage = AIMResearchError.missingKey.localizedDescription; return false }
        }
        if !usesResearch && webSearch && budgetEnabled && requiresVerifiedWebSearchBudget {
            errorMessage = String(localized: "chat.error.web_budget.message")
            errorNoticeKind = .webSearchBudget
            return false
        }
        do {
            if webSearch && !usesResearch && !NativeWebSearchRules.supports(provider: selectedProvider, modelID: selectedModel) {
                throw ChatServiceError.unsupportedWebSearch
            }
            try NativeWebSearchRules.requireBudgetCompatibility(enabled: webSearch && !usesResearch, budgetEnabled: budgetEnabled, allowEstimatedWebSearch: !requiresVerifiedWebSearchBudget)
        } catch { errorMessage = error.localizedDescription; return false }
        var conversation = conversations.first(where: { $0.id == id }) ?? .init(id: id, title: String((text.isEmpty ? attachments.first?.name ?? "Chat" : text).prefix(80)), provider: selectedProvider, modelID: selectedModel, projectID: projectID?.uuidString)
        let projectID = conversation.projectID.flatMap(UUID.init(uuidString:))
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else {
            errorMessage = "This project is no longer available. Review the conversation’s project before sending."
            return false
        }
        let user = NativeChatMessage(role: .user, text: text, attachments: attachments.isEmpty ? nil : attachments, visualReport: visualReport)
        let assistant = NativeChatMessage(role: .assistant, text: "", createdAt: user.createdAt.addingTimeInterval(0.001), webSearchUsage: webSearch ? .init() : nil)
        let executionModel = executionModel(model, provider: selectedProvider)
        let pricing = executionModel.pricing
        let instructionText = [voiceContextInstructions(query: text, projectID: projectID), attachedSkillInstructions ?? "", projectID == nil ? "" : ProjectSourceTools.citationInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
        // With no budget, automatic output remains provider-controlled. With a
        // budget, automatic output reserves only what is affordable and sends
        // that exact output cap; explicit user caps are never silently lowered.
        let catalogMaximum = executionModel.maxOutputTokens ?? executionModel.topProvider?.maxCompletionTokens
        let inputBytes = conversation.messages.reduce(256 + NativeAttachmentEncoding.text(user).utf8.count + instructionText.utf8.count) { $0 + NativeAttachmentEncoding.text($1).utf8.count + 64 }
        let remainingUSD = (UserDefaults.standard.object(forKey: "aim.budget.limit") as? Double ?? 2)
            - DeviceBudgetRules.committedUSD(records: activityRecords, accountID: accountID, deviceID: deviceID)
        let maximumOutput = budgetEnabled
            ? DeviceBudgetRules.affordableOutputTokens(inputBytes: inputBytes, catalogMaximum: catalogMaximum,
                userLimit: customOutputTokenLimit, remainingUSD: remainingUSD, pricing: pricing)
            : customOutputTokenLimit
        if let maximumOutput {
            do { _ = try ModelOutputPolicy.resolve(provider: selectedProvider, modelID: selectedModel, catalogMaximum: catalogMaximum, userLimit: maximumOutput) }
            catch { errorMessage = error.localizedDescription; return false }
        }
        // The estimate excludes provider-controlled search iterations; the UI states that coverage.
        let bound = hasImages ? nil : (maximumOutput ?? (budgetEnabled ? catalogMaximum : nil)).flatMap { maximum in
            maximum > 0 ? DeviceBudgetRules.upperBound(inputBytes: inputBytes, maxOutputTokens: maximum, pricing: pricing) : nil
        }
        if budgetEnabled {
            if let failure = budgetFailure(bound) { errorMessage = budgetFailureMessage(failure); return false }
        }
        let previousPending = pendingSubmissions
        let previousConversations = conversations, previousActivity = activityRecords, previousDrafts = drafts, previousInputs = inputDrafts, previousDirty = dirty
        conversation.provider = selectedProvider; conversation.modelID = selectedModel
        conversation.messages.append(user); let history = VisualAnalysisService.primaryHistory(conversation.messages); conversation.messages.append(assistant)
        conversation.turns.append(.init(id: assistant.id)); conversation.updatedAt = .now
        conversation.executionDeviceIDs = Array(Set((conversation.executionDeviceIDs ?? []) + [deviceID])).sorted()
        conversation.lastTurnStatus = "running"
        let startedAt = Date(), taskID = user.id, generation = UUID()
        let shouldCaptureMemory = memory.enabled
        responseGenerations[id] = generation; responseErrors.removeValue(forKey: id)
        if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index] = conversation } else { conversations.insert(conversation, at: 0) }
        dirty.insert(id); drafts.removeValue(forKey: id); inputDrafts.removeValue(forKey: id)
        activityRecords = AccountActivityRecord.merge(activityRecords + [.init(id: assistant.id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name, conversationID: id,
            parentTaskID: taskID, provider: selectedProvider.rawValue, modelID: selectedModel, mode: "chat", startedAt: startedAt, costUSD: bound, costState: bound == nil ? .unknown : .reserved)], accountID: accountID)
        let pending = PendingSubmission(conversationID: id, user: user, assistant: assistant, projectID: projectID,
            provider: selectedProvider, model: executionModel, history: history, instructions: instructionText,
            maxOutput: maximumOutput, catalogMaximum: catalogMaximum, webSearch: webSearch, skills: enabledSkills,
            bound: bound, startedAt: startedAt, permissionFingerprint: submissionFingerprint(projectID: projectID), captureMemory: shouldCaptureMemory,
            projectSourcesAllowed: allowProjectSources, researchMode: researchMode)
        pendingSubmissions[id] = pending
        // No suspension between checking, reserving and persisting: two MainActor
        // admissions cannot both spend the same remaining budget.
        guard persist() else {
            pendingSubmissions = previousPending
            conversations = previousConversations; activityRecords = previousActivity; drafts = previousDrafts; inputDrafts = previousInputs; dirty = previousDirty
            responseGenerations.removeValue(forKey: id); return false
        }
        visualDraftReports.removeValue(forKey: id); persist()
        if attachedSkillInstructions != nil { AIMSkillsStore.shared.attachedInstructions = nil }
        if selectConversation { selectedID = id; newDraftID = UUID(); if projectID == nil { generalDraftID = newDraftID }; errorMessage = nil }
        memoryCaptureMessage = nil
        beginSubmission(pending, apiKey: apiKey)
        return true
    }
    private func beginSubmission(_ pending: PendingSubmission, apiKey: String) {
        let id = pending.conversationID, user = pending.user, assistant = pending.assistant
        let projectID = pending.projectID, selectedProvider = pending.provider, selectedModel = pending.model.id
        let records = (try? projectDocuments.sourceStore?.records()) ?? []
        let enabledSources = records.filter { $0.projectID == projectID && $0.useInChat }
        let usesProjectTools = pending.projectSourcesAllowed == true && projectID != nil && !enabledSources.isEmpty
            && NativeSkillToolRuntime.supports(selectedProvider) && pending.model.capabilities.contains(.tools)
            && !UserDefaults.standard.bool(forKey: "aim.budget.enabled")
        let sourceRuntime: LocalProjectSourceToolRuntime? = {
            guard usesProjectTools, let projectID, let store = projectDocuments.sourceStore else { return nil }
            return LocalProjectSourceToolRuntime(store: store, projectID: projectID)
        }()
        let history = ProjectSourceRequestHistory.filtered(pending.history, knownSourceIDs: Set(records.map(\.id)),
            currentMessageID: usesProjectTools ? nil : user.id,
            allowedCurrentSourceIDs: usesProjectTools || pending.projectSourcesAllowed != true ? [] : Set(enabledSources.map(\.id)))
        let instructionText = pending.instructions, maximumOutput = pending.maxOutput
        let usesResearch = pending.webSearch && pending.researchMode?.isOrchestrated == true
        let catalogMaximum = pending.catalogMaximum, webSearch = pending.webSearch && !usesResearch, enabledSkills = pending.skills
        let startedAt = pending.startedAt, taskID = user.id, text = user.text
        let attachments = user.attachments ?? [], pricing = pending.model.pricing
        let generation = UUID(), captureGeneration = memoryCaptureGeneration, shouldCaptureMemory = pending.captureMemory
        responseGenerations[id] = generation; responseErrors.removeValue(forKey: id)
        let admit: @Sendable () async throws -> Void = { [weak self] in
            try await MainActor.run {
                guard let self, self.responseGenerations[id] == generation else { throw CancellationError() }
                // Revalidate the current authorization at every skill round as well.
                guard (projectID == nil || self.projects.contains(where: { $0.id == projectID })),
                      pending.permissionFingerprint != "unreadable-project-sources",
                      self.submissionFingerprint(projectID: projectID) == pending.permissionFingerprint else { throw NativeDocumentError.limit }
                if let queued = self.pendingSubmissions.removeValue(forKey: id) {
                    // Persist BEFORE sending. A crash after this boundary is uncertain and never replayed.
                    guard self.persist() else { self.pendingSubmissions[id] = queued; throw NativeDocumentError.limit }
                }
            }
        }
        let researchRuntime: AIMResearchSession? = {
            guard usesResearch, let mode = pending.researchMode, let key = try? researchKey(for: mode), !key.isEmpty else { return nil }
            return AIMResearchSession(mode: mode, credential: {
                try await admit()
                try Task.checkCancellation()
                return key
            }, perform: { [weak self] operation in
                guard let self else { throw CancellationError() }
                return try await self.performResearchHTTP(operation, conversationID: id, parentID: assistant.id,
                    generation: generation, fingerprint: pending.permissionFingerprint)
            })
        }()
        responseTasks[id] = Task { [weak self] in
            guard let self else { return }
            var usage = TokenUsage(); var webUsage: NativeWebSearchUsage? = (webSearch || usesResearch) ? .init() : nil
            // Where reasoning, text and actions happen in this answer, for the timeline view.
            var timeline = TurnTimelineBuilder(startedAt: startedAt)
            var succeeded = false, cancelled = false, lastSave = Date.distantPast
            var usedProvider = selectedProvider, usedModel = pending.model
            do {
                guard !usesResearch || researchRuntime != nil else { throw AIMResearchError.missingKey }
                var routes = [NativeChatRoute(provider: selectedProvider, model: pending.model, key: apiKey)]
                let canonical = CanonicalModelRouting.identity(selectedModel, provider: selectedProvider.rawValue)
                for provider in catalogModels.keys.sorted(by: { CanonicalModelRouting.rank($0.rawValue) < CanonicalModelRouting.rank($1.rawValue) }) where !usesResearch && provider != selectedProvider && provider != .local && provider != .chatgpt {
                    guard let model = catalogModels[provider]?.first(where: { CanonicalModelRouting.identity($0.id, provider: provider.rawValue) == canonical }),
                          model.isChatModel, !history.contains(where: { ($0.attachments ?? []).contains(where: \.containsVisualContent) }) || model.supportsImageInput == true,
                          !webSearch || NativeWebSearchRules.supports(provider: provider, modelID: model.id),
                          (enabledSkills.isEmpty && !usesProjectTools && !usesResearch) || (NativeSkillToolRuntime.supports(provider) && model.capabilities.contains(.tools)),
                          let key = try? self.key(for: provider), !key.isEmpty else { continue }
                    routes.append(.init(provider: provider, model: executionModel(model, provider: provider), key: key))
                }
                let transport = self.transport, skillTransport = self.skillTransport
                let stream = RoutedChatTransport.stream(routes: routes) { [weak self] route in
                    let routeAdmission: @Sendable () async throws -> Void = {
                        try await MainActor.run {
                            guard let self, self.responseGenerations[id] == generation,
                                  (projectID == nil || self.projects.contains(where: { $0.id == projectID })),
                                  pending.permissionFingerprint != "unreadable-project-sources",
                                  self.submissionFingerprint(projectID: projectID) == pending.permissionFingerprint else { throw CancellationError() }
                            let maximum = maximumOutput ?? route.model.maxOutputTokens ?? route.model.topProvider?.maxCompletionTokens
                            let estimate = !history.contains(where: { ($0.attachments ?? []).contains(where: \.containsVisualContent) }) ? maximum.flatMap { DeviceBudgetRules.upperBound(inputBytes: history.dropLast().reduce(256 + instructionText.utf8.count + (history.last.map { NativeAttachmentEncoding.text($0).utf8.count } ?? 0)) { $0 + NativeAttachmentEncoding.text($1).utf8.count + 64 }, maxOutputTokens: $0, pricing: route.model.pricing) } : nil
                            if UserDefaults.standard.bool(forKey: "aim.budget.enabled") {
                                if let failure = self.budgetFailure(estimate, excluding: assistant.id) {
                                    throw NativeChatBudgetRefusal(message: self.budgetFailureMessage(failure))
                                }
                            }
                            if let row = self.activityRecords.firstIndex(where: { $0.id == assistant.id }) {
                                self.activityRecords[row].provider = route.provider.rawValue; self.activityRecords[row].modelID = route.model.id
                                self.activityRecords[row].costUSD = estimate; self.activityRecords[row].costState = estimate == nil ? .unknown : .reserved
                                guard self.persist() else { throw NativeDocumentError.limit }
                            }
                        }
                        try await admit()
                    }
                    let researchAdmission: @Sendable (Int, TokenUsage, NativeWebSearchUsage) async throws -> Int? = { requestBytes, used, metadata in
                        try await MainActor.run {
                            guard let self, self.responseGenerations[id] == generation,
                                  self.submissionFingerprint(projectID: projectID) == pending.permissionFingerprint else { throw CancellationError() }
                            guard UserDefaults.standard.bool(forKey: "aim.budget.enabled") else { return nil }
                            guard !self.requiresVerifiedWebSearchBudget else { throw AIMResearchError.strictBudget }
                            let modelSpent = ChatCostRules.estimateUSD(usage: used, pricing: route.model.pricing,
                                webSearch: metadata, allowPartialWebSearchCost: true) ?? 0
                            let others = self.activityRecords.filter { $0.id != assistant.id }
                            let available = (UserDefaults.standard.object(forKey: "aim.budget.limit") as? Double ?? 2)
                                - DeviceBudgetRules.committedUSD(records: others, accountID: self.accountID, deviceID: self.deviceID) - modelSpent
                            let maximum = DeviceBudgetRules.affordableOutputTokens(inputBytes: requestBytes + 256,
                                catalogMaximum: route.model.maxOutputTokens ?? route.model.topProvider?.maxCompletionTokens,
                                userLimit: self.customOutputTokenLimit, remainingUSD: available, pricing: route.model.pricing)
                            guard let maximum, let nextBound = DeviceBudgetRules.upperBound(inputBytes: requestBytes + 256,
                                maxOutputTokens: maximum, pricing: route.model.pricing) else { throw NativeDocumentError.limit }
                            if let failure = self.budgetFailure(modelSpent + nextBound, excluding: assistant.id) {
                                throw ResearchAdmissionFailure(message: self.budgetFailureMessage(failure))
                            }
                            guard let row = self.activityRecords.firstIndex(where: { $0.id == assistant.id }) else { throw CancellationError() }
                            self.activityRecords[row].costUSD = modelSpent + nextBound
                            self.activityRecords[row].costState = .reserved
                            guard self.persist() else { throw NativeDocumentError.limit }
                            return maximum
                        }
                    }
                    let researchWillExecute: @Sendable (TokenUsage, NativeWebSearchUsage) async throws -> Void = { used, metadata in
                        try await MainActor.run {
                            guard let self, self.responseGenerations[id] == generation,
                                  self.submissionFingerprint(projectID: projectID) == pending.permissionFingerprint,
                                  let row = self.activityRecords.firstIndex(where: { $0.id == assistant.id }) else { throw CancellationError() }
                            let amount = ChatCostRules.estimateUSD(usage: used, pricing: route.model.pricing,
                                webSearch: metadata, allowPartialWebSearchCost: true)
                            self.activityRecords[row].costUSD = amount
                            self.activityRecords[row].costState = amount == nil ? .unknown : metadata.providerTotalCostUSD == nil ? .estimated : .confirmed
                            guard self.persist() else { throw NativeDocumentError.limit }
                        }
                    }
                    return enabledSkills.isEmpty && !usesProjectTools && !usesResearch
                        ? transport.stream(provider: route.provider, modelID: route.model.id, messages: history, key: route.key, instructions: instructionText, maxOutputTokens: maximumOutput, webSearch: webSearch, catalogMaximum: route.model.maxOutputTokens ?? route.model.topProvider?.maxCompletionTokens, reasoningSummary: route.model.capabilities.contains(.reasoning), admission: routeAdmission)
                        : skillTransport.stream(provider: route.provider, modelID: route.model.id, messages: history, key: route.key, instructions: instructionText, maxOutputTokens: maximumOutput, webSearch: webSearch, catalogMaximum: route.model.maxOutputTokens ?? route.model.topProvider?.maxCompletionTokens, skills: enabledSkills, projectSources: sourceRuntime, research: researchRuntime, researchAdmission: usesResearch ? researchAdmission : nil, researchWillExecute: usesResearch ? researchWillExecute : nil, admission: routeAdmission)
                }
                for try await event in stream {
                    try Task.checkCancellation()
                    guard responseGenerations[id] == generation, let index = conversations.firstIndex(where: { $0.id == id }),
                          let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == assistant.id }),
                          let turnIndex = conversations[index].turns.firstIndex(where: { $0.id == assistant.id }) else { throw CancellationError() }
                    if let attempt = event.routeAttempt {
                        var attempts = conversations[index].messages[messageIndex].routeAttempts ?? []
                        if let prior = attempts.firstIndex(where: { $0.ordinal == attempt.ordinal }) { attempts[prior] = attempt } else { attempts.append(attempt) }
                        conversations[index].messages[messageIndex].routeAttempts = attempts
                        if attempt.state == .accepted, let route = routes.first(where: { $0.provider == attempt.provider && $0.model.id == attempt.modelID }) {
                            usedProvider = route.provider; usedModel = route.model
                        }
                        if attempt.ordinal > 0 {
                            let actionID = assistant.id.uuidString + ":route:" + String(attempt.ordinal)
                            let prior = conversations[index].messages[messageIndex].actions?.first { $0.id == actionID }
                            let action = ConversationAction(id: actionID, conversationID: id, turnID: assistant.id, ordinal: -2,
                                name: "Provider · " + attempt.provider.name, state: attempt.state == .trying ? .running : attempt.state == .accepted ? .completed : attempt.state == .rejected ? .failed : .needsReview,
                                startedAt: prior?.startedAt ?? .now, finishedAt: attempt.state == .trying ? nil : prior?.finishedAt ?? .now,
                                input: selectedProvider.name + " → " + attempt.provider.name,
                                output: attempt.state.rawValue + " · " + attempt.modelID)
                            conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, [action])
                            if attempt.state == .trying { timeline.action(actionID) }
                        }
                    }
                    if let waiting = event.connectionWaiting {
                        let actionID = assistant.id.uuidString + ":network"
                        if waiting || conversations[index].messages[messageIndex].actions?.contains(where: { $0.id == actionID }) == true {
                            let action = ConversationAction(id: actionID, conversationID: id, turnID: assistant.id, ordinal: -1,
                                name: waiting ? "Waiting for network · cancel with Stop" : "Network restored",
                                state: waiting ? .waiting : .completed, startedAt: startedAt, finishedAt: waiting ? nil : .now,
                                detail: "Submission waits for a connection. An interrupted provider request is never repeated automatically.")
                            conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, [action])
                            if waiting { timeline.action(actionID) }
                        }
                    }
                    if let reasoning = event.reasoning { timeline.reasoning(reasoning) }
                    if let sources = event.sources { conversations[index].messages[messageIndex].sources = ConversationSource.merge(conversations[index].messages[messageIndex].sources, sources) }
                    if !event.text.isEmpty { timeline.text(event.text); conversations[index].messages[messageIndex].text += event.text }
                    if let activities = event.skillActivities {
                        conversations[index].messages[messageIndex].skillActivities = activities
                        for value in activities { timeline.action(value.id) }
                        let actions = activities.enumerated().map { ordinal, value in ConversationAction(id: value.id, conversationID: id,
                            turnID: assistant.id, ordinal: ordinal, name: value.name, state: value.running == true ? .running : value.isError ? .failed : .completed,
                            startedAt: value.startedAt ?? startedAt, finishedAt: value.running == true ? nil : value.finishedAt ?? .now, detail: value.skill + (value.path.map { " · " + $0 } ?? "") + (value.detail.map { "\n\n" + $0 } ?? "")) }
                        conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, actions)
                    }
                    if let reported = event.usage { usage.merge(reported) }
                    if let reported = event.webSearchUsage { webUsage?.merge(reported); conversations[index].messages[messageIndex].webSearchUsage = webUsage }
                    if let activities = event.webSearchActivities {
                        for value in activities { timeline.action("web:" + value.id) }
                        let actions = activities.map { value in
                            let prior = conversations[index].messages[messageIndex].actions?.first { $0.id == "web:" + value.id }
                            return ConversationAction(id: "web:" + value.id, conversationID: id, turnID: assistant.id,
                                ordinal: prior?.ordinal ?? (conversations[index].messages[messageIndex].actions?.count ?? 0),
                                name: "web_search", state: value.status == .running ? .running : value.status == .failed ? .failed : .completed,
                                startedAt: prior?.startedAt ?? .now, finishedAt: value.status == .running ? nil : prior?.finishedAt ?? .now,
                                input: value.input ?? prior?.input, output: value.output ?? prior?.output)
                        }
                        conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, actions)
                        conversations[index].messages[messageIndex].webSearchActivities = Self.mergingWebSearchActivities(conversations[index].messages[messageIndex].webSearchActivities ?? [], with: activities)
                    }
                    if event.isComplete {
                        var viewed: [ConversationAction] = []
                        for input in attachments where input.containsVisualContent {
                            if let video = input.video {
                                viewed += video.frames.map { frame in .init(id: assistant.id.uuidString + ":" + frame.id.uuidString,
                                    conversationID: id, turnID: assistant.id, ordinal: viewed.count, name: "view_image",
                                    state: .completed, startedAt: startedAt, finishedAt: .now, detail: input.name,
                                    mediaID: frame.id, timestamp: frame.seconds) }
                            } else { viewed.append(.init(id: assistant.id.uuidString + ":" + input.id.uuidString, conversationID: id,
                                turnID: assistant.id, ordinal: viewed.count, name: "view_image", state: .completed,
                                startedAt: startedAt, finishedAt: .now, detail: input.name, mediaID: input.id)) }
                        }
                        if let report = history.last(where: { $0.role == .user })?.visualReport {
                            viewed.append(.init(id: report.id.uuidString, conversationID: id, turnID: assistant.id, ordinal: viewed.count,
                                name: "visual_analysis", state: .completed, startedAt: min(startedAt, report.createdAt), finishedAt: report.createdAt,
                                detail: report.choice.provider.rawValue + " · " + report.choice.modelID + "\n\n" + report.text))
                        }
                        conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, viewed.isEmpty ? nil : viewed)
                        let completedAt = Date()
                        conversations[index].turns[turnIndex] = .init(id: assistant.id, usage: usage, estimatedUSD: ChatCostRules.estimateUSD(usage: usage, pricing: usedModel.pricing, webSearch: webUsage, allowPartialWebSearchCost: true), completedAt: completedAt)
                        conversations[index].latestResponseVersion = .init(id: assistant.id.uuidString, completedAt: completedAt)
                        conversations[index].lastTurnStatus = "idle"
                        timeline.finish()
                    }
                    conversations[index].messages[messageIndex].timeline = timeline.timeline
                    conversations[index].updatedAt = .now; dirty.insert(id)
                    if event.isComplete || Date().timeIntervalSince(lastSave) >= 0.5 { persist(); lastSave = .now }
                }
                try Task.checkCancellation(); succeeded = responseGenerations[id] == generation
            } catch is CancellationError { cancelled = true; setResponseError("Response stopped. The partial answer has been kept.", conversationID: id) }
            catch { setResponseError(error.localizedDescription, conversationID: id) }
            if pendingSubmissions[id] != nil {
                responseTasks.removeValue(forKey: id); responseGenerations.removeValue(forKey: id)
                persist(); return
            }
            if !succeeded, let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].lastTurnStatus = cancelled ? "cancelled" : "failed"; dirty.insert(id) }
            if !succeeded, let index = conversations.firstIndex(where: { $0.id == id }),
               let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == assistant.id }),
               conversations[index].messages[messageIndex].timeline != nil {
                timeline.finish(); conversations[index].messages[messageIndex].timeline = timeline.timeline
            }
            if !succeeded, let conversationIndex = conversations.firstIndex(where: { $0.id == id }),
               let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == assistant.id }),
               let activities = conversations[conversationIndex].messages[messageIndex].webSearchActivities {
                conversations[conversationIndex].messages[messageIndex].webSearchActivities = Self.interruptedWebSearchActivities(activities)
                dirty.insert(id)
            }
            let responseFinishedAt = Date()
            let modelReceipt = usesResearch ? webUsage?.providerTotalCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            let cost = succeeded ? ChatCostRules.estimateUSD(usage: usage, pricing: usedModel.pricing, webSearch: webUsage, allowPartialWebSearchCost: true) : modelReceipt
            // Research API attempts have their own settled records. An uncertain model attempt is
            // completed/unknown, never a permanent reservation or an invoice from another provider.
            let reserved = usesResearch ? nil : activityRecords.first(where: { $0.id == assistant.id })?.costUSD
            activityRecords = AccountActivityRecord.merge(activityRecords + [
                .init(id: assistant.id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name, conversationID: id,
                      parentTaskID: taskID, provider: usedProvider.rawValue, modelID: usedModel.id, mode: "chat", startedAt: startedAt,
                      completedAt: responseFinishedAt, totalTokens: usage.inputTokens.flatMap { input in usage.outputTokens.map { input + $0 } }, costUSD: cost ?? reserved, costState: cost != nil ? (webUsage?.providerTotalCostUSD.map { $0.isFinite && $0 >= 0 } == true ? .confirmed : .estimated) : (reserved == nil ? .unknown : .reserved))
            ], accountID: accountID); persist()
            if succeeded && shouldCaptureMemory && !Task.isCancelled && responseGenerations[id] == generation {
                await captureMemory(userText: text, sourceMessageID: user.id, conversationID: id, projectID: projectID,
                                    parentTaskID: taskID, provider: selectedProvider, modelID: selectedModel,
                                    pricing: pricing, key: apiKey, responseGeneration: generation, captureGeneration: captureGeneration)
            }
            activityRecords = AccountActivityRecord.merge(activityRecords + [
                .init(id: taskID, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name, conversationID: id,
                      kind: .task, provider: selectedProvider.rawValue, modelID: selectedModel, mode: "chat", startedAt: startedAt, completedAt: .now)
            ], accountID: accountID)
            responseTasks.removeValue(forKey: id); responseGenerations.removeValue(forKey: id); persist()
            await synchronize(); await syncAccountData()
            if succeeded { await notifyCompletion(accountID, assistant.id, user.id, id, .response) }
        }
    }
    static func mergingWebSearchActivities(_ existing: [NativeWebSearchActivity], with incoming: [NativeWebSearchActivity]) -> [NativeWebSearchActivity] {
        var result = existing
        for activity in incoming {
            if let index = result.firstIndex(where: { $0.id == activity.id }) {
                if result[index].status != .running && activity.status == .running { continue }
                var merged = activity; merged.input = merged.input ?? result[index].input; merged.output = merged.output ?? result[index].output
                result[index] = merged
            } else { result.append(activity) }
        }
        return result
    }
    static func interruptedWebSearchActivities(_ activities: [NativeWebSearchActivity]) -> [NativeWebSearchActivity] {
        activities.map { .init(id: $0.id, status: $0.status == .running ? .failed : $0.status, input: $0.input, output: $0.output) }
    }
    func responseError(conversationID: UUID) -> String? { responseErrors[conversationID] }
    private func setResponseError(_ text: String, conversationID: UUID) {
        responseErrors[conversationID] = text
        if selectedID == conversationID { errorMessage = text }
    }
    @discardableResult func reconcileLegacyBudgetEstimates() -> Bool {
        guard canPersist else { return false }
        // Only direct catalogs qualify; never use reference enrichment from another provider.
        var exact = nativeCatalogModels
        if provider == .openRouter, exact[provider] == nil { exact[provider] = models }
        let recovered = DeviceBudgetRules.recoveringLegacyEstimates(records: activityRecords, conversations: conversations,
            accountID: accountID, deviceID: deviceID, models: exact)
        guard recovered != activityRecords else { return true }
        let previousActivity = activityRecords, previousConversations = conversations
        activityRecords = recovered
        for record in recovered where record.costEstimateBasis == "legacy-saved-usage-current-native-catalog-v1" {
            guard let conversationIndex = conversations.firstIndex(where: { $0.id == record.conversationID }),
                  let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == record.id }),
                  conversations[conversationIndex].turns[turnIndex].estimatedUSD == nil else { continue }
            conversations[conversationIndex].turns[turnIndex].estimatedUSD = record.costUSD
        }
        guard persist() else { activityRecords = previousActivity; conversations = previousConversations; return false }
        return true
    }
    private func budgetFailure(_ bound: Double?, excluding requestID: UUID? = nil) -> DeviceBudgetRules.AdmissionFailure? {
        DeviceBudgetRules.admissionFailure(bound: bound,
            limit: UserDefaults.standard.object(forKey: "aim.budget.limit") as? Double ?? 2,
            records: activityRecords.filter { $0.id != requestID }, accountID: accountID, deviceID: deviceID,
            historyPolicy: requiresVerifiedWebSearchBudget ? .requireComplete : .estimatedKnownCharges)
    }
    private func budgetFailureMessage(_ failure: DeviceBudgetRules.AdmissionFailure) -> String {
        switch failure {
        case .invalidLimit: "This device’s budget amount is invalid. Review Usage & costs."
        case .unknownHistory: requiresVerifiedWebSearchBudget
            ? "Strict budget protection requires a complete charge history. Review unknown charges in Usage & costs, or choose estimated protection."
            : "A request still has an unresolved charge. Review pending activity in Usage & costs before sending again."
        case .exhausted: "This iPhone’s monthly budget has been reached. Review Usage & costs."
        case .reserved: "Other requests still reserve this iPhone’s remaining budget. Wait for them to finish, then send again."
        case .requestTooLarge: "The selected output limit would exceed this iPhone’s remaining budget. Choose Automatic output or a smaller limit in Configuration."
        case .unknownPrice: "This model has no verified price or affordable output capacity. Refresh its catalog, choose an explicit output limit, or review Usage & costs."
        }
    }
    private func budgetAdmits(_ bound: Double) -> Bool { budgetFailure(bound) == nil }
    private func captureMemory(userText: String, sourceMessageID: UUID, conversationID: UUID, projectID: UUID?,
                               parentTaskID: UUID, provider: ChatProvider, modelID: String, pricing: ChatModel.Pricing?,
                               key: String, responseGeneration generation: UUID, captureGeneration: UUID) async {
        guard memory.enabled, memoryCaptureGeneration == captureGeneration, responseGenerations[conversationID] == generation,
              !Task.isCancelled, let messages = AccountMemoryCapture.messages(userText: userText) else { return }
        let base: AccountMemorySnapshot
        do { base = try await loadStoredMemory(); try Task.checkCancellation() }
        catch { if !Task.isCancelled { memoryCaptureMessage = "Memory was not saved. Refresh Memory before trying again." }; return }
        guard base.enabled, memory.enabled, memoryCaptureGeneration == captureGeneration, responseGenerations[conversationID] == generation else { return }
        if (base.revision ?? 0) >= (memory.revision ?? 0) { memory = base }
        let bound = DeviceBudgetRules.upperBound(inputBytes: messages.reduce(256) { $0 + $1.text.utf8.count + 64 }, maxOutputTokens: AccountMemoryCapture.maxOutputTokens, pricing: pricing)
        if UserDefaults.standard.bool(forKey: "aim.budget.enabled") {
            guard let bound, budgetAdmits(bound) else {
                memoryCaptureMessage = "Memory was not captured because its additional request has no verified maximum within this iPhone’s budget."; return
            }
        }
        let requestID = UUID(), startedAt = Date()
        activityRecords.append(.init(id: requestID, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
            conversationID: conversationID, parentTaskID: parentTaskID, provider: provider.rawValue, modelID: modelID, mode: "memory",
            startedAt: startedAt, costUSD: bound, costState: bound == nil ? .unknown : .reserved, toolName: "Memory capture"))
        guard persist() else { return }
        memoryCaptureIDs.insert(requestID)
        defer { memoryCaptureIDs.remove(requestID) }
        var output = "", usage = TokenUsage(), completed = false
        do {
            for try await event in transport.stream(provider: provider, modelID: modelID, messages: messages, key: key,
                                                    maxOutputTokens: AccountMemoryCapture.maxOutputTokens, webSearch: false) {
                try Task.checkCancellation()
                guard memory.enabled, memoryCaptureGeneration == captureGeneration, responseGenerations[conversationID] == generation else { throw CancellationError() }
                output += event.text
                guard output.utf8.count <= AccountMemoryCapture.maxResponseBytes else { throw ChatServiceError.invalidResponse }
                if let reported = event.usage { usage.merge(reported) }
                completed = completed || event.isComplete
            }
            try Task.checkCancellation()
            guard completed, memory.enabled, memoryCaptureGeneration == captureGeneration, responseGenerations[conversationID] == generation else { throw CancellationError() }
            let proposals = AccountMemoryCapture.parse(output, source: userText, projectID: projectID, sourceMessageID: sourceMessageID)
            let proposed = AccountMemoryCapture.adding(proposals, to: base)
            if proposed != base {
                // CAS preserves a concurrent correction, archive, deletion or disable, without retrying stale proposals.
                guard (memory.revision ?? 0) == (base.revision ?? 0) else { throw AccountServiceError.conflict }
                let saved = try await storeMemory(proposed)
                try Task.checkCancellation()
                guard memory.enabled, memoryCaptureGeneration == captureGeneration, responseGenerations[conversationID] == generation else { throw CancellationError() }
                if (saved.revision ?? 0) >= (memory.revision ?? 0) { memory = saved }
                memoryCaptureMessage = "New memories are ready to review in Memory summary."
            } else if AccountMemoryCapture.requestsRemembering(userText) {
                memoryCaptureMessage = "No new supported, non-sensitive memory was saved. Review Memory summary to add or edit it."
            }
        } catch is CancellationError {
            memoryCaptureMessage = "Memory capture stopped. Your saved memories are preserved."
        } catch AccountServiceError.conflict {
            memoryCaptureMessage = "Memory changed during capture. Your newer edits were preserved; review Memory summary."
        } catch {
            memoryCaptureMessage = "Memory capture did not finish. Your saved memories are preserved."
        }
        let cost = completed ? ChatCostRules.estimateUSD(usage: usage, pricing: pricing) : nil
        activityRecords = AccountActivityRecord.merge(activityRecords + [
            .init(id: requestID, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
                  conversationID: conversationID, parentTaskID: parentTaskID, provider: provider.rawValue, modelID: modelID, mode: "memory", startedAt: startedAt,
                  completedAt: .now, totalTokens: usage.inputTokens.flatMap { input in usage.outputTokens.map { input + $0 } },
                  costUSD: cost ?? bound, costState: cost != nil ? .estimated : (bound == nil ? .unknown : .reserved), toolName: "Memory capture")
        ], accountID: accountID)
        persist()
    }
    func cancel(conversationID: UUID) {
        let unsent = pendingSubmissions.removeValue(forKey: conversationID)
        if let unsent { UserDefaults.standard.set(Array(cancelledSubmissionIDs.union([unsent.assistant.id.uuidString])), forKey: cancelledSubmissionKey) }
        if unsent != nil, responseTasks[conversationID] == nil, let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].lastTurnStatus = "cancelled"
            if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == unsent?.assistant.id }) {
                var action = conversations[index].messages[messageIndex].actions?.first(where: { $0.id.hasSuffix(":network") })
                action?.state = .cancelled; action?.finishedAt = .now
                if let action { conversations[index].messages[messageIndex].actions = ConversationAction.merge(conversations[index].messages[messageIndex].actions, [action]) }
            }
            dirty.insert(conversationID)
        }
        _ = persist()
        responseGenerations.removeValue(forKey: conversationID); responseTasks[conversationID]?.cancel()
    }
    func stop(conversationID: UUID) { cancel(conversationID: conversationID) }
    func stop() { stopAll() }
    func stopAll() { memoryCaptureGeneration = UUID(); for id in Set(responseTasks.keys).union(pendingSubmissions.keys) { cancel(conversationID: id) } }
    func stopAndWait() async {
        let pending = Array(responseTasks.values), speaking = speechTask
        suspendForProtection(); stopSpeaking(); await voiceInstance?.stopAndWait()
        for task in pending { await task.value }; await speaking?.value
    }
    func waitForResponse(conversationID: UUID? = nil) async {
        if let id = conversationID ?? selectedID { await responseTasks[id]?.value }
    }
    func voiceKey(_ provider: AIMVoiceConfiguration.SpeechProvider) throws -> String? {
        if provider == .openAI { return try key(for: .openAI) }; if provider == .openRouter { return try key(for: .openRouter) }
        return try credentials.readData(forKey: accountID.uuidString + ".voice.elevenlabs").flatMap { String(data: $0, encoding: .utf8) }
    }
    func saveElevenLabsKey(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        try credentials.store(Data(value.utf8), forKey: accountID.uuidString + ".voice.elevenlabs")
    }
    func admitRealtimeVoice(id: UUID, context: RealtimeVoiceContext? = nil) -> Bool {
        if UserDefaults.standard.bool(forKey: "aim.budget.enabled") {
            errorMessage = "Realtime cannot yet enforce this iPhone’s spending limit. Choose dictation with Chat to use the limit."
            return false
        }
        if activityRecords.contains(where: { $0.id == id }) { return true }
        let conversationID = context == nil ? selectedID : context?.conversationID
        activityRecords = AccountActivityRecord.merge(activityRecords + [.init(id: id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name, conversationID: conversationID, kind: .voice, provider: "openai", modelID: RealtimeVoiceProtocol.defaultModel, mode: "voice", startedAt: .now, costState: .unknown)], accountID: accountID)
        persist(); return true
    }
    @discardableResult func recordVoiceTurn(id: UUID, userText: String, assistantText: String, start: Date, tokens: Int?, cost: Double?, context: RealtimeVoiceContext? = nil) -> UUID? {
        let source: RealtimeVoiceContext
        if let context { source = context }
        else if let selected { source = .init(conversationID: selected.id, projectID: selected.projectID.flatMap(UUID.init(uuidString:))) }
        else { source = .init(projectID: selectedProjectID) }
        var row = activityRecords.first { $0.id == id } ?? .init(id: id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name, kind: .voice, provider: "openai", modelID: RealtimeVoiceProtocol.defaultModel, mode: "voice", startedAt: start)
        if !userText.isEmpty || !assistantText.isEmpty {
            let priorID = row.completedAt == nil ? source.conversationID : row.conversationID
            var conversation = conversations.first {
                $0.id == priorID && $0.provider == .openAI && $0.modelID == RealtimeVoiceProtocol.defaultModel && $0.projectID == source.projectID?.uuidString
            } ?? .init(title: userText.isEmpty ? "Voice conversation" : String(userText.prefix(80)), provider: .openAI, modelID: RealtimeVoiceProtocol.defaultModel, projectID: source.projectID?.uuidString)
            // Stable IDs make an interrupted turn and any repeated receipt one
            // conversation turn after persistence or account synchronization.
            var userUUID = id.uuid; userUUID.15 ^= 0x80
            for message in [NativeChatMessage(id: UUID(uuid: userUUID), role: .user, text: userText, createdAt: start),
                            NativeChatMessage(id: id, role: .assistant, text: assistantText, createdAt: start.addingTimeInterval(0.000001))] where !message.text.isEmpty {
                if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
                    if message.text.count > conversation.messages[index].text.count { conversation.messages[index].text = message.text }
                } else { conversation.messages.append(message) }
            }
            conversation.updatedAt = .now
            if context == nil || selectedID == source.conversationID { selectedID = conversation.id }
            update(conversation); row.conversationID = conversation.id
        }
        row.completedAt = row.completedAt ?? .now; row.totalTokens = tokens.flatMap { $0 >= 0 ? $0 : nil } ?? row.totalTokens; row.updatedAt = .now
        if let cost, cost.isFinite, cost >= 0 { row.costUSD = cost; row.costState = .estimated }
        activityRecords = AccountActivityRecord.merge(activityRecords + [row], accountID: accountID); persist(); Task { await synchronize(); await syncAccountData() }
        return row.conversationID
    }
    func recordRealtimeVoicePreview(id: UUID, startedAt: Date, totalTokens: Int?, costUSD: Double?) {
        var row = activityRecords.first { $0.id == id } ?? .init(id: id, accountID: accountID, deviceID: deviceID,
            deviceName: UIDevice.current.name, kind: .voice, provider: "openai", modelID: RealtimeVoiceProtocol.defaultModel,
            mode: "voice", startedAt: startedAt)
        row.conversationID = nil; row.completedAt = .now; row.updatedAt = .now
        row.totalTokens = totalTokens.flatMap { $0 >= 0 ? $0 : nil }; row.toolName = "Voice preview"
        if let costUSD, costUSD.isFinite, costUSD >= 0 { row.costUSD = costUSD; row.costState = .estimated }
        activityRecords = AccountActivityRecord.merge(activityRecords + [row], accountID: accountID)
        persist(); Task { await syncAccountData() }
    }
    /// Lossless provider-sized segments; this bounds each HTTP request, never the
    /// answer or accumulated playback. Splitting preserves every Character exactly.
    static func speechSegments(_ text: String, maximumCharacters: Int = 2000, maximumUTF8Bytes: Int = 8000) -> [String] {
        guard maximumCharacters > 0, maximumUTF8Bytes > 0 else { return [] }
        var result: [String] = [], current = "", bytes = 0, count = 0
        for character in text {
            let value = String(character), size = value.utf8.count
            if !current.isEmpty && (count >= maximumCharacters || bytes + size > maximumUTF8Bytes) {
                result.append(current); current = ""; bytes = 0; count = 0
            }
            current += value; bytes += size; count += 1
        }
        if !current.isEmpty { result.append(current) }; return result
    }
    func speak(_ text: String, conversationID: UUID? = nil) {
        stopSpeaking()
        let configuration = voiceController.configuration
        let capturedConversationID = conversationID ?? selectedID
        let generation = speechGeneration
        if configuration.provider == .system {
            let utterance = AVSpeechUtterance(string: text)
            if let identifier = UserDefaults.standard.string(forKey: "aim.voice.identifier"), !identifier.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: identifier) }
            if let rate = UserDefaults.standard.object(forKey: "aim.voice.rate") as? Double { utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, Float(rate))) }
            speech.speak(utterance); return
        }
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer { if speechGeneration == generation { speechTask = nil; speechPlayer = nil } }
            do {
                guard let key = try voiceKey(configuration.provider), !key.isEmpty else { throw ChatServiceError.missingKey }
                let catalog = try await AIMVoiceCatalog.models(provider: configuration.provider, key: key)
                try Task.checkCancellation()
                guard speechGeneration == generation, let selected = catalog.first(where: { $0.id == configuration.speechModel }) else { throw ChatServiceError.invalidResponse }
                for segment in Self.speechSegments(text) {
                    try Task.checkCancellation(); guard speechGeneration == generation else { throw CancellationError() }
                    let bound = selected.usdPerCharacter.flatMap { price -> Double? in
                        let value = price * Double(segment.count); return value.isFinite && value >= 0 ? value : nil
                    }
                    if UserDefaults.standard.bool(forKey: "aim.budget.enabled") {
                        guard let bound, budgetAdmits(bound) else {
                            setResponseError("This speech request has no verified maximum within this iPhone’s budget.", conversationID: capturedConversationID ?? newDraftID); return
                        }
                    }
                    let id = UUID(), started = Date.now
                    activityRecords = AccountActivityRecord.merge(activityRecords + [.init(id: id, accountID: accountID, deviceID: deviceID, deviceName: UIDevice.current.name,
                        conversationID: capturedConversationID, kind: .cost, provider: configuration.provider.rawValue, modelID: configuration.speechModel, mode: "voice",
                        startedAt: started, costUSD: bound, costState: bound == nil ? .unknown : .reserved)], accountID: accountID)
                    guard persist() else { return }
                    let data = try await VoiceSpeechTransport().audio(text: segment, configuration: configuration, key: key)
                    if let index = activityRecords.firstIndex(where: { $0.id == id }) {
                        activityRecords[index].completedAt = .now; activityRecords[index].updatedAt = .now
                        activityRecords[index].costState = bound == nil ? .unknown : .estimated; persist()
                    }
                    try Task.checkCancellation(); guard speechGeneration == generation else { throw CancellationError() }
                    let playing = try AVAudioPlayer(data: data); speechPlayer = playing
                    guard playing.play() else { throw ChatServiceError.invalidResponse }
                    while playing.isPlaying { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
                }
            } catch is CancellationError {} catch {
                if speechGeneration == generation { setResponseError("The selected speech provider is unavailable. Choose another provider explicitly.", conversationID: capturedConversationID ?? newDraftID) }
            }
        }
    }
    func stopSpeaking() {
        speechGeneration = UUID(); speechTask?.cancel(); speechTask = nil
        speechPlayer?.stop(); speechPlayer = nil; speech.stopSpeaking(at: .immediate)
    }
    /// Called only after the import preview's explicit confirmation.
    /// Persist one complete copy before scheduling normal account synchronization.
    func importProfileArchive(_ archive: AIMProfileArchive) throws {
        guard canPersist, !syncing, !savingPreferences else { throw AccountServiceError.unavailable }
        let copy = try archive.copiedWithNewIDs()
        let oldConversations = conversations, oldProjects = projects
        let oldDirty = dirty, oldProjectDirty = projectDirty
        conversations += copy.conversations; projects += copy.projects
        dirty.formUnion(copy.conversations.map(\.id)); projectDirty.formUnion(copy.projects.map(\.id))
        guard persist() else {
            conversations = oldConversations; projects = oldProjects
            dirty = oldDirty; projectDirty = oldProjectDirty
            throw AccountServiceError.unavailable
        }
        Task { await synchronize() }
    }
    /// Prepare a project draft without moving an already open conversation into it.
    func startProjectChat(_ id: UUID) {
        guard projects.contains(where: { $0.id == id }), !deletedProjects.contains(id) else { return }
        if selectedProjectID == nil { generalDraftID = newDraftID }
        if let draft = projectDraftIDs[id], !conversations.contains(where: { $0.id == draft }) {
            newDraftID = draft
        } else {
            newDraftID = UUID(); projectDraftIDs[id] = newDraftID
        }
        selectedID = nil; selectedProjectID = id; errorMessage = nil
        persist()
    }
    @discardableResult func saveProject(_ project: NativeChatProject) -> Bool {
        guard !deletedProjects.contains(project.id), !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.name.count <= 120, project.instructions.count <= 16_000 else { return false }
        let previous = projects, previousDirty = projectDirty
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        projectDirty.insert(project.id)
        guard persist() else { projects = previous; projectDirty = previousDirty; return false }
        Task { await synchronize() }; return true
    }
    func togglePinnedProject(_ id: UUID) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.isPinned.toggle(); project.updatedAt = .now; saveProject(project)
    }
    /// Keep conversations and local source bytes recoverable. Persist the tombstone before sync.
    @discardableResult func deleteProject(_ id: UUID) -> Bool {
        guard projects.contains(where: { $0.id == id }) else { return false }
        let previous = projects, previousChats = conversations, previousDirty = dirty
        let previousProjectDirty = projectDirty, previousDeleted = deletedProjects
        projects.removeAll { $0.id == id }; deletedProjects.insert(id); projectDirty.insert(id)
        for index in conversations.indices where conversations[index].projectID.flatMap(UUID.init(uuidString:)) == id {
            conversations[index].projectID = nil; conversations[index].updatedAt = .now; dirty.insert(conversations[index].id)
        }
        guard persist() else {
            projects = previous; conversations = previousChats; dirty = previousDirty
            projectDirty = previousProjectDirty; deletedProjects = previousDeleted; return false
        }
        if selectedProjectID == id { selectedProjectID = nil }
        Task { await synchronize() }; return true
    }
    func assignProject(_ projectID: UUID?) {
        selectedProjectID = projectID
        if var conversation = selected { conversation.projectID = projectID?.uuidString; conversation.updatedAt = .now; update(conversation); Task { await synchronize() } }
    }
    func export() throws -> URL {
        let file = URL.temporaryDirectory.appending(path: "AIM-chat-\(UUID().uuidString).json")
        try JSONEncoder().encode(AIMProfileArchive.make(conversations: conversations, projects: projects)).write(to: file, options: [.atomic, .completeFileProtection]); return file
    }
    func synchronize() async {
        guard !usesNativeUITestFixture else { return }
        guard let sync, !savingPreferences else { return }
        await synchronizeReadReceipts()
        guard !syncing else { syncRequested = true; return }
        syncing = true
        defer {
            syncing = false
            if syncRequested { syncRequested = false; Task { await synchronize() } }
        }
        do {
            let documents = try await sync.documents(accountID: accountID)
            for document in documents {
                revisions[document.id] = document.revision
                if document.kind == "project", document.deleted {
                    deletedProjects.insert(document.id); projects.removeAll { $0.id == document.id }
                    if selectedProjectID == document.id { selectedProjectID = nil }
                    for index in conversations.indices where conversations[index].projectID.flatMap(UUID.init(uuidString:)) == document.id {
                        conversations[index].projectID = nil; dirty.insert(conversations[index].id)
                    }
                    continue
                }
                guard !document.deleted else { continue }
                if document.kind == "chat", let data = document.payload.data(using: .utf8), let incoming = try? JSONDecoder().decode(NativeChatConversation.self, from: data), incoming.id == document.id {
                    guard responseTasks[incoming.id] == nil else { continue }
                    if let index = conversations.firstIndex(where: { $0.id == incoming.id }) {
                        let merged = conversations[index].merging(incoming)
                        if merged != incoming { dirty.insert(incoming.id) }; conversations[index] = merged
                    } else { conversations.append(incoming) }
                } else if document.kind == "project", let data = document.payload.data(using: .utf8), let incoming = try? JSONDecoder().decode(NativeChatProject.self, from: data), incoming.id == document.id {
                    guard !deletedProjects.contains(incoming.id), !projectDirty.contains(incoming.id) else { continue }
                    if let index = projects.firstIndex(where: { $0.id == incoming.id }) {
                        if incoming.updatedAt >= projects[index].updatedAt {
                            var value = incoming
                            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                            if fields?["memoryScope"] == nil { value.memoryScope = projects[index].memoryScope }
                            if fields?["isPinned"] == nil { value.isPinned = projects[index].isPinned }
                            projects[index] = value
                        }
                    } else { projects.append(incoming) }
                } else if document.id == preferencesID, !preferencesDirty, let data = document.payload.data(using: .utf8), let saved = try? JSONDecoder().decode(AccountChatPreferences.self, from: data) { preferences = saved
                } else if document.id == pinsID, let data = document.payload.data(using: .utf8), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
                    let merged = saved.union(pinnedModels.subtracting(pinnedBase)).subtracting(pinnedBase.subtracting(pinnedModels))
                    pinnedModels = pinsDirty ? merged : saved; pinnedBase = saved
                } else if document.id == favoritesID, let data = document.payload.data(using: .utf8), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
                    let merged = saved.union(favorites.subtracting(favoritesBase)).subtracting(favoritesBase.subtracting(favorites))
                    favorites = favoritesDirty ? merged : saved; favoritesBase = saved
                }
            }
            // Tombstones may arrive before or after their chats in the server response.
            for index in conversations.indices {
                if let project = conversations[index].projectID.flatMap(UUID.init(uuidString:)), deletedProjects.contains(project) {
                    conversations[index].projectID = nil; dirty.insert(conversations[index].id)
                }
            }
            var documentFailures: [String] = []
            // Deletions cannot be held hostage by an unrelated oversized/failed chat.
            for id in Array(projectDirty) where deletedProjects.contains(id) {
                do {
                    let saved = try await sync.save(.init(id: id, kind: "project", payload: "{}", revision: revisions[id] ?? 0, deleted: true), accountID: accountID)
                    revisions[id] = saved.revision; projectDirty.remove(id)
                } catch { documentFailures.append(error.localizedDescription) }
            }
            for id in Array(dirty) {
                guard responseTasks[id] == nil, let conversation = conversations.first(where: { $0.id == id }) else { continue }
                do {
                    let payload = String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self)
                    guard payload.utf8.count <= 16_000_000 else { throw NativeDocumentError.synchronizationLimit }
                    let saved = try await sync.save(.init(id: id, kind: "chat", payload: payload, revision: revisions[id] ?? 0), accountID: accountID)
                    revisions[id] = saved.revision; if conversations.first(where: { $0.id == id }) == conversation { dirty.remove(id) }
                } catch { documentFailures.append(error.localizedDescription) }
            }
            for id in Array(projectDirty) where !deletedProjects.contains(id) {
                guard let project = projects.first(where: { $0.id == id }) else { continue }
                do {
                    let saved = try await sync.save(.init(id: id, kind: "project", payload: String(decoding: try JSONEncoder().encode(project), as: UTF8.self), revision: revisions[id] ?? 0), accountID: accountID)
                    revisions[id] = saved.revision; if projects.first(where: { $0.id == id }) == project { projectDirty.remove(id) }
                } catch { documentFailures.append(error.localizedDescription) }
            }
            if favoritesDirty {
                let selectedFavorites = favorites
                let payload = String(decoding: try JSONEncoder().encode(selectedFavorites), as: UTF8.self)
                let saved = try await sync.save(.init(id: favoritesID, kind: "favorites", payload: payload, revision: revisions[favoritesID] ?? 0), accountID: accountID)
                revisions[favoritesID] = saved.revision; favoritesBase = selectedFavorites; favoritesDirty = favorites != selectedFavorites
            }
            if pinsDirty {
                let selectedPins = pinnedModels
                let payload = String(decoding: try JSONEncoder().encode(selectedPins), as: UTF8.self)
                let saved = try await sync.save(.init(id: pinsID, kind: "favorites", payload: payload, revision: revisions[pinsID] ?? 0), accountID: accountID)
                revisions[pinsID] = saved.revision; pinnedBase = selectedPins; pinsDirty = pinnedModels != selectedPins
            }
            if preferencesDirty {
                let selectedPreferences = preferences
                let payload = String(decoding: try JSONEncoder().encode(selectedPreferences), as: UTF8.self)
                let saved = try await sync.save(.init(id: preferencesID, kind: "preferences", payload: payload, revision: revisions[preferencesID] ?? 0), accountID: accountID)
                revisions[preferencesID] = saved.revision; preferencesDirty = preferences != selectedPreferences
            }
            syncMessage = documentFailures.first; persist()
        } catch { syncMessage = error.localizedDescription; persist() }
    }
    private func update(_ conversation: NativeChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index] = conversation }
        else { conversations.insert(conversation, at: 0) }
        dirty.insert(conversation.id); persist()
    }
    private struct Snapshot: Codable {
        var executionTarget: ChatExecutionTarget? = nil
        var readReceipts: ConversationReadReceipts?
        var pendingSubmissions: [UUID: PendingSubmission]?
        var visualDraftReports: [UUID: VisualAnalysisReport]?
        var drafts: [UUID: String]?; var inputDrafts: [UUID: [NativeChatAttachment]]?; var newDraftID: UUID?
        var pinnedModels: Set<String>?; var pinnedBase: Set<String>?; var pinsDirty: Bool?
        var activityRecords: [AccountActivityRecord]?; var memory: AccountMemorySnapshot?; var lastActivitySync: Date?
        var generalDraftID: UUID?
        var deletedProjects: Set<UUID>?; var projectDraftIDs: [UUID: UUID]?
        var projects: [NativeChatProject]?; var projectDirty: Set<UUID>?; var favoritesBase: Set<String>?
        let conversations: [NativeChatConversation]; let favorites: Set<String>; let revisions: [UUID: Int]; let dirty: Set<UUID>; let favoritesDirty: Bool; let preferences: AccountChatPreferences?; let preferencesDirty: Bool?
    }
    @discardableResult private func persist() -> Bool {
        if usesNativeUITestFixture { return true } // Synthetic UI state never writes account data.
        guard canPersist else { return false }
        do { try JSONEncoder().encode(Snapshot(executionTarget: executionTarget, readReceipts: readReceipts, pendingSubmissions: pendingSubmissions, visualDraftReports: visualDraftReports, drafts: drafts, inputDrafts: inputDrafts, newDraftID: newDraftID, pinnedModels: pinnedModels, pinnedBase: pinnedBase, pinsDirty: pinsDirty, activityRecords: activityRecords, memory: memory, lastActivitySync: lastActivitySync, generalDraftID: generalDraftID, deletedProjects: deletedProjects, projectDraftIDs: projectDraftIDs, projects: projects, projectDirty: projectDirty, favoritesBase: favoritesBase, conversations: conversations, favorites: favorites, revisions: revisions, dirty: dirty, favoritesDirty: favoritesDirty, preferences: preferences, preferencesDirty: preferencesDirty)).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
        catch { errorMessage = "Chat could not be saved on this device. Export it before closing AIM."; return false }
        return true
    }
}

@MainActor @Observable final class AIMWebConnectorStore {
    var servers: [MCPServerConfiguration] = []
    var tools: [MCPWebTool] = []
    var loadedServerID: UUID?
    var errorMessage: String?
    var resultText: String?
    var busy = false
    var draftConnector: PortableConnector?
    let accountID: UUID
    private let credentials: any SecureStoring
    private var client: MCPWebClient?
    private var operationID: UUID?
    private var canPersist = true
    init(accountID: UUID, credentials: (any SecureStoring)? = nil) {
        self.accountID = accountID
        self.credentials = credentials ?? KeychainSecureStore(service: (Bundle.main.bundleIdentifier ?? "com.aimai.ios") + ".web-connectors")
        do {
            if let data = try self.credentials.readData(forKey: "servers." + accountID.uuidString) {
                servers = try JSONDecoder().decode([MCPServerConfiguration].self, from: data)
            }
            // Preserve exceptions selected by earlier builds; configurations remain device/account local.
            let legacy = (UserDefaults.standard.dictionary(forKey: "aim.connector.exceptions." + accountID.uuidString) as? [String: String]) ?? [:]
            var migrated = servers
            for index in migrated.indices {
                for (key, value) in legacy where key.hasPrefix(migrated[index].id.uuidString + ":") {
                    let action = String(key.dropFirst(migrated[index].id.uuidString.count + 1))
                    if let decision = ConnectorPermissionPolicy.Decision(rawValue: value), migrated[index].actionPermissions?[action] == nil {
                        if migrated[index].actionPermissions == nil { migrated[index].actionPermissions = [:] }
                        migrated[index].actionPermissions?[action] = decision
                    }
                }
            }
            if migrated != servers { try persist(migrated); servers = migrated }
        } catch { canPersist = false; errorMessage = "Saved connectors could not be read. Existing data has been preserved; restart AIM before changing connections." }
    }
    @discardableResult func add(name: String, url: String, token: String, connectorID: String? = nil) throws -> MCPServerConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = URL(string: url), endpoint.scheme == "https", endpoint.host?.isEmpty == false,
              !token.contains("\n"), !token.contains("\r"), !token.contains("\0") else { throw MCPWebError.unsupportedTransport }
        var server = MCPConnectionIdentity.new(name: name, endpoint: endpoint, existing: servers, connectorID: connectorID)
        server.secretNames = token.isEmpty ? [] : ["AUTHORIZATION"]
        guard server.isValid else { throw MCPWebError.unsupportedTransport }
        let key = secretKey(server.id)
        if !token.isEmpty { try credentials.store(Data(token.utf8), forKey: key) }
        do { let next = servers + [server]; try persist(next); servers = next }
        catch { try? credentials.removeData(forKey: key); throw error }
        errorMessage = nil; return server
    }
    func disconnect(_ server: MCPServerConfiguration) async {
        if loadedServerID == server.id { await close() }
        do {
            let original = servers, tokenKey = secretKey(server.id), oauthKey = secretKey(server.id) + ".oauth"
            let token = try credentials.readData(forKey: tokenKey), oauth = try credentials.readData(forKey: oauthKey)
            let next = servers.filter { $0.id != server.id }
            try persist(next)
            do {
                try credentials.removeData(forKey: tokenKey); try credentials.removeData(forKey: oauthKey)
                servers = next; errorMessage = nil
            } catch {
                if let token { try? credentials.store(token, forKey: tokenKey) }
                if let oauth { try? credentials.store(oauth, forKey: oauthKey) }
                try? persist(original)
                throw error
            }
        } catch { errorMessage = "The connection could not be removed. Your existing connections have been kept; retry after unlocking the device." }
    }
    func loadTools(_ server: MCPServerConfiguration) async {
        let operation = UUID(); operationID = operation; busy = true
        defer { if operationID == operation { busy = false } }
        tools = []; loadedServerID = nil; errorMessage = nil; resultText = nil
        let previous = client; client = nil; await previous?.close()
        guard operationID == operation else { return }
        do {
            guard server.enabled, servers.contains(where: { $0.id == server.id }),
                  server.transport == .http, let raw = server.url, let url = URL(string: raw) else { throw MCPWebError.unsupportedTransport }
            let credentials = credentials, key = secretKey(server.id)
            let opened = try MCPWebClient(url: url, authorization: { refresh in
                if let data = try credentials.readData(forKey: key + ".oauth") {
                    let saved = try JSONDecoder().decode(MCPAuthorizationTokens.self, from: data)
                    guard saved.resource == url else { throw MCPAuthorizationError.invalidToken }
                    let tokens = try await saved.refreshed(force: refresh)
                    try credentials.store(JSONEncoder().encode(tokens), forKey: key + ".oauth")
                    return tokens.accessToken
                }
                guard let data = try credentials.readData(forKey: key) else { return nil }; return String(data: data, encoding: .utf8)
            })
            client = opened; try await opened.initialize()
            let definitions = try await opened.definitions().filter { server.allows(tool: $0.name) }
            guard operationID == operation, servers.contains(where: { $0.id == server.id && $0.enabled }) else { await opened.close(); return }
            tools = definitions; loadedServerID = server.id
        } catch { if operationID == operation { errorMessage = "Could not load connector actions. Check its connection, authentication and endpoint, then retry." } }
    }
    @discardableResult func saveOAuth(name: String, url: URL, tokens: MCPAuthorizationTokens,
                                      reconnecting id: UUID? = nil, connectorID: String? = nil) throws -> MCPServerConfiguration {
        guard tokens.resource == url else { throw MCPAuthorizationError.invalidToken }
        let server: MCPServerConfiguration
        if let id {
            guard let existing = servers.first(where: { $0.id == id }), existing.url == url.absoluteString else { throw MCPAuthorizationError.invalidToken }
            server = existing
        } else { server = MCPConnectionIdentity.new(name: name, endpoint: url, existing: servers, connectorID: connectorID) }
        guard server.isValid else { throw MCPWebError.unsupportedTransport }
        let key = secretKey(server.id) + ".oauth", previous = try credentials.readData(forKey: secretKey(server.id) + ".oauth")
        try credentials.store(JSONEncoder().encode(tokens), forKey: key)
        do {
            let next = id == nil ? servers + [server] : servers
            try persist(next); servers = next; errorMessage = nil; return server
        } catch {
            if let previous { try? credentials.store(previous, forKey: key) } else { try? credentials.removeData(forKey: key) }
            throw error
        }
    }
    func saveConfiguration(_ updated: MCPServerConfiguration) throws {
        guard updated.isValid, let index = servers.firstIndex(where: { $0.id == updated.id }), servers[index].url == updated.url else { throw MCPWebError.unsupportedTransport }
        var next = servers; next[index] = updated; next[index].updatedAt = .now
        try persist(next); servers = next; errorMessage = nil
    }
    func setPermission(serverID: UUID, action: String, decision: ConnectorPermissionPolicy.Decision?) {
        guard var updated = servers.first(where: { $0.id == serverID }) else { return }
        if updated.actionPermissions == nil { updated.actionPermissions = [:] }
        updated.actionPermissions?[action] = decision
        do { try saveConfiguration(updated) } catch { errorMessage = "This permission could not be saved." }
    }
    func assessment(serverID: UUID, action: String, arguments: RemoteJSONValue? = nil) -> ConnectorPermissionPolicy.Assessment {
        guard let server = servers.first(where: { $0.id == serverID }) else { return .init(effect: .unknown, authorization: .deny) }
        return ConnectorPermissionService.assess(server: server, action: action, arguments: arguments)
    }
    func execute(_ tool: MCPWebTool, serverID: UUID, arguments: String, confirmed: Bool) async {
        guard !busy, loadedServerID == serverID, let client, tools.contains(where: { $0.name == tool.name }) else { return }
        var executionOperation: UUID?
        do {
            guard arguments.utf8.count <= 256 * 1024 else { throw MCPWebError.invalidResponse }
            let json = try JSONDecoder().decode(RemoteJSONValue.self, from: Data(arguments.utf8))
            guard json.objectValue != nil else { throw MCPWebError.invalidResponse }
            let permission = assessment(serverID: serverID, action: tool.name, arguments: json)
            guard permission.authorization != .deny else { errorMessage = "This action is blocked in connector permissions."; return }
            let authorized = confirmed || permission.authorization == .allow
            guard authorized else { errorMessage = MCPWebError.approvalRequired.localizedDescription; return }
            let operation = UUID(); operationID = operation; executionOperation = operation; busy = true
            defer { if operationID == operation { busy = false } }
            let result = try await client.call(tool.name, arguments: json, authorized: authorized)
            guard operationID == operation, loadedServerID == serverID else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            resultText = String(decoding: try encoder.encode(result), as: UTF8.self); errorMessage = nil
        } catch {
            if executionOperation == nil || executionOperation == operationID {
                errorMessage = "The action could not finish. Check its JSON arguments and connection. Verify any effect before trying again."
            }
        }
    }
    func close() async { operationID = nil; busy = false; let previous = client; client = nil; tools = []; loadedServerID = nil; resultText = nil; await previous?.close() }
    private func secretKey(_ id: UUID) -> String { accountID.uuidString + "." + id.uuidString }
    private func persist(_ values: [MCPServerConfiguration]) throws {
        guard canPersist else { throw MCPWebError.invalidResponse }
        try credentials.store(JSONEncoder().encode(values), forKey: "servers." + accountID.uuidString)
    }
}

struct NativeVisualApproval: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let projectID: UUID?
    let text: String
    let primaryProvider: ChatProvider
    let primaryModel: String
    let catalog: [ChatModel]
    let target: ChatExecutionTarget
    let selectConversation: Bool
    let attachments: [NativeChatAttachment]
    let sources: [NativeChatAttachment]
}

private struct NativeChatBudgetRefusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
