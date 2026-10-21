import AIMAgentRuntime
import AIMAgentKit
import AppKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {

    var mode: AIMMode = .chat
    var conversations: [Conversation] = []
    var projectPageVisible = false
    var projects: [AIMApplication.AIMProject] = []
    var projectSourceRevision = 0
    var selectedProjectID: UUID?
    var showProjects = false
    var selectedConversationID: UUID?
    var searchTargetMessageID: UUID?
    var messages: [ConversationMessage] = []
    var voiceSession: (any VoiceConversation)?
    var remoteStatus: RemoteHost.Status = .stopped
    private(set) var remoteEnabled = AIMInstallationContext.sharedPreferences.bool(forKey: "AIMRemoteEnabled")
    private(set) var remoteHostAvailable = false
    private(set) var isChangingRemote = false
    var remoteHost: RemoteHost?
    var remoteBridge: RemoteHostBridge?
    var directRemote: MacDirectRemoteCoordinator?
    var directRemoteError: String?
    var remoteTasks: [Task<Void, Never>] = []
    var compactedThroughSequence: Int?
    var composerText = "" { didSet { scheduleComposerSave() } }
    var pendingAttachments: [TextAttachment] = [] { didSet { scheduleComposerSave() } }
    var pendingImages: [ImageAttachment] = [] { didSet { scheduleComposerSave() } }
    var isImportingAttachment = false
    private var cancelAttachmentPreparation: (() -> Void)?
    func cancelAttachmentImport() { cancelAttachmentPreparation?() }
    var importingAttachmentName: String?
    var attachmentImportErrors: [String] = []
    var isImportingProjectDocument = false
    var isIndexingProjectSource = false
    var isBranchingConversation = false
    var responseSaveError: String?
    var isRetryingResponseSave = false
    var unsavedResponse: ConversationMessage? { responseSaveError == nil ? nil : draftAssistantMessage }
    var selectedModelID = ""
    var selectedProvider: ChatProvider = .openRouter
    var connectedProviders: Set<ChatProvider> = []
    private var providerInventoryRevision: UInt64 = 0
    /// A Black Forest Labs (FLUX) key is saved.
    var hasFluxKey = false
    var availableModels: [ChatModel] = []
    var isLoadingModels = false
    var catalogError: String?
    var hasProviderKey: Bool { connectedProviders.contains(selectedProvider) }
    var showProviderSetup = false
    var showModelPicker = false
    var attachmentPickerRequestID = UUID()
    var settingsSection: SettingsSection?
    var requestedPanel: WorkbenchPanelKind?
    /// Sources, actions or a page to show in the right panel of the current conversation.
    var requestedWorkbench: WorkbenchRequest?
    /// The Mission permissions sheet (apps and sites the agent may use without asking).
    var showMissionAuthorization = false
    var archivedConversations: [Conversation] = []
    var isShowingArchives = false
    var modelDisplayName: String {
        let name = availableModels.first(where: { $0.id == selectedModelID })?.name ?? (selectedModelID.isEmpty ? "Choose model" : selectedModelID)
        guard let effort = reasoningEffort(provider: selectedProvider, modelID: selectedModelID) else { return name }
        return "\(name) · \(effort.title)"
    }
    /// OpenRouter's public catalog indexed by model identity (prices, reasoning levels…),
    /// also describing models reached through a direct provider.
    var modelReference: [String: ChatModel] = [:]

    /// The catalog facts for a model, enriched from OpenRouter's public catalog.
    func modelInfo(provider: ChatProvider, modelID: String) -> ChatModel? {
        let base = availableModels.first { $0.id == modelID } ?? (modelID.isEmpty ? nil : ChatModel(id: modelID, name: modelID))
        return base.map { ModelDetailsLookup.enriched($0, provider: provider, index: modelReference) }
    }

    /// The saved effort if this model accepts it; otherwise the model default (nil).
    func reasoningEffort(provider: ChatProvider, modelID: String) -> OpenAIReasoningEffort? {
        OpenAIReasoningEffort.effective(settings.openAIReasoningEffortByModel?[modelID], provider: provider, modelID: modelID,
                                        info: modelInfo(provider: provider, modelID: modelID)?.reasoning)
    }
    var workspacePath: String?
    var recentWorkspacePaths: [String] { settings.recentWorkspacePaths ?? [] }
    var isChangingWorkspace = false
    var workspaceToolsEnabled = false { didSet { if !workspaceToolsEnabled { workspaceTextToolProtocol = false; workspaceEditsEnabled = false; workspaceCommandsEnabled = false; workspacePlanOnly = false; approvalPolicy = .alwaysAsk } } }
    var workspaceTextToolProtocol = false
    var workspaceEditsEnabled = false
    var workspaceCommandsEnabled = false
    var workspacePlanOnly = false { didSet { if workspacePlanOnly { workspaceEditsEnabled = false; workspaceCommandsEnabled = false } } }
    var approvalPolicy: ApprovalPolicy = .alwaysAsk
    var transcriptSearchRequest = UUID()
    /// The durable-task decision card the person hid (execution ID and revision); it returns when the task changes.
    var dismissedContinuityDecision: String?
    var pendingToolApprovals: [PendingToolApproval] = [] {
        didSet {
            let fresh = pendingToolApprovals.filter { approval in !oldValue.contains { $0.id == approval.id } }
            if let first = fresh.first {
                // Using the real pointer and keyboard is a hand-over the person grants when ready.
                if first.toolName.hasPrefix("desktop_") && first.toolName != "desktop_list_windows" && first.toolName != "desktop_read_window" {
                    // Shown even while AIM is in front: the person is using the Mac by definition.
                    AIMNotifier.post(.approval, title: "AIM needs to take control of your Mac",
                        body: "Open the conversation and allow it when you are ready: AIM will use your pointer and keyboard. The task waits until then.",
                        preferences: preferences, evenWhenActive: true)
                } else {
                    AIMNotifier.post(.approval, title: "AIM needs your approval", body: RemoteHostBridge.summary(first), preferences: preferences)
                }
            }
        }
    }
    var pendingAgentQuestions: [AgentQuestion] = [] {
        didSet {
            let fresh = pendingAgentQuestions.filter { question in !oldValue.contains { $0.id == question.id } }
            if !fresh.isEmpty {
                AIMNotifier.post(.question, title: "AIM has a question", body: "Answer it to let the task continue.", preferences: preferences)
            }
        }
    }
    var agentPlan: AgentPlan?
    var agentMission: AgentMission?
    var missionAuthorization: MissionAuthorization?
    var isSavingMissionAuthorization = false
    var actionReconciliations: [ActionReconciliation] = []
    var isReviewingMission = false
    var activeToolName: String?
    var toolRunProvider: ChatProvider?
    var toolRunModelID = ""
    var toolRunConversationID: UUID?
    var completedToolCount = 0
    var toolProgress = ToolProgressWindow()
    func remoteWorkspaceHistory(conversationID: UUID) async throws -> [WorkspaceRunHistory] {
        try await workspaceRunRepository.history(conversationID: conversationID, limit: 100)
    }
    var workspaceHistory: [WorkspaceRunHistory] = []
    var workspaceHistoryError: String?
    private var workspaceHistoryLoadID = UUID()
    var showWorkspaceHistory = false
    var engineStatuses: [EngineStatus] = AgentEngineID.allCases.map {
        EngineStatus(id: $0, state: $0 == .aim ? .stopped : .notInstalled, isInstalled: $0 == .aim)
    }
    var selectedAgentEngineID: AgentEngineID = .aim
    var agentInstallProgress: [AgentEngineID: RuntimeInstallProgress] = [:]
    var agentInstallErrors: [AgentEngineID: String] = [:]
    /// Installed agents with a newer vetted version in this app, and that version.
    var agentUpdateAvailable: [AgentEngineID: String] = [:]
    var permissionStates: [MacPermissionKind: MacPermissionState] = [:]
    var settings = AppSettings()
    var activityEntries: [ActivityEntry] = []
    var activityError: String?
    var memories: [MemoryItem] = []
    var memoryError: String?
    var accountMemoryRevision: Int?
    var legacyMemoryPreview: [MemoryItem] = []
    var spendSnapshot: SpendSnapshot?
    var spendBreakdown: SpendBreakdown?
    var recentSpendAttempts: [SpendAttempt] = []
    var recentSpendCorrections: [SpendCostCorrection] = []
    var spendReportError: String?
    var pendingSpendExceptions: [PendingSpendException] = []
    var cuaDriverDiagnostic: CuaDriverDiagnosticReport?
    var cuaDriverError: String?
    var isCheckingCuaDriver = false
    var cuaFixtureResult: String?
    var isRunningCuaFixture = false

    func checkEmbeddedCuaDriver() async {
        guard !isCheckingCuaDriver, !isRunningCuaFixture else { return }
        isCheckingCuaDriver = true
        defer { isCheckingCuaDriver = false }
        do {
            cuaDriverDiagnostic = try await cuaDriverDiagnostics.probe()
            cuaDriverError = nil
        } catch {
            cuaDriverDiagnostic = nil
            cuaDriverError = error.localizedDescription
        }
    }

    func runCuaFixtureQualification() async {
        guard !isRunningCuaFixture, !isCheckingCuaDriver else { return }
        isRunningCuaFixture = true
        defer { isRunningCuaFixture = false }
        #if DEBUG
        let report = QualificationReport(suite: "cua-ladder", destination: nil)
        await CuaCapabilityQualifier.run(into: report)
        let recorded = await recordCuaQualification(report)
        let conclusion = report.value("conclusion") as? String ?? "Fixture qualification did not finish."
        cuaFixtureResult = recorded.isEmpty
            ? "No background capability qualified. \(conclusion)"
            : "Qualified on AgentFixture: \(recorded.map(\.rawValue).joined(separator: ", ")). \(conclusion)"
        #else
        cuaFixtureResult = "Fixture qualification is available in development builds only."
        #endif
    }

    /// Adopts the signed bundle's CUA release manifest for this Mac (see CuaReleaseManifest).
    nonisolated static func adoptCuaReleaseManifest(into repository: SQLiteCuaQualificationRepository) async -> Int {
        await CuaRuntimeIdentity.adoptReleaseManifest(into: repository)
    }

    #if DEBUG
    /// Persists the capabilities a finished ladder report proves for this exact
    /// driver binary, macOS build and adapter contract.
    @discardableResult
    func recordCuaQualification(_ report: QualificationReport) async -> [CuaCapability] {
        guard let key = await CuaRuntimeIdentity.currentKey(),
              let digest = report.value("schema_digest") as? String else { return [] }
        let capabilities = CuaCapabilityQualifier.qualifiedCapabilities(in: report)
        let evidence = String(decoding: report.encoded().prefix(60 * 1_024), as: UTF8.self)
        var recorded: [CuaCapability] = []
        for capability in capabilities {
            do {
                try await cuaQualificationRepository.record(CuaQualificationRecord(key: key, capability: capability,
                    schemaDigest: digest, qualifiedAt: .now, evidence: evidence))
                recorded.append(capability)
            } catch {
                continue
            }
        }
        return recorded
    }
    #endif

    func loadSpendReport() async {
        do {
            let now = Date.now
            spendSnapshot = try await spendLedger.snapshot(at: now)
            spendBreakdown = try await spendLedger.breakdown(at: now)
            recentSpendAttempts = try await spendLedger.recentAttempts()
            recentSpendCorrections = try await spendLedger.recentCorrections()
            spendReportError = nil
        } catch {
            spendBreakdown = nil
            spendReportError = error.localizedDescription
        }
    }

    func configureSpendPolicy(_ policy: GlobalSpendPolicy) async throws {
        try await spendLedger.configure(policy)
        await loadSpendReport()
    }

    func decideSpendException(id: UUID, allow: Bool) async {
        _ = await spendExceptions.decide(id: id, allow: allow)
        await loadSpendReport()
    }

    func setAnthropicOutputTokens(_ tokens: Int?, modelID: String) async throws {
        guard !modelID.isEmpty, tokens == nil || tokens! > 0 else { throw ModelToolError.invalidConfiguration }
        let previous = settings.anthropicOutputTokensByModel
        var updated = previous ?? [:]
        updated[modelID] = tokens
        settings.anthropicOutputTokensByModel = updated
        do { try await settingsRepository.save(settings) }
        catch {
            if settings.anthropicOutputTokensByModel == updated { settings.anthropicOutputTokensByModel = previous }
            throw error
        }
    }
    func setOpenAIReasoningEffort(_ effort: OpenAIReasoningEffort?, modelID: String) async throws {
        guard !modelID.isEmpty else { throw ModelToolError.invalidConfiguration }
        let previous = settings.openAIReasoningEffortByModel
        var updated = previous ?? [:]
        updated[modelID] = effort
        settings.openAIReasoningEffortByModel = updated
        do { try await settingsRepository.save(settings) }
        catch {
            if settings.openAIReasoningEffortByModel == updated { settings.openAIReasoningEffortByModel = previous }
            throw error
        }
    }
    var queuedMessages: [QueuedMessage] = []
    /// ⌥⌘D (Settings › Keyboard shortcuts): the composer starts or stops dictation.
    var dictationRequestID: UUID?
    @ObservationIgnored let powerActivity = PowerActivityController()
    var isSending = false { didSet { if isSending != oldValue { sendingChanged() } } }
    var isGeneratingImage = false
    var isShuttingDown = false
    var isLoadingConversation = false
    var isBootstrapping = true
    var alertMessage: String? {
        didSet {
            guard let alertMessage, alertMessage != oldValue,
                  [SpendAdmissionError.limitReached.errorDescription, ChatServiceError.planLimitReached.errorDescription].contains(alertMessage) else { return }
            AIMNotifier.post(.limit, title: "Usage limit reached", body: alertMessage, preferences: preferences)
        }
    }

    let paths: ApplicationPaths?
    let account: MacAccountController
    private static let testLocalProfileStore = EphemeralProviderKeyStore()
    #if DEBUG
    /// Settings gallery only: shows a given gate screen without an account service.
    var debugAccessOverride: AccountAccess?
    /// Settings gallery only: asks a view to open one of its menus ("policies", "folders", "add", "spaces", "profile").
    var debugOpenMenu: String?
    /// Settings gallery only: shows a dictation state ("recording", "transcribing", "retry", "menu", "idle").
    var debugDictation: String?
    /// Debug gallery: show every turn's work unfolded.
    var debugExpandTurns = false
    /// Debug gallery: sub-agents shown instead of the execution store's.
    var debugSubagents: [SubagentSnapshot]?
    #endif
    var access: AccountAccess {
        #if DEBUG
        if let debugAccessOverride { return debugAccessOverride }
        #endif
        return AccountAccessPolicy.access(identity: account.identity, offline: account.offlineUser != nil)
    }
    var hasAccess: Bool { access.isGranted }
    let updateController: MacUpdateController
    let launchAtLoginController: LaunchAtLoginController

    let database: AIMDatabase
    let conversationRepository: any ConversationRepository
    private let workspaceRunRepository: any WorkspaceRunRepository
    private let subagentJobRepository: any SubagentJobRepository
    let cuaQualificationRepository: SQLiteCuaQualificationRepository
    let mcpServerRepository: SQLiteMCPServerRepository
    private let accountChatSync: AccountChatSync
    @ObservationIgnored private(set) lazy var localHistoryCopy = LocalHistoryCopyCoordinator(account: account, sync: accountChatSync) { [weak self] in
        guard let self else { return }
        try await self.reloadConversations()
        self.projects = try await self.visibleProjects()
        await self.synchronizeAccountChat()
    }
    private let accountPreferenceScopes: AccountChatPreferenceScopeStore
    private var accountPreferenceScopeReady = false
    private var accountPreferenceScopeInitialized = false
    private var accountPreferenceScopeOwner: UUID?
    private var pendingPreferenceSnapshot: AccountChatPreferenceScopeStore.Snapshot?
    private var accountChatPreferences = AccountChatPreferences()
    private var accountSyncTask: Task<Void, Never>?
    var accountSyncMessage: String?
    let accountActivityRepository: SQLiteAccountActivityRepository
    var accountActivityRecords: [AccountActivityRecord] = []
    var accountActivitySyncedAt: Date?
    var accountActivityError: String?
    private var activeAccountTask: AccountActivityRecord?
    let metricsRepository: SQLiteMessageMetricsRepository
    /// What AIM measured for the answers of the open conversation.
    var messageMetrics: [UUID: TurnMetrics] = [:]
    /// Debug gallery: shows the latest answer's statistics tooltip.
    var debugShowsMetrics = false
    /// Debug gallery: a conversation drawn as running.
    var debugRunningConversationID: UUID?
    #if DEBUG
    /// Debug gallery: made-up statistics for the profile page.
    var debugProfileSample: (metrics: [TurnMetrics], activity: [Date], tools: [(name: String, count: Int)])?
    #endif
    /// When each conversation was last opened (sidebar's unread dot).
    var lastReadAt: [UUID: Date] = [:]
    private var knownLegacyReads: [UUID: LegacyConversationReadState] = [:]
    var accountReadReceipts = ConversationReadReceipts()
    var conversationResponseVersions: [UUID: ConversationResponseVersion] = [:]
    var conversationExecutionDevices: [UUID: [String]] = [:]
    private var readReceiptAccountID: UUID?
    var conversationContinuityAccountMatches: Bool { readReceiptAccountID != nil && readReceiptAccountID == account.accessUser?.id }
    /// What fills the open conversation's context window (the context gauge).
    var contextUsage: ContextUsage?
    var isCompacting = false
    /// Usage measured during the running turn, completed by the provider's token count.
    private var turnContextUsage: [UUID: ContextUsage] = [:]
    /// Conversations whose latest answer failed (sidebar's red dot).
    var failedConversations: Set<UUID> = []
    private var draftMetrics: TurnMetrics?
    /// New conversations whose first answer has not brought a title yet.
    private var awaitingTitle: Set<UUID> = []
    let schedulerRepository: SQLiteSchedulerRepository
    let subagentWorkspaceRepository: SQLiteSubagentWorkspaceRepository
    private var taskScheduler: TaskScheduler?
    private var triggerMonitor: TaskTriggerMonitor?
    private let runsScheduledTasks: Bool
    var scheduledTasks: [ScheduledTask] = []
    private let projectRepository: any ProjectRepository
    private let projectDocuments: SQLiteProjectDocumentRepository
    private let projectSourceIndex: SQLiteProjectSourceIndex
    private let activityRepository: SQLiteActivityRepository
    private let memoryRepository: any MemoryRepository
    private let compactionRepository: any SessionCompactionRepository
    private let planRepository: any AgentPlanRepository
    private let missionRepository: any AgentMissionRepository
    let spendLedger: SQLiteGlobalSpendLedger
    private let spendMeter: BillableRequestMeter
    private let spendExceptions = SpendExceptionBroker()
    private let cuaDriverDiagnostics: CuaDriverDiagnostics
    private let activityTracker: ActivityTracker
    private let settingsRepository: any SettingsRepository
    private let permissions: any MacPermissionChecking
    private let engineRegistry = AgentEngineRegistry()
    private let aimEngine: NativeAIMEngine
    private let coordinatedAgentRunner: any NativeAgentTurnRunning
    private let upstreamInstaller: UpstreamAgentInstaller?
    private var agentInstallTasks: [AgentEngineID: Task<Void, Never>] = [:]
    private let continuityRuntime: AgentRuntimeController?
    private var continuityTask: Task<Void, Never>?
    var continuityExecutions: [AgentExecution] = []
    var continuitySpend: [UUID: SpendSnapshot] = [:]
    var continuityProcesses: [UUID: [DurableProcess]] = [:]
    private var continuityApprovalRoots: [UUID: UUID] = [:]
    private var sentPhoneEvents: Set<UUID> = []
    /// Only tasks that change after launch notify the phone (no burst for earlier tasks).
    private let phoneEventsSince = Date.now
    var isChangingContinuityService = false
    private var runtimeManagedConversations: Set<UUID> = []
    private let additionalAgentEngines: [any AgentEngine]
    private var eventTasks: [AgentEngineID: Task<Void, Never>] = [:]
    private var approvalTask: Task<Void, Never>?
    private var spendExceptionTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var activityTaskID = UUID()
    private var memoryCaptureTasks: [UUID: (UUID, Task<Void, Never>)] = [:]
    /// The last memories saved from a conversation's exchange, shown under that answer.
    struct MemoryNotice: Equatable { var after: UUID; var text: String; var saved = true }
    static let memoryLog = Logger(subsystem: "com.aimai.macos", category: "memory")
    var memoryNotices: [UUID: MemoryNotice] = [:]
    private var imageGenerationTask: Task<ImageAttachment, Error>?
    private var mediaGenerationTask: Task<GeneratedMedia, Error>?
    private var imageGenerationCancelled = false
    /// The Create sheet (images and videos), optionally opened on one model (its slug).
    var showMediaCreator = false
    var mediaCreatorPreset: String?
    private let imageGenerator: any ImageGenerating
    private let toolApprovals = ToolApprovalBroker()
    private let agentQuestions = AgentQuestionBroker()
    private var draftAssistantMessage: ConversationMessage?
    /// Records where reasoning, text and actions happen in the draft answer.
    private var draftTimeline = TurnTimelineBuilder()
    private var draftTimelineMessageID: UUID?
    private var assistantSaveTask: Task<Bool, Never>?
    private var correctionSaveTask: Task<ConversationMessage, Error>?
    private(set) var activeTurnConversationID: UUID?
    private var activeTurnEngineID: AgentEngineID?
    private var didStart = false
    private var remoteRuntimeReady = false
    private var remoteHostStarting = false
    private var remoteHostAccountID: UUID?
    private var pendingSends = 0
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var catalogRequestID = UUID()
    private var navigationID = UUID()
    var dictationContext: UUID { navigationID }
    private var lastTranscriptUpdate = Date.distantPast
    private let composerDraftStore: ComposerDraftStore
    private var composerScope = "new:chat"
    private var composerRevision = UUID()
    private var composerStorageID: UUID?
    var visualDraftReport: VisualAnalysisReport?
    var pendingVisualApproval: PendingMacVisualApproval?
    var isAnalysingVisualInput = false
    typealias PendingMacVisualApproval = MacVisualApproval
    private var currentVisualDraftContext: MacVisualDraftContext? {
        guard let owner = account.identity?.storageID, composerStorageID == owner else { return nil }
        return .init(scope: composerScope, navigation: navigationID, draftRevision: composerRevision, ownerID: owner,
            primaryProvider: selectedProvider, primaryModel: selectedModelID,
            target: "mac:" + visualExecutionDeviceID, credentialScope: account.credentialScope.snapshot())
    }
    private var visualExecutionDeviceID: String {
        if let owner = account.accessUser?.id,
           let machine = try? RemoteHostIdentityStore(accountID: owner).load()?.machineID { return machine }
        return accountActivityRepository.deviceID
    }
    func remoteVisualApproval(conversationID: UUID) -> PendingMacVisualApproval? {
        guard let pending = pendingVisualApproval, pending.conversationID == conversationID,
              pending.context == currentVisualDraftContext,
              pending.ownerID == account.accessUser?.id, selectedConversationID == conversationID else { return nil }
        return pending
    }
    func refuseVisualInput(_ pendingID: UUID) {
        guard pendingVisualApproval?.id == pendingID else { return }
        pendingVisualApproval = nil
        _ = flushComposer()
        alertMessage = "Visual analysis declined. Your draft and source media were kept."
    }
    func analyseVisualInput(_ pending: PendingMacVisualApproval, choice: SubagentModelChoice, remember: Bool) async -> Bool {
        let coordinator = MacVisualDelegationCoordinator(
            currentContext: { self.currentVisualDraftContext },
            catalog: { try await self.catalog(for: $0) },
            credential: { try await self.providerKeyData($0).flatMap { String(data: $0, encoding: .utf8) } ?? "" },
            recordConsent: { pending, choice, remember in
                var defaults = self.accountChatPreferences.subagentDefaults?[pending.target]
                    ?? SubagentPreferenceStore.load(accountID: pending.ownerID, target: pending.target)
                defaults.visual = choice
                if remember { defaults.permanentVisualConsents.insert(choice) }
                try SubagentPreferenceStore.save(defaults, accountID: pending.ownerID, target: pending.target)
                self.accountChatPreferences.subagentDefaults = (self.accountChatPreferences.subagentDefaults ?? [:])
                    .merging([pending.target: defaults]) { _, new in new }
            }, analyser: MeteredMacVisualAnalyser(meter: spendMeter))
        guard !isAnalysingVisualInput, (try? coordinator.validate(pending)) != nil else {
            alertMessage = "The account, draft, target or principal model changed. Review the draft and request visual analysis again."
            return false
        }
        isAnalysingVisualInput = true; defer { isAnalysingVisualInput = false }
        do {
            let report = try await coordinator.analyse(pending, choice: choice, remember: remember)
            visualDraftReport = report
            pendingVisualApproval = nil
            guard flushComposer() else { pendingVisualApproval = pending; return false }
            await synchronizeAccountChat()
            do { try coordinator.validate(pending) }
            catch { alertMessage = "The selected task changed. Analysis is saved with the draft; review before sending."; return false }
            isAnalysingVisualInput = false
            await sendComposer()
            return true
        } catch { alertMessage = error.localizedDescription; return false }
    }
    private var restoringComposer = false
    private var composerLoaded = false
    private var composerSaveTask: Task<Void, Never>?
    private let providerStore: ProfileScopedCredentialStore

    init(database testDatabase: AIMDatabase? = nil, conversationRepository suppliedRepository: (any ConversationRepository)? = nil, turnRunner: (any NativeAgentTurnRunning)? = nil, account suppliedAccount: MacAccountController? = nil, settingsRepository suppliedSettingsRepository: (any SettingsRepository)? = nil, memoryRepository suppliedMemoryRepository: (any MemoryRepository)? = nil, providerStore suppliedProviderStore: (any SecureStoring)? = nil, imageGenerator suppliedImageGenerator: (any ImageGenerating)? = nil, additionalAgentEngines: [any AgentEngine] = []) {
        let bootstrap: (paths: ApplicationPaths?, database: AIMDatabase, alert: String?, lease: RuntimeLease?)
        do {
            if let testDatabase {
                bootstrap = (nil, testDatabase, nil, nil)
            } else {
            let applicationPaths = try ApplicationPaths()
            let permanent = UserDefaults.standard.data(forKey: "aim.settings.v1")
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }.flatMap(\.continuity)?.permanent == true
            let lease = permanent ? nil : try RuntimeLease(url: applicationPaths.applicationSupport.appending(path: "agent-runtime.lock"))
            bootstrap = (
                applicationPaths,
                try AIMDatabase(path: applicationPaths.database.path, mode: permanent ? .existingSchemaOnly : .migrate),
                nil, lease
            )
            }
        } catch {
            // If the user library is temporarily unavailable, keep the native
            // shell launchable and surface the persistence error in the UI.
            bootstrap = (
                nil,
                try! AIMDatabase(inMemory: true),
                "AIM AI could not open its local database: \(error.localizedDescription)", nil
            )
        }
        paths = bootstrap.paths
        account = suppliedAccount ?? (testDatabase != nil ? MacAccountController(infoDictionary: [:], secureStoreOverride: Self.testLocalProfileStore) : MacAccountController())
        database = bootstrap.database
        let accountSyncSecrets: any SecureStoring
        if testDatabase != nil { accountSyncSecrets = EphemeralProviderKeyStore() }
        else { accountSyncSecrets = KeychainSecureStore(service: (HostBundleResources.applicationBundle.bundleIdentifier ?? "com.aimai.macos") + ".chat-sync") }
        accountActivityRepository = SQLiteAccountActivityRepository(
            database: bootstrap.database,
            importOwnersStore: accountSyncSecrets
        )
        composerDraftStore = ComposerDraftStore(database: bootstrap.database)
        alertMessage = bootstrap.alert
        conversationRepository = suppliedRepository ?? SQLiteConversationRepository(database: database)
        workspaceRunRepository = SQLiteWorkspaceRunRepository(database: database)
        subagentJobRepository = SQLiteSubagentJobRepository(database: database)
        cuaQualificationRepository = SQLiteCuaQualificationRepository(database: database)
        mcpServerRepository = SQLiteMCPServerRepository(database: database)
        metricsRepository = SQLiteMessageMetricsRepository(database: database)
        schedulerRepository = SQLiteSchedulerRepository(database: database)
        subagentWorkspaceRepository = SQLiteSubagentWorkspaceRepository(database: database)
        runsScheduledTasks = testDatabase == nil
        projectRepository = SQLiteProjectRepository(database: database)
        accountChatSync = AccountChatSync(repository: conversationRepository, projects: projectRepository, metrics: metricsRepository,
            secureStore: accountSyncSecrets, runs: workspaceRunRepository)
        accountPreferenceScopes = AccountChatPreferenceScopeStore(secureStore: accountSyncSecrets)
        accountPreferenceScopeReady = testDatabase != nil
        projectDocuments = SQLiteProjectDocumentRepository(database: database)
        projectSourceIndex = SQLiteProjectSourceIndex(database: database)
        activityRepository = SQLiteActivityRepository(database: database)
        let memoryAccount = account
        memoryRepository = suppliedMemoryRepository ?? AccountMemoryRepository(legacy: SQLiteMemoryRepository(database: database), binding: {
            try await MainActor.run {
                guard let id = memoryAccount.accessUser?.id else { return nil }
                // Signed in but without a connection: this Mac's copy of the account's memory is used.
                guard let client = memoryAccount.supabaseClient else { return AccountMemoryBinding(accountID: id, service: UnreachableAccountContent()) }
                return AccountMemoryBinding(accountID: id, service: AccountContentSyncService(client: client))
            }
        }, cache: SQLiteAccountMemoryCache(database: database))
        compactionRepository = SQLiteSessionCompactionRepository(database: database)
        planRepository = SQLiteAgentPlanRepository(database: database)
        missionRepository = SQLiteAgentMissionRepository(database: database)
        let ledger = SQLiteGlobalSpendLedger(database: database)
        spendLedger = ledger
        spendMeter = BillableRequestMeter(ledger: ledger, exceptions: spendExceptions)
        cuaDriverDiagnostics = CuaDriverDiagnostics()
        let credentialBacking: any SecureStoring = suppliedProviderStore ?? (testDatabase != nil ? EphemeralProviderKeyStore() : MacProviderKeyStore())
        providerStore = ProfileScopedCredentialStore(backing: credentialBacking, scope: account.credentialScope)
        imageGenerator = suppliedImageGenerator ?? OpenAIImageGenerationService(meter: spendMeter)
        activityTracker = ActivityTracker(sampler: MacActivitySampler(), repository: activityRepository)
        settingsRepository = suppliedSettingsRepository ?? UserDefaultsSettingsRepository()
        permissions = testDatabase == nil ? MacPermissionCenter() : UnavailableMacPermissions()
        updateController = MacUpdateController(startingUpdater: testDatabase == nil)
        launchAtLoginController = LaunchAtLoginController()
        let runtimeDependencies = AgentRuntimeDependencies(conversations: conversationRepository, missions: missionRepository,
            runs: workspaceRunRepository, secureStore: providerStore, memory: memoryRepository,
            settings: settingsRepository, plans: planRepository, ledger: spendLedger,
            cuaQualifications: cuaQualificationRepository, mcpServers: mcpServerRepository,
            projects: projectRepository, documents: projectDocuments, sourceIndex: projectSourceIndex,
            activity: activityRepository, compaction: compactionRepository, jobs: subagentJobRepository,
            workspaces: subagentWorkspaceRepository, scheduler: schedulerRepository)
        let fallback = runtimeDependencies.runner(approvals: toolApprovals, questions: agentQuestions, meter: spendMeter)
        if testDatabase == nil, let paths = bootstrap.paths {
            let vault = try? ExecutionArtifactStore(directory: paths.applicationSupport.appending(path: "AgentArtifacts"))
            let account = self.account
            let controller = AgentRuntimeController(dependencies: runtimeDependencies,
                executions: SQLiteAgentExecutionRepository(database: database, artifacts: vault), lease: bootstrap.lease,
                accountID: { await MainActor.run { account.identity?.storageID } },
                authenticatedAccountID: { await MainActor.run { account.accessUser?.id } })
            continuityRuntime = controller
            let runner = turnRunner ?? CoordinatedTurnRunner(controller: controller, fallback: fallback)
            coordinatedAgentRunner = runner
            aimEngine = NativeAIMEngine(runner: runner)
        } else {
            continuityRuntime = nil
            coordinatedAgentRunner = turnRunner ?? fallback
            aimEngine = NativeAIMEngine(runner: turnRunner ?? fallback)
        }
        upstreamInstaller = bootstrap.paths.map { UpstreamAgentInstaller(root: $0.applicationSupport.appending(path: "Agents")) }
        self.additionalAgentEngines = additionalAgentEngines
        _ = restoreComposer(scope: composerScope)
    }

    #if DEBUG
    /// The model the window started (SwiftUI may build the app value more than once).
    static weak var started: AppModel?
    #endif
    func start() async {
        guard !didStart, !isShuttingDown else { return }
        didStart = true
        #if DEBUG
        Self.started = self
        #endif
        isBootstrapping = true
        ComputerUseActivity.shared.stopHandler = { [weak self] in
            Task { await self?.cancelCurrentTurn() }
        }
        if let cached = await ModelCatalogCache.shared.cached(.openRouter) { modelReference = ModelDetailsLookup.index(cached) }
        // Revocation still stops account work; local execution has its own identity.
        account.onServerRevocation = { [weak self] in
            guard let self else { throw AccountServiceError.unavailable }
            await self.cancelCurrentTurn()
            try await self.continuityRuntime?.cancelAllForSessionRevocation()
            try await self.remoteHost?.processAccountStopRequests()
            self.voiceSession?.stop(); self.cancelImageGeneration()
        }
        account.onAccessChange = { [weak self] _ in
            self?.resetProviderPresentationForIdentityChange()
            Task { await self?.accountAccessChanged() }
        }
        accountSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronizeAccountChat()
                // Memory changes made while the account was unreachable reach it here.
                if let shared = self?.memoryRepository as? AccountMemoryRepository { await shared.flushPending() }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        // Cloud refresh must never hold up local startup when offline.
        Task { await account.start() }
        await engineRegistry.register(aimEngine)
        do {
            if let paths, let external = try ExternalEngineFactory.configured(directory: paths.applicationSupport.appending(path: "ExternalEngine"),
                secureStore: providerStore, approvals: toolApprovals) { await engineRegistry.register(external) }
        } catch { alertMessage = "External adapter configuration could not be loaded: " + error.localizedDescription }
        for engine in additionalAgentEngines { await engineRegistry.register(engine) }
        if let installer = upstreamInstaller {
            for id in UpstreamAgentInstaller.downloadable {
                do {
                    if let installed = try await installer.installation(id) {
                        await registerUpstreamAgent(installed)
                        if installed.updateAvailable { agentUpdateAvailable[id] = UpstreamAgentCatalog.release(id)?.version }
                        Task.detached(priority: .background) { await installer.cleanUp(id) }
                    }
                } catch { agentInstallErrors[id] = error.localizedDescription }
            }
            // An app update brings vetted agent versions: install them in the background while
            // the current version keeps working.
            if !agentUpdateAvailable.isEmpty {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    self?.updateAgentsInBackground()
                }
            }
        }
        do {
            settings = try await settingsRepository.load()
            accountPreferenceScopeReady = true
            try prepareAccountPreferenceScope()
            try await settingsRepository.save(settings)
            await continuityRuntime?.configureRemoteControl { [weak self] command in
                guard let self else { throw AgentHostTransportError.disconnected }
                return try await self.handleIntegratedRemoteControl(command)
            }
            try await continuityRuntime?.start(database: database, maximumRoots: settings.continuity?.maximumRoots ?? 2)
            try await aimEngine.start()
            if settings.continuity?.permanent != true {
                _ = try await missionRepository.recoverInterrupted()
                _ = try await subagentJobRepository.recoverInterrupted()
            }
            let cuaRepository = cuaQualificationRepository
            Task.detached(priority: .utility) { _ = await AppModel.adoptCuaReleaseManifest(into: cuaRepository) }
            // A crash between merge/discard and cleanup leaves an obsolete worktree.
            let finished = (try? await subagentWorkspaceRepository.list(states: [.merged, .discarded])) ?? []
            let leftovers = finished.filter { FileManager.default.fileExists(atPath: $0.worktreePath) }
            if !leftovers.isEmpty {
                Task.detached {
                    let service = SubagentWorkspaceService()
                    for record in leftovers { try? await service.remove(record) }
                }
            }
            settings = try await settingsRepository.load()
            AppearancePreferences.mirror(preferences)
            try prepareAccountPreferenceScope(restoringStored: true)
            try await settingsRepository.save(settings)
            let activity = settings.activity
            settings.activity = ActivitySettings(
                isEnabled: activity.isEnabled,
                retentionDays: activity.retentionDays,
                excludedApplications: activity.excludedApplications,
                excludedDomains: activity.excludedDomains
            )
            if settings.activity != activity { await persistSettings() }
            if await purgeActivity(now: .now) { configureActivityTracking() }
            mode = settings.selectedMode
            selectedAgentEngineID = settings.selectedAgentEngineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim
            _ = restoreComposer(scope: "new:\(mode.rawValue)")
            selectedModelID = settings.selectedModelID == "AIM Preview" ? "" : (settings.selectedModelID ?? "")
            selectedProvider = settings.selectedProvider ?? .openRouter
            workspacePath = settings.workspacePath
            if paths != nil { try launchAtLoginController.setEnabled(settings.launchAtLogin) }
            try await reloadConversations()
            projects = try await visibleProjects()
            await startScheduledTasks()
            // Like ChatGPT and Codex, AIM opens on a new conversation; earlier ones stay in the sidebar.
            await refreshPermissions()
            engineStatuses = await engineRegistry.statuses()
            await listenToEngine()
            startContinuityObservation()
            let approvals = await toolApprovals.updates()
            approvalTask = Task { [weak self] in
                for await pending in approvals {
                    guard !Task.isCancelled else { return }
                    self?.pendingToolApprovals = pending
                }
            }
            let spendApprovals = await spendExceptions.updates()
            spendExceptionTask = Task { [weak self] in
                for await pending in spendApprovals {
                    guard !Task.isCancelled else { return }
                    self?.pendingSpendExceptions = pending
                }
            }
            let questions = await agentQuestions.updates()
            questionTask = Task { [weak self] in
                for await pending in questions {
                    guard !Task.isCancelled else { return }
                    self?.pendingAgentQuestions = pending
                }
            }
            // An account callback can precede runtime/remote-handler readiness.
            // Local mirror data and observers are now loaded. Reconcile the
            // missed ingress without waiting for provider Keychain inventory.
            remoteRuntimeReady = true
            Task { [weak self] in
                guard let self, self.hasAccess else { return }
                await self.startRemoteHostIfEnabled()
            }
            // Local conversations and permission controls stay usable while the
            // system waits for Keychain consent. Never gate local history on keys.
            await refreshProviderInventory()

        } catch {
            alertMessage = error.localizedDescription
        }
        isBootstrapping = false
    }

    func selectMode(_ mode: AIMMode, restoreRecent: Bool = true) {
        guard self.mode != mode else { return }
        guard flushComposer(), restoreComposer(scope: "new:\(mode.rawValue)") else { return }
        self.mode = mode
        projectPageVisible = false
        selectedProjectID = nil
        workspaceToolsEnabled = false
        let navigation = UUID()
        navigationID = navigation
        isLoadingConversation = false
        selectedConversationID = nil
        agentPlan = nil
        agentMission = nil
        missionAuthorization = nil
        actionReconciliations = []
        searchTargetMessageID = nil
        messages = []
        if selectedProvider != (settings.selectedProvider ?? .openRouter) {
            availableModels = []
            catalogRequestID = UUID()
            isLoadingModels = false
        }
        selectedProvider = settings.selectedProvider ?? .openRouter
        selectedModelID = settings.selectedModelID ?? ""
        workspacePath = settings.workspacePath
        selectedAgentEngineID = settings.selectedAgentEngineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim
        settings.selectedMode = mode
        applyNewConversationDefaults()
        Task {
            await persistSettings()
            guard self.mode == mode, navigationID == navigation else { return }
            if restoreRecent, let first = conversations.first(where: { $0.mode == mode }) {
                await selectConversation(first.id)
            }
        }
    }

    /// Changing the new-chat intent never rewrites an existing conversation.
    func selectNewConversationMode(_ mode: AIMMode) {
        guard selectedConversationID == nil, mode != .code, self.mode != .code else { return }
        selectMode(mode, restoreRecent: false)
    }

    /// The engine is a property of a conversation, not an interchangeable visual preset.
    func selectAgentEngine(_ id: AgentEngineID) {
        guard mode == .agent, selectedConversationID == nil, !isSending, !isShuttingDown else { return }
        selectedAgentEngineID = id
        if [.openClaw, .hermes].contains(id), selectedProvider != .openRouter { selectProvider(.openRouter) }
        settings.selectedAgentEngineID = id.rawValue
        Task { await persistSettings() }
    }

    func refreshEngineStatuses() async { engineStatuses = await engineRegistry.statuses() }
    #if DEBUG
    var startDiagnostics: [String: String] { ["didStart": "\(didStart)", "installer": "\(upstreamInstaller != nil)",
                                              "runtime": "\(continuityRuntime != nil)", "alert": alertMessage ?? ""] }
    #endif

    func updateAgentsInBackground() {
        guard !RuntimePrivacyPolicy.isEnabled else { return }
        for id in agentUpdateAvailable.keys.sorted(by: { $0.rawValue < $1.rawValue }) { downloadAgent(id, select: false) }
    }

    func uninstallAgent(_ id: AgentEngineID) {
        guard !isSending, !isShuttingDown, agentInstallTasks[id] == nil, let installer = upstreamInstaller,
              selectedAgentEngineID != id || selectedConversationID == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.uninstall(id)
                await self.engineRegistry.unregister(id)
                self.agentUpdateAvailable[id] = nil; self.agentInstallErrors[id] = nil
                if self.selectedAgentEngineID == id { self.selectAgentEngine(.aim) }
                self.engineStatuses = await self.engineRegistry.statuses()
            } catch { self.alertMessage = error.localizedDescription }
        }
    }

    func downloadAgent(_ id: AgentEngineID, select: Bool = true) {
        guard !isSending, !isShuttingDown, agentInstallTasks[id] == nil,
              UpstreamAgentInstaller.downloadable.contains(id), let installer = upstreamInstaller else { return }
        do { try RuntimePrivacyPolicy.requireNetwork() }
        catch { agentInstallErrors[id] = error.localizedDescription; alertMessage = error.localizedDescription; return }
        agentInstallErrors[id] = nil
        agentInstallProgress[id] = RuntimeInstallProgress(engine: id, phase: .preparing, percent: 0, message: "Préparation…")
        agentInstallTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.agentInstallTasks[id] = nil; self.agentInstallProgress[id] = nil }
            do {
                for try await progress in await installer.install(id) { self.agentInstallProgress[id] = progress }
                try Task.checkCancellation()
                guard let installation = try await installer.installation(id) else { return }
                await self.registerUpstreamAgent(installation)
                self.agentUpdateAvailable[id] = installation.updateAvailable ? UpstreamAgentCatalog.release(id)?.version : nil
                self.engineStatuses = await self.engineRegistry.statuses()
                await self.listenToEngine()
                if select { self.selectAgentEngine(id) }
            } catch is CancellationError {
                self.agentInstallErrors[id] = "Téléchargement annulé. L’installation précédente est conservée."
            } catch {
                self.agentInstallErrors[id] = error.localizedDescription
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func cancelAgentDownload(_ id: AgentEngineID) { agentInstallTasks[id]?.cancel() }

    private func registerUpstreamAgent(_ installation: UpstreamAgentInstallation) async {
        let engine = NativeAIMEngine(runner: coordinatedAgentRunner, id: installation.engine, version: installation.version)
        await engineRegistry.register(engine)
    }

    func selectConversation(_ id: UUID?) async {
        if let id, (try? await accountChatSync.isVisible(id, identity: account.identity)) != true { return }
        showCustomize = false
        guard flushComposer(), restoreComposer(scope: id.map { "conversation:\($0.uuidString)" } ?? newComposerScope) else { return }
        projectPageVisible = false
        workspaceToolsEnabled = false
        searchTargetMessageID = nil
        let navigation = UUID()
        navigationID = navigation
        selectedConversationID = id
        agentPlan = nil
        agentMission = nil
        missionAuthorization = nil
        actionReconciliations = []
        messages = []
        messageMetrics = [:]
        contextUsage = nil
        compactedThroughSequence = nil
        guard let id else { isLoadingConversation = false; return }
        markRead(id)
        isLoadingConversation = true
        defer { if navigationID == navigation { isLoadingConversation = false } }
        do {
            let conversation = try await conversationRepository.conversation(id: id)
            let loaded = try await conversationRepository.messages(conversationID: id)
            let loadedPlan = try? await planRepository.load(conversationID: id)
            let loadedMission = try? await missionRepository.latest(conversationID: id)
            let loadedAuthorization: MissionAuthorization?
            if let loadedMission {
                loadedAuthorization = try? await missionRepository.authorization(missionID: loadedMission.id)
            } else { loadedAuthorization = nil }
            // A corrupt derived summary must never hide the original transcript.
            let checkpoint: SessionCompaction?
            let summaryError: Bool
            do { checkpoint = try await compactionRepository.load(conversationID: id); summaryError = false }
            catch {
                checkpoint = nil
                summaryError = true
            }
            guard selectedConversationID == id, navigationID == navigation else { return }
            agentPlan = loadedPlan
            agentMission = loadedMission
            missionAuthorization = loadedAuthorization
            if summaryError { alertMessage = "The saved context summary is unreadable. Original messages remain intact, but a new model request may require repair." }
            if let conversation { mode = conversation.mode }
            selectedAgentEngineID = conversation.map { $0.engineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim }
                ?? settings.selectedAgentEngineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim
            selectedProjectID = conversation?.projectID
            if let conversation, let provider = conversation.provider {
                if selectedProvider != provider { availableModels = []; catalogRequestID = UUID(); isLoadingModels = false }
                selectedProvider = provider
                selectedModelID = conversation.modelID ?? ""
                workspacePath = conversation.workspacePath
            } else {
                // Legacy transcripts keep their history; new requests use the user's last choice.
                selectedProvider = settings.selectedProvider ?? .openRouter
                selectedModelID = settings.selectedModelID ?? ""
                workspacePath = nil
            }
            // Answers are formatted before they are shown (no raw Markdown flash).
            let answers = loaded.suffix(60).filter { $0.role == .assistant }.map(\.content)
            await Task.detached(priority: .userInitiated) { for answer in answers { MarkdownBlockCache.shared.parse(answer) } }.value
            guard selectedConversationID == id, navigationID == navigation else { return }
            messages = loaded
            messageMetrics = (try? await metricsRepository.metrics(conversationID: id)) ?? [:]
            contextUsage = (try? await metricsRepository.contextUsage(conversationID: id)) ?? estimatedContextUsage(loaded, checkpoint: checkpoint)
            compactedThroughSequence = checkpoint?.throughSequence
            updateVisibleDraft()
        }
        catch { if navigationID == navigation { alertMessage = error.localizedDescription } }
    }

    func loadProjects() async {
        do { projects = try await visibleProjects() }
        catch { alertMessage = "Projects could not be loaded." }
    }

    func documents(for projectID: UUID) async throws -> [ProjectDocument] {
        try await projectDocuments.list(projectID: projectID)
    }
    func importProjectDocument(_ url: URL, projectID: UUID) async throws {
        guard !isSending, !isShuttingDown, !isImportingProjectDocument else { throw ProjectDocumentError.busy }
        isImportingProjectDocument = true
        defer { isImportingProjectDocument = false }
        let snapshot = try await Task.detached { try DocumentTextImporter.read(url) }.value
        guard !isShuttingDown else { throw ProjectDocumentError.busy }
        try await projectDocuments.add(ProjectDocument(projectID: projectID, name: snapshot.name, content: snapshot.content))
    }
    func removeProjectDocument(_ id: String, projectID: UUID) async throws {
        guard !isSending, !isShuttingDown else { throw ProjectDocumentError.busy }
        try await projectDocuments.remove(id: id, projectID: projectID)
    }

    func sources(for projectID: UUID) async throws -> [ProjectSource] {
        try await projectRepository.sources(projectID: projectID)
    }

    private func linkedFolderWriteAccess(for path: String, projectID: UUID) async throws -> Bool? {
        try await projectRepository.sources(projectID: projectID)
            .filter { path == $0.canonicalPath || path.hasPrefix($0.canonicalPath + "/") }
            .max { $0.canonicalPath.count < $1.canonicalPath.count }?.writeAccessGranted
    }

    func setProjectSourceWriteAccess(_ source: ProjectSource, granted: Bool) async throws {
        guard !isSending, !isShuttingDown else { throw ProjectDocumentError.busy }
        var updated = source
        updated.writeAccessGranted = granted
        try await projectRepository.save(source: updated)
        projectSourceRevision += 1
        if !granted && selectedProjectID == source.projectID && workspacePath == source.canonicalPath {
            workspaceToolsEnabled = false
            workspacePath = nil
        }
    }

    func indexProjectFolder(_ url: URL, projectID: UUID) async throws -> ProjectSourceScan {
        guard !isSending, !isShuttingDown, !isIndexingProjectSource else { throw ProjectDocumentError.busy }
        isIndexingProjectSource = true
        defer { isIndexingProjectSource = false }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let existing = try await projectRepository.sources(projectID: projectID).first { $0.canonicalPath == canonical.path }
        let source = existing ?? ProjectSource(projectID: projectID, canonicalPath: canonical.path, displayName: canonical.lastPathComponent)
        let scanStartedAt = Date.now
        let scanTask = Task.detached(priority: .utility) { try ProjectSourceScanner.scan(url) }
        let scan = try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        guard !isShuttingDown else { throw ProjectDocumentError.busy }
        if existing == nil { try await projectRepository.save(source: source) }
        do { try await projectSourceIndex.replace(source: source, chunks: scan.chunks, scanStartedAt: scanStartedAt) }
        catch {
            if existing == nil { try? await projectRepository.deleteSource(id: source.id) }
            throw error
        }
        projectSourceRevision += 1
        return scan
    }

    func removeProjectSource(_ source: ProjectSource) async throws {
        guard !isSending, !isShuttingDown, !isIndexingProjectSource else { throw ProjectDocumentError.busy }
        try await projectRepository.deleteSource(id: source.id)
        projectSourceRevision += 1
    }

    func saveProject(id: UUID?, name: String, instructions: String, usesGlobalMemory: Bool? = nil) async -> Bool {
        guard !isSending, !isShuttingDown else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, instructions.count <= 16_000 else {
            alertMessage = "Use a project name of 1–120 characters and instructions of at most 16,000 characters."
            return false
        }
        guard id == nil || projects.contains(where: { $0.id == id }) else { return false }
        var project = id.flatMap { value in projects.first { $0.id == value } } ?? AIMApplication.AIMProject(name: name)
        project.name = name; project.instructions = instructions; project.updatedAt = .now
        if let usesGlobalMemory { project.usesGlobalMemory = usesGlobalMemory }
        do {
            if id == nil, let identity = account.identity { try await accountChatSync.markOwned(project.id, identity: identity) }
            try await projectRepository.save(project)
            projects = try await visibleProjects()
            return true
        } catch { alertMessage = "The project could not be saved."; return false }
    }

    func deleteProject(_ id: UUID) async -> Bool {
        guard !isSending, !isShuttingDown, !isIndexingProjectSource else { return false }
        do {
            try await projectRepository.delete(id: id)
            projects = try await visibleProjects()
            if selectedProjectID == id { selectedProjectID = nil }
            try await reloadConversations()
            return true
        } catch { alertMessage = "The project could not be deleted."; return false }
    }

    @discardableResult
    func selectProject(_ id: UUID?) async -> Bool {
        guard !isSending, !isShuttingDown else { return false }
        guard id == nil || projects.contains(where: { $0.id == id }) else { return false }
        let scope = "new:\(mode.rawValue)" + (id.map { ":project:\($0.uuidString)" } ?? "")
        guard flushComposer(), restoreComposer(scope: scope) else { return false }
        selectedProjectID = id
        await newConversation()
        return selectedConversationID == nil && composerScope == scope
    }

    func moveConversation(_ id: UUID, toProject projectID: UUID?) async {
        guard !isSending, !isShuttingDown else { return }
        do {
            guard var conversation = try await conversationRepository.conversation(id: id) else { return }
            conversation.projectID = projectID; conversation.updatedAt = .now
            try await conversationRepository.save(conversation)
            if selectedConversationID == id { selectedProjectID = projectID }
            try await reloadConversations()
        } catch { alertMessage = "The conversation could not be moved." }
    }

    func newConversation() async {
        guard flushComposer(), restoreComposer(scope: newComposerScope) else { return }
        projectPageVisible = false
        workspaceToolsEnabled = false
        navigationID = UUID()
        isLoadingConversation = false
        selectedConversationID = nil
        agentPlan = nil
        agentMission = nil
        missionAuthorization = nil
        messages = []
        if selectedProvider != (settings.selectedProvider ?? .openRouter) { availableModels = [] }
        selectedProvider = settings.selectedProvider ?? .openRouter
        selectedModelID = settings.selectedModelID ?? ""
        workspacePath = settings.workspacePath
        selectedAgentEngineID = settings.selectedAgentEngineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim
        applyNewConversationDefaults()
    }

    /// Settings › General and Configuration for a new conversation: permissions, folder,
    /// and the mode's default model when its provider is connected.
    func applyNewConversationDefaults() {
        let defaults = preferences.modeDefaults[mode.rawValue]
        if mode != .chat {
            approvalPolicy = ApprovalPolicy(rawValue: defaults?.approvalPolicy ?? preferences.defaultApprovalPolicy) ?? .alwaysAsk
            workspacePlanOnly = approvalPolicy == .plan
            if workspacePath == nil, let folder = preferences.defaultTaskFolder,
               FileManager.default.fileExists(atPath: folder) { workspacePath = folder }
        }
        if let provider = defaults?.provider.flatMap(ChatProvider.init(rawValue:)), let id = defaults?.modelID, !id.isEmpty,
           connectedProviders.contains(provider) {
            if selectedProvider != provider { availableModels = [] }
            selectedProvider = provider
            selectedModelID = id
        }
    }

    /// The sidebar's New chat and Command-N always start outside a project.
    func newGeneralConversation() async {
        showCustomize = false
        guard flushComposer() else { return }
        selectedProjectID = nil
        await newConversation()
    }

    /// Bind a Remote root before launching its work, so a simultaneous revocation
    /// can stop it by the already-admitted command UUID even before result delivery.
    func requireRemoteAgent(_ id: AgentEngineID, provider: ChatProvider?) async throws {
        guard id == .aim || [.hermes, .openClaw].contains(id) else { throw RemoteHostCommandFailure("agent_inconnu") }
        if id != .aim {
            guard provider == .openRouter, let installer = upstreamInstaller,
                  let installation = try await installer.installation(id) else { throw RemoteHostCommandFailure("agent_not_installed_or_provider_incompatible") }
            await registerUpstreamAgent(installation)
        }
        guard await engineRegistry.engine(id) != nil else { throw RemoteHostCommandFailure("agent_indisponible") }
    }

    func prepareRemoteConversation(id: UUID, mode: AIMMode, engineID: AgentEngineID = .aim) async throws {
        guard try await conversationRepository.conversation(id: id) == nil else {
            throw RemoteHostCommandFailure("remote_creation_already_exists")
        }
        await newGeneralConversation()
        var conversation = Conversation(id: id, title: "Remote conversation", mode: mode, engineID: mode == .agent ? engineID.rawValue : nil)
        conversation.provider = selectedProvider; conversation.modelID = selectedModelID
        if let identity = account.identity { try await accountChatSync.markOwned(id, identity: identity) }; if let accountID = account.accessUser?.id { try await accountActivityRepository.ownConversation(id, accountID: accountID) }
        try await conversationRepository.save(conversation)
        try await reloadConversations(select: id)
    }

    func importAttachment(_ url: URL) async {
        await importAttachments([url])
    }

    @discardableResult
    func attachWorkspacePreview(_ content: String, named path: String, from workspace: String) -> Bool {
        guard mode != .chat, workspacePath == workspace, canImportAttachments else {
            alertMessage = "Select a current Code or Agent workspace file before attaching it."
            return false
        }
        do {
            let snapshot = TextAttachment(name: path, content: content)
            try TextAttachment.validate(pendingAttachments + [snapshot])
            pendingAttachments.append(snapshot)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    var attachmentImportContext: UUID { navigationID }

    var canImportAttachments: Bool {
        !isImportingAttachment && !isBranchingConversation && !isSending && !isGeneratingImage && !isShuttingDown && !isLoadingConversation && pendingAttachments.count + pendingImages.count < TextAttachment.maximumFiles
    }

    struct PendingVideoImport: Identifiable {
        let id = UUID()
        let urls: [URL]
        let context: UUID
    }
    var pendingVideoImport: PendingVideoImport?
    func importAttachments(_ urls: [URL], context: UUID? = nil, videoOptions: VideoPreparationOptions? = nil) async {
        guard canImportAttachments, context == nil || context == navigationID else { return }
        let navigation = navigationID
        if videoOptions == nil, urls.contains(where: { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }) {
            pendingVideoImport = .init(urls: urls, context: navigation); return
        }
        let options = videoOptions ?? .init()
        isImportingAttachment = true; attachmentImportErrors = []
        defer { isImportingAttachment = false; importingAttachmentName = nil; cancelAttachmentPreparation = nil }
        do {
            guard !urls.isEmpty, urls.count + pendingAttachments.count + pendingImages.count <= TextAttachment.maximumFiles else { throw AttachmentError.limit }
            guard urls.allSatisfy(\.isFileURL), Set(urls.map { $0.standardizedFileURL }).count == urls.count else {
                throw AttachmentError.invalidSelection
            }
            let mediaRoot = paths?.applicationSupport ?? FileManager.default.temporaryDirectory.appendingPathComponent("aim-inputs")
            let mediaOwner = account.accessUser?.id
            let mediaDeviceName = Host.current().localizedName ?? "Mac"
            let mediaDeviceID = (try? RemoteHostIdentityStore(accountID: mediaOwner).load()?.machineID) ?? "unknown"
            let priorText = pendingAttachments, priorImages = pendingImages
            let job = Task.detached { [weak self] in
                var text: [TextAttachment] = [], images: [ImageAttachment] = [], errors: [String] = []
                for url in urls {
                    try Task.checkCancellation()
                    await MainActor.run { if self?.navigationID == navigation { self?.importingAttachmentName = url.lastPathComponent } }
                    do {
                        var fileText: [TextAttachment] = [], fileImages: [ImageAttachment] = []
                        if ["png", "jpg", "jpeg", "heic", "heif"].contains(url.pathExtension.lowercased()) {
                            let image = try ImageAttachment.read(url)
                            _ = try PrivateInputMedia.retain(url, root: mediaRoot, accountID: mediaOwner, attachmentID: image.id)
                            fileImages.append(image)
                        } else if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                            let video = try await VideoAttachmentImporter.read(url, mode: options.mode, range: try options.range(), originDeviceID: mediaDeviceID, originDeviceName: mediaDeviceName)
                            _ = try PrivateInputMedia.retain(url, root: mediaRoot, accountID: mediaOwner, attachmentID: video.0.id)
                            fileText.append(video.0); fileImages.append(contentsOf: video.1)
                        } else if ["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf", "flac"].contains(url.pathExtension.lowercased()) {
                            fileText.append(try await MediaTranscriptImporter.read(url))
                        } else { fileText.append(try DocumentTextImporter.read(url)) }
                        try Task.checkCancellation()
                        try TextAttachment.validate(priorText + text + fileText)
                        try ImageAttachment.validate(priorImages + images + fileImages)
                        text += fileText; images += fileImages
                    } catch is CancellationError { throw CancellationError() }
                    catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
                }
                return (text, images, errors)
            }
            cancelAttachmentPreparation = { job.cancel() }
            let imported = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard navigationID == navigation, account.accessUser?.id == mediaOwner, !isShuttingDown else { return }
            pendingAttachments.append(contentsOf: imported.0)
            pendingImages.append(contentsOf: imported.1)
            attachmentImportErrors = imported.2
            _ = flushComposer()

        } catch is CancellationError { return }
        catch { if navigationID == navigation { alertMessage = error.localizedDescription } }
    }

    var canSteerActiveMission: Bool {
        isSending && mode == .agent && activeTurnEngineID == .aim &&
            activeTurnConversationID != nil && activeTurnConversationID == selectedConversationID &&
            toolRunProvider != nil && toolRunConversationID == activeTurnConversationID &&
            toolProgress.stage == .waitingForModel &&
            !isShuttingDown
    }

    /// Rechecks the captured owner/mode after every suspended setup operation,
    /// including external engines that do not enter the durable AIM coordinator.
    func authorizesComposerDispatch(owner: UUID?, expectedMode: AIMMode) async -> Bool {
        guard let owner, account.identity?.storageID == owner, composerStorageID == owner else { return false }
        return mode == expectedMode && !isShuttingDown
    }

    /// `alternate` (⌘↩ while a task runs) does the opposite of the Follow-up setting once.
    func sendComposer(alternate: Bool = false) async {
        guard !isAnalysingVisualInput else { return }
        let admissionOwner = account.identity?.storageID, admissionMode = mode
        // Automatic dictation follows the language the person writes in (detected on this Mac).
        DictationLanguage.learn(from: composerText)
        if isSending {
            let steer = (preferences.followUp == .steer) != alternate
            if steer && canSteerActiveMission { await sendMissionCorrection() } else { queueComposer() }
            return
        }
        guard responseSaveError == nil, assistantSaveTask == nil else {
            alertMessage = "Save the pending response before sending another message."
            return
        }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty else { return }
        guard !isImportingProjectDocument, !isBranchingConversation, !isImportingAttachment,
              !isSending, !isGeneratingImage, !isLoadingConversation, !isShuttingDown else { return }
        guard await ensureBuiltInModelLoaded() else { return }
        if mode == .code && workspacePath == nil {
            alertMessage = "Choose a working folder before sending in Code. Your draft was kept."
            return
        }
        if (mode == .code || workspacePath != nil), mode != .chat {
            guard let workspacePath else {
                alertMessage = "Choose a workspace folder before using workspace tools. Your draft was kept."
                return
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue,
                  URL(fileURLWithPath: workspacePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path == workspacePath else {
                workspaceToolsEnabled = false
                alertMessage = "The selected workspace is missing or has moved. Choose its current folder before using workspace tools. Your draft was kept."
                return
            }
            if let selectedProjectID {
                do {
                    if try await linkedFolderWriteAccess(for: workspacePath, projectID: selectedProjectID) == false {
                        alertMessage = "This project folder is linked read-only. Grant Code access in Manage sources before sending. Your draft was kept."
                        return
                    }
                } catch {
                    alertMessage = "Project folder permissions could not be checked. Your draft was kept."
                    return
                }
            }
        }
        let requestAttachments = pendingAttachments
        let requestImages = pendingImages
        let submittedDraft = ComposerDraft(text: composerText, attachments: requestAttachments, images: requestImages.isEmpty ? nil : requestImages, visualReport: visualDraftReport)
        guard flushComposer() else { return }
        guard hasProviderKey else { showProviderSetup = true; return }
        guard !selectedModelID.isEmpty else { showModelPicker = true; return }
        let requestEngineID: AgentEngineID = mode == .agent ? selectedAgentEngineID : .aim
        let registeredEngine = await engineRegistry.engine(requestEngineID)
        guard let requestEngine: any AgentEngine = registeredEngine ?? (requestEngineID == .aim ? aimEngine : nil) else {
            alertMessage = "Install the selected agent before sending. Your draft was kept."
            return
        }
        if (await requestEngine.status()).state != .ready {
            do { try await requestEngine.start() }
            catch {
                alertMessage = "The selected agent could not start: \(error.localizedDescription). Your draft was kept."
                return
            }
            guard (await requestEngine.status()).state == .ready else {
                alertMessage = "The selected agent is not ready. Your draft was kept."
                return
            }
        }
        pendingSends += 1
        defer {
            pendingSends -= 1
            if pendingSends == 0 {
                let waiters = sendWaiters
                sendWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let requestIdentity = account.identity
        let requestAccount = requestIdentity?.authenticatedUser?.id
        do {
            guard accountPreferenceScopeReady else { throw AccountServiceError.unavailable }
            try prepareAccountPreferenceScope()
        } catch { alertMessage = "Account preferences could not be loaded safely. Your message is kept."; return }
        let requestStartedAt = Date.now
        let requestMode = mode
        guard await authorizesComposerDispatch(owner: admissionOwner, expectedMode: admissionMode) else { return }
        guard requestIdentity?.storageID == admissionOwner, requestMode == admissionMode else { return }
        let requestModel = selectedModelID
        // The picker's catalog may not be loaded yet (just started, provider just changed): the
        // saved catalog tells whether the model sees images, so screenshots and pixel tools are kept.
        var requestModelSupportsImages = availableModels.first(where: { $0.id == requestModel })?.supportsImageInput
        if requestModelSupportsImages == nil {
            requestModelSupportsImages = await ModelCatalogCache.shared.cached(selectedProvider)?
                .first(where: { $0.id == requestModel })?.supportsImageInput
        }
        let requestProvider = selectedProvider
        var portablePreferences = accountChatPreferences
        portablePreferences.customInstructions = settings.personalization?.isEnabled == true ? settings.personalization?.instructions : nil
        let requestPersonalization = Personalization(isEnabled: !portablePreferences.instructions.isEmpty, instructions: portablePreferences.instructions)
        let requestMemoryEnabled = settings.memoryEnabled != false
        let requestAutomaticWebSearch = portablePreferences.automaticWebSearch
        let requestResearchMode = portablePreferences.researchMode
        let requestOutputTokens = requestProvider == .anthropic ? settings.anthropicOutputTokensByModel?[requestModel] : nil
        let requestReasoningEffort = reasoningEffort(provider: requestProvider, modelID: requestModel)
        let requestWorkspace = workspacePath
        let requestTools = requestMode != .chat && requestProvider.supportsWorkspaceTools
            && (requestMode == .agent || requestWorkspace != nil)
        let requestTextToolProtocol = requestTools && requestProvider == .openRouter && workspaceTextToolProtocol
        let requestPlanOnly = requestTools && (workspacePlanOnly || approvalPolicy == .plan)
        let requestEdits = requestTools && !requestPlanOnly
        let requestCommands = requestTools && !requestPlanOnly
        let requestVisualReport = visualDraftReport
        var prior: [ConversationMessage] = []
        if let selectedConversationID { prior = (try? await conversationRepository.messages(conversationID: selectedConversationID)) ?? [] }
        let covered = Set(prior.compactMap(\.visualReport).flatMap(\.sourceIDs) + (requestVisualReport?.sourceIDs ?? []))
        let sourceDocuments = prior.flatMap { $0.attachments ?? [] } + requestAttachments
        let sourceImages = prior.flatMap { $0.images ?? [] } + requestImages
        let visualSources: [NativeChatAttachment] = sourceDocuments.filter { $0.video != nil && !covered.contains($0.id) }.map { .init(id: $0.id, name: $0.name, kind: .document, mimeType: "text/plain", text: $0.content, video: $0.video) }
            + sourceImages.filter { !covered.contains($0.id) }.map { .init(id: $0.id, name: $0.name, kind: .image, mimeType: $0.mimeType, data: $0.data) }
        let needsBatch = visualSources.contains { ($0.video?.frames.count ?? 0) > 4 }
        if !visualSources.isEmpty && (requestModelSupportsImages != true || needsBatch) {
            guard let owner = requestIdentity?.storageID else { return }
            let sourceMachineID = visualExecutionDeviceID
            let pending = PendingMacVisualApproval(scope: composerScope, navigation: navigationID, draftRevision: composerRevision, ownerID: owner,
                primaryProvider: requestProvider, primaryModel: requestModel, sources: visualSources,
                conversationID: selectedConversationID ?? UUID(), target: "mac:" + sourceMachineID, credentialScope: account.credentialScope.snapshot())
            let defaults = accountChatPreferences.subagentDefaults?[pending.target] ?? SubagentPreferenceStore.load(accountID: owner, target: pending.target)
            if requestModelSupportsImages == true {
                _ = await analyseVisualInput(pending, choice: .init(provider: requestProvider, modelID: requestModel), remember: false)
            } else if let choice = defaults.visual, defaults.permanentVisualConsents.contains(choice) {
                _ = await analyseVisualInput(pending, choice: choice, remember: false)
            } else { pendingVisualApproval = pending; _ = flushComposer() }
            return
        }
        activeToolName = nil
        completedToolCount = 0
        toolProgress = ToolProgressWindow()
        toolRunProvider = requestTools ? requestProvider : nil
        toolRunModelID = requestModel
        let existing = conversations.first { $0.id == selectedConversationID && $0.mode == mode }
        let title = text.isEmpty
            ? String((requestAttachments.first?.name ?? requestImages.first?.name ?? "Attachment").prefix(80))
            : String(text.prefix(80))
        var conversation = existing ?? Conversation(title: title, mode: mode, projectID: selectedProjectID)
        if existing == nil { awaitingTitle.insert(conversation.id) }
        draftMetrics = nil
        markRead(conversation.id)
        if mode == .agent { conversation.engineID = existing?.engineID ?? requestEngineID.rawValue }
        conversation.provider = requestProvider
        conversation.modelID = requestModel
        conversation.workspacePath = requestWorkspace
        let conversationID = conversation.id
        toolRunConversationID = conversationID
        selectedConversationID = conversationID
        let sourceComposerScope = composerScope
        let sourceComposerKey = scopedComposerKey(composerScope)
        restoringComposer = true
        composerText = ""
        pendingAttachments = []
        pendingImages = []
        visualDraftReport = nil
        restoringComposer = false
        composerScope = "conversation:\(conversationID.uuidString)"
        isSending = true
        activeTurnConversationID = conversationID
        activeTurnEngineID = requestEngineID
        var userMessageWasSaved = false
        do {
            guard account.identity == requestIdentity, let requestIdentity else { throw URLError(.userAuthenticationRequired) }
            if existing == nil { try await accountChatSync.markOwned(conversation.id, identity: requestIdentity) }
            try await conversationRepository.save(conversation)
            let history = try await conversationRepository.messages(conversationID: conversationID)
            guard activeTurnConversationID == conversationID else { return }
            let sequence = (history.last?.sequence ?? -1) + 1
            let userMessage = ConversationMessage(conversationID: conversationID, role: .user, content: text, sequence: sequence, attachments: requestAttachments.isEmpty ? nil : requestAttachments, images: requestImages.isEmpty ? nil : requestImages, visualReport: requestVisualReport)
            // Old attachments are retained locally. Request-context selection
            // and its byte budget happen in the runner after compaction.
            try TextAttachment.validate(requestAttachments)
            try ImageAttachment.validate(requestImages)
            try await conversationRepository.append(userMessage)
            if let owner = requestAccount, let machineID = try? RemoteHostIdentityStore(accountID: owner).load()?.machineID {
                try await accountChatSync.recordExecution(conversationID: conversationID, deviceID: machineID, accountID: owner)
                conversationExecutionDevices[conversationID] = Array(Set((conversationExecutionDevices[conversationID] ?? []) + [machineID])).sorted()
            }
            if let requestAccount {
                try await accountActivityRepository.ownConversation(conversationID, accountID: requestAccount, since: requestStartedAt)
                if requestMode == .chat || requestEngineID != .aim || continuityRuntime == nil {
                    let task = AccountActivityRecord(id: UUID(), accountID: requestAccount, deviceID: accountActivityRepository.deviceID,
                        deviceName: Host.current().localizedName ?? "Mac", conversationID: conversationID, kind: .task,
                        provider: requestProvider.rawValue, modelID: requestModel, mode: requestMode.rawValue, startedAt: requestStartedAt)
                    try await accountActivityRepository.record(task); activeAccountTask = task
                }
            }
            userMessageWasSaved = true
            projectPageVisible = false
            if existing == nil { conversations.insert(conversation, at: 0) }
            else if let index = conversations.firstIndex(where: { $0.id == conversationID }) { conversations[index] = conversation }
            try composerDraftStore.removeIfUnchanged(submittedDraft, key: sourceComposerKey)
            guard activeTurnConversationID == conversationID, !isShuttingDown else { return }
            if selectedConversationID == conversationID { messages = history + [userMessage] }
            draftAssistantMessage = ConversationMessage(
                conversationID: conversationID,
                role: .assistant,
                content: "",
                sequence: sequence + 1
            )
            startDraftTimeline()
            lastTranscriptUpdate = .distantPast
            var request = AgentRequest(
                conversationID: conversationID,
                text: text,
                modelID: requestModel,
                mode: requestMode,
                workspacePath: requestWorkspace,
                provider: requestProvider,
                workspaceToolsEnabled: requestTools, workspaceTextToolProtocol: requestTextToolProtocol,
                workspaceEditsEnabled: requestEdits, workspaceCommandsEnabled: requestCommands,
                workspacePlanOnly: requestPlanOnly,
                approvalPolicy: requestPlanOnly ? .plan : approvalPolicy,
                personalization: requestPersonalization, anthropicOutputTokens: requestOutputTokens, openAIReasoningEffort: requestReasoningEffort,
                memoryEnabled: requestMemoryEnabled,
                activitySettings: requestMode == .agent && requestEngineID == .aim ? settings.activity : nil,
                modelSupportsImages: requestModelSupportsImages,
                contextLength: currentContextLimit
            )
            if requestMode != .chat, let profile = try CustomAgentLibrary().selected() {
                try profile.apply(to: &request)
            }
            let preferenceTarget = "mac:" + visualExecutionDeviceID
            request.generalSubagentChoice = SubagentPreferenceStore.load(accountID: requestIdentity.storageID, target: preferenceTarget).general
            request.sourceMessageID = userMessage.id
            // Each turn decides who saves its answer: the durable runtime, or this app.
            if continuityRuntime != nil, requestMode != .chat, requestEngineID == .aim {
                runtimeManagedConversations.insert(conversationID)
            } else {
                runtimeManagedConversations.remove(conversationID)
            }
            request.automaticWebSearch = requestAutomaticWebSearch
            request.researchMode = requestResearchMode
            guard await authorizesComposerDispatch(owner: requestIdentity.storageID, expectedMode: requestMode) else { throw URLError(.userAuthenticationRequired) }
            try await ProfileScopedCredentialStore.$requiredOwnerID.withValue(requestIdentity.storageID) {
                try await requestEngine.send(request)
            }
        } catch {
            guard activeTurnConversationID == conversationID else { return }
            if !userMessageWasSaved, selectedConversationID == conversationID, composerText.isEmpty {
                if existing == nil {
                    selectedConversationID = nil
                    composerScope = sourceComposerScope
                }
                composerText = text
                pendingAttachments = requestAttachments
                pendingImages = requestImages
                visualDraftReport = submittedDraft.visualReport
                _ = flushComposer()
            }
            if userMessageWasSaved {
                draftAssistantMessage?.completionStatus = .failed
                await persistDraft(conversationID: conversationID)
            }
            isSending = false
            activeTurnConversationID = nil
            activeTurnEngineID = nil
            if !userMessageWasSaved { draftAssistantMessage = nil }
            toolProgress.interruptRunning()
            alertMessage = error.localizedDescription
        }
    }

    private func sendMissionCorrection() async {
        guard canSteerActiveMission, let conversationID = activeTurnConversationID else { return }
        guard correctionSaveTask == nil else { return }
        guard pendingAttachments.isEmpty, pendingImages.isEmpty else {
            alertMessage = "Send the correction as text while this mission runs. Attachments stay in your draft."
            return
        }
        let submitted = composerText
        let content = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard flushComposer() else { return }
        let task = Task { try await missionRepository.enqueueCorrection(conversationID: conversationID, message: content) }
        correctionSaveTask = task
        do {
            let saved = try await task.value
            applySavedCorrection(saved)
            if composerText == submitted {
                restoringComposer = true
                composerText = ""
                restoringComposer = false
                _ = flushComposer()
            }
        } catch {
            alertMessage = "The correction was not queued: \(error.localizedDescription)"
        }
        correctionSaveTask = nil
    }

    private func applySavedCorrection(_ saved: ConversationMessage) {
        if var draft = draftAssistantMessage, draft.conversationID == saved.conversationID {
            draft.sequence = max(draft.sequence, saved.sequence + 1)
            draftAssistantMessage = draft
        }
        guard selectedConversationID == saved.conversationID else { return }
        if !messages.contains(where: { $0.id == saved.id }) { messages.append(saved) }
        updateVisibleDraft()
        messages.sort { $0.sequence < $1.sequence }
    }

    private func settlePendingCorrection() async {
        if let correctionSaveTask, let saved = try? await correctionSaveTask.value {
            applySavedCorrection(saved)
        }
    }

    func stopRemoteConversations(_ ids: Set<UUID>) async {
        if let activeTurnConversationID, ids.contains(activeTurnConversationID) { await cancelCurrentTurn() }
        for id in ids {
            let engineID = conversations.first(where: { $0.id == id })?.engineID.flatMap(AgentEngineID.init(rawValue:)) ?? .aim
            if let engine = await engineRegistry.engine(engineID) ?? (engineID == .aim ? aimEngine : nil) { await engine.cancel(conversationID: id) }
        }
    }

    func cancelCurrentTurn() async {
        if !isSending, selectedContinuityExecution?.state.isRecoverable == true {
            await controlContinuityExecution(.cancel)
            return
        }
        guard let id = activeTurnConversationID else { return }
        if draftAssistantMessage?.conversationID == id { draftAssistantMessage?.completionStatus = .cancelled }
        if let engineID = activeTurnEngineID,
           let engine = await engineRegistry.engine(engineID) ?? (engineID == .aim ? aimEngine : nil) {
            await engine.cancel(conversationID: id)
        }
        await settlePendingCorrection()
        await persistDraft(conversationID: id)
        if selectedConversationID == id { agentMission = try? await missionRepository.latest(conversationID: id) }
        activeTurnConversationID = nil
        activeTurnEngineID = nil
        isSending = false
        activeToolName = nil
        toolProgress.interruptRunning()
    }

    func decideToolApproval(_ approval: PendingToolApproval, allow: Bool) async {
        await decideToolApproval(approval, decision: allow ? .allowOnce : .deny)
    }

    func decideToolApproval(_ approval: PendingToolApproval, decision: ApprovalDecision) async {
        let engineID = conversations.first(where: { $0.id == approval.sessionID })?.engineID
            .flatMap(AgentEngineID.init(rawValue:)) ?? .aim
        if let engine = await engineRegistry.engine(engineID) ?? (engineID == .aim ? aimEngine : nil) {
            await engine.decide(approvalID: "\(approval.sessionID.uuidString)/\(approval.id.uuidString)", decision: decision)
        }
    }

    func addMissionAuthorizationRule(kind: MissionResource.Kind, identifier: String,
                                     operations: Set<MissionOperation>) async -> Bool {
        guard !isSavingMissionAuthorization, let mission = agentMission,
              mission.conversationID == selectedConversationID else { return false }
        isSavingMissionAuthorization = true
        defer { isSavingMissionAuthorization = false }
        do {
            let resource = try MissionResource(kind: kind, identifier: identifier)
            let rule = try MissionAuthorizationRule(resource: resource, operations: operations)
            var rules = missionAuthorization?.rules.filter { $0.resource != resource } ?? []
            rules.append(rule)
            let saved = try await missionRepository.replaceAuthorization(missionID: mission.id,
                expectedRevision: missionAuthorization?.revision, rules: rules)
            if agentMission?.id == mission.id { missionAuthorization = saved }
            return true
        } catch {
            if agentMission?.id == mission.id {
                missionAuthorization = try? await missionRepository.authorization(missionID: mission.id)
                alertMessage = "Mission scope was not saved: \(error.localizedDescription)"
            }
            return false
        }
    }

    func removeMissionAuthorizationRule(_ resource: MissionResource) async -> Bool {
        guard !isSavingMissionAuthorization, let mission = agentMission,
              mission.conversationID == selectedConversationID,
              let authorization = missionAuthorization else { return false }
        isSavingMissionAuthorization = true
        defer { isSavingMissionAuthorization = false }
        do {
            let saved = try await missionRepository.replaceAuthorization(missionID: mission.id,
                expectedRevision: authorization.revision,
                rules: authorization.rules.filter { $0.resource != resource })
            if agentMission?.id == mission.id { missionAuthorization = saved }
            return true
        } catch {
            if agentMission?.id == mission.id {
                missionAuthorization = try? await missionRepository.authorization(missionID: mission.id)
                alertMessage = "Mission scope was not updated: \(error.localizedDescription)"
            }
            return false
        }
    }

    func revokeMissionAuthorization() async -> Bool {
        guard !isSavingMissionAuthorization, let mission = agentMission,
              mission.conversationID == selectedConversationID,
              let authorization = missionAuthorization, authorization.revokedAt == nil else { return false }
        isSavingMissionAuthorization = true
        defer { isSavingMissionAuthorization = false }
        do {
            let revoked = try await missionRepository.revokeAuthorization(missionID: mission.id,
                expectedRevision: authorization.revision)
            if agentMission?.id == mission.id { missionAuthorization = revoked }
            return true
        } catch {
            if agentMission?.id == mission.id {
                missionAuthorization = try? await missionRepository.authorization(missionID: mission.id)
                alertMessage = "Mission scope was not revoked: \(error.localizedDescription)"
            }
            return false
        }
    }

    @discardableResult func answerAgentQuestion(_ question: AgentQuestion, answer: String) async -> Bool {
        if let continuityRuntime, let execution = continuityExecutions.first(where: { $0.conversationID == question.conversationID && !$0.state.isTerminal }) {
            do {
                _ = try await continuityRuntime.send(AgentHostCommand(action: .answer, executionID: execution.id, text: answer, interactionID: question.id))
                return true
            } catch { alertMessage = error.localizedDescription; return false }
        }
        guard question.conversationID == activeTurnConversationID else { return false }
        return await agentQuestions.answer(question.id, text: answer)
    }

    func loadWorkspaceHistory() async {
        let loadID = UUID()
        workspaceHistoryLoadID = loadID
        guard let id = selectedConversationID else {
            workspaceHistory = []; actionReconciliations = []; workspaceHistoryError = nil; return
        }
        do {
            var history = try await workspaceRunRepository.history(conversationID: id, limit: 10)
            let mission: AgentMission?
            if agentMission?.conversationID == id { mission = agentMission }
            else { mission = try await missionRepository.latest(conversationID: id) }
            let reconciliations: [ActionReconciliation]
            if let mission { reconciliations = try await missionRepository.reconciliations(missionID: mission.id) }
            else { reconciliations = [] }
            var priorityRunIDs: [String] = []
            if let activeRunID = mission?.activeRunID { priorityRunIDs.append(activeRunID) }
            for record in reconciliations.sorted(by: { $0.reviewedAt > $1.reviewedAt })
                where !priorityRunIDs.contains(record.runID) {
                priorityRunIDs.append(record.runID)
            }
            for runID in priorityRunIDs.prefix(10) where !history.contains(where: { $0.run.id == runID }) {
                if let reviewedRun = try await workspaceRunRepository.run(id: runID),
                   reviewedRun.run.conversationID == id.uuidString {
                    history.append(reviewedRun)
                }
            }
            guard selectedConversationID == id, workspaceHistoryLoadID == loadID else { return }
            workspaceHistory = history
            actionReconciliations = reconciliations
            workspaceHistoryError = nil
        } catch {
            guard selectedConversationID == id, workspaceHistoryLoadID == loadID else { return }
            workspaceHistory = []
            actionReconciliations = []
            workspaceHistoryError = "Workspace action history could not be loaded."
        }
    }

    func missionFileEvidence(criterionID: UUID) async -> MissionFileEvidence? {
        guard let mission = agentMission,
              mission.conversationID == selectedConversationID,
              mission.criteria.contains(where: { $0.id == criterionID }) else { return nil }
        let evidence = try? await missionRepository.fileEvidence(missionID: mission.id,
                                                                  criterionID: criterionID)
        guard agentMission?.id == mission.id, selectedConversationID == mission.conversationID else { return nil }
        return evidence
    }

    @discardableResult
    func recordActionReview(callID: String, assessment: ActionEffectAssessment, note: String) async -> Bool {
        guard !isReviewingMission, !isSending, let mission = agentMission,
              mission.conversationID == selectedConversationID, mission.state == .blocked else { return false }
        isReviewingMission = true
        defer { isReviewingMission = false }
        do {
            let updated = try await missionRepository.recordReconciliation(missionID: mission.id,
                expectedRevision: mission.revision, callID: callID, assessment: assessment, note: note)
            guard selectedConversationID == mission.conversationID else { return true }
            agentMission = updated
            await loadWorkspaceHistory()
            return true
        } catch {
            if selectedConversationID == mission.conversationID {
                agentMission = try? await missionRepository.latest(conversationID: mission.conversationID)
                alertMessage = "Action review was not saved: \(error.localizedDescription)"
            }
            return false
        }
    }

    @discardableResult
    func completeMissionReview(note: String) async -> Bool {
        guard !isReviewingMission, !isSending, let mission = agentMission,
              mission.conversationID == selectedConversationID, mission.state == .blocked else { return false }
        isReviewingMission = true
        defer { isReviewingMission = false }
        do {
            let updated = try await missionRepository.completeReview(missionID: mission.id,
                expectedRevision: mission.revision, note: note)
            guard selectedConversationID == mission.conversationID else { return true }
            agentMission = updated
            messages = try await conversationRepository.messages(conversationID: mission.conversationID)
            await loadWorkspaceHistory()
            return true
        } catch {
            if selectedConversationID == mission.conversationID {
                agentMission = try? await missionRepository.latest(conversationID: mission.conversationID)
                alertMessage = "Mission review was not completed: \(error.localizedDescription)"
            }
            return false
        }
    }

    func continueReviewedMission() async {
        guard let mission = agentMission, mission.conversationID == selectedConversationID,
              mission.state == .partial,
              mission.stateReason?.hasPrefix("The user reviewed the interrupted run.") == true,
              !isSending else { return }
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText = "Continue the mission using my recorded review. First inspect the current target state; do not blindly repeat an interrupted action."
        }
        await sendComposer()
    }

    @discardableResult
    func chooseWorkspace(_ path: String) async -> Bool {
        guard !isChangingWorkspace, !isSending, !isLoadingConversation, !isShuttingDown else { return false }
        let canonical = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            alertMessage = "Choose an existing workspace folder."
            return false
        }
        if let selectedProjectID {
            do {
                if try await linkedFolderWriteAccess(for: canonical, projectID: selectedProjectID) == false {
                    alertMessage = "This folder is linked read-only. Grant Code access in the project's sources first."
                    return false
                }
            } catch {
                alertMessage = "Project folder permissions could not be checked."
                return false
            }
        }
        isChangingWorkspace = true
        defer { isChangingWorkspace = false }
        let navigation = navigationID
        let conversationID = selectedConversationID
        do {
            if let conversationID {
                guard var conversation = try await conversationRepository.conversation(id: conversationID),
                      navigationID == navigation, selectedConversationID == conversationID else { return false }
                conversation.workspacePath = canonical
                conversation.updatedAt = .now
                try await conversationRepository.save(conversation)
                guard navigationID == navigation, selectedConversationID == conversationID else { return false }
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index] = conversation
                }
            }
            guard navigationID == navigation, selectedConversationID == conversationID else { return false }
            workspaceToolsEnabled = false
            workspacePath = canonical
            settings.workspacePath = canonical
            settings.rememberWorkspace(canonical)
            await persistSettings()
            return true
        } catch {
            alertMessage = "The workspace could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// SecItemCopyMatching can wait for a macOS authorization dialog. It must
    /// not block the main actor (including after an ad-hoc signature changes).
    func captureCredentialScope() -> CredentialStorageScope.Snapshot { account.credentialScope.snapshot() }

    func scopedProviderCredentials() -> any SecureStoring { providerStore.boundToCurrentScope() }

    @ObservationIgnored lazy var legacyCredentialAdoption = LegacyCredentialAdoptionCoordinator(
        account: account, store: providerStore,
        didCopy: { [weak self] in
            guard let self else { return }
            self.providerInventoryRevision &+= 1
            await self.refreshProviderInventory()
            await self.refreshFluxKey()
            self.availableModels = []; self.catalogError = nil
        })

    private func providerKeyData(_ provider: ChatProvider) async throws -> Data? {
        if provider == .chatgpt { return try await chatGPTAccessToken().map { Data($0.utf8) } }
        return try await storedKeyData(provider)
    }

    private func storedKeyData(_ provider: ChatProvider) async throws -> Data? {
        let store = providerStore
        let captured = account.credentialScope.snapshot()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try store.readData(forKey: provider.rawValue, expectedScope: captured) })
            }
        }
    }

    private func resetProviderPresentationForIdentityChange() {
        navigationID = UUID()
        providerInventoryRevision &+= 1
        connectedProviders = []; hasFluxKey = false; chatGPTEmail = nil
        availableModels = []; catalogError = nil; isLoadingModels = false; catalogRequestID = UUID()
        chatGPTRefresh?.cancel(); chatGPTRefresh = nil; chatGPTRefreshScope = nil
        for (_, task) in memoryCaptureTasks.values { task.cancel() }
        memoryCaptureTasks.removeAll()
        cancelImageGeneration(); voiceSession?.stop(); voiceSession = nil
        Task { [weak self] in await self?.refreshProviderInventory() }
    }

    private func refreshProviderInventory() async {
        let captured = account.credentialScope.snapshot(), store = providerStore, revision = providerInventoryRevision
        do {
            let providers = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try store.configuredProviders() })
                }
            }
            guard account.credentialScope.snapshot() == captured, providerInventoryRevision == revision, !isShuttingDown else { return }
            connectedProviders = providers
        } catch {
            if account.credentialScope.snapshot() == captured, providerInventoryRevision == revision { connectedProviders = [] }
        }
    }

    // MARK: ChatGPT plan (official Sign in with ChatGPT)

    /// The signed-in ChatGPT account, for display.
    var chatGPTEmail: String?
    private var chatGPTRefresh: Task<String?, Error>?
    private var chatGPTRefreshScope: CredentialStorageScope.Snapshot?

    func saveChatGPTSession(_ session: ChatGPTPlanAuth.Session, expectedScope: CredentialStorageScope.Snapshot? = nil) throws {
        guard session.hasValidatedIdentity else { throw ChatGPTPlanAuth.AuthError.invalidIdentity }
        let captured = expectedScope ?? account.credentialScope.snapshot()
        guard captured == account.credentialScope.snapshot() else { throw CredentialScopeError.changed }
        let scopedStore = providerStore.boundToCurrentScope()
        try scopedStore.store(try JSONEncoder().encode(session), forKey: ChatGPTPlanAuth.sessionKey)
        try scopedStore.store(Data(session.accessToken.utf8), forKey: ChatProvider.chatgpt.rawValue)
        providerInventoryRevision &+= 1
        chatGPTEmail = session.email
        Task { await ModelCatalogCache.shared.invalidate(.chatgpt) }
        if session.canUsePlan { connectedProviders.insert(.chatgpt) }
        else { connectedProviders.remove(.chatgpt) }
        if selectedProvider == .chatgpt { availableModels = []; catalogError = nil }
    }

    func chatGPTSession() async throws -> ChatGPTPlanAuth.Session? {
        let store = providerStore
        let captured = account.credentialScope.snapshot()
        let data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try store.readData(forKey: ChatGPTPlanAuth.sessionKey, expectedScope: captured) })
            }
        }
        return data.flatMap { try? JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: $0) }
    }

    func refreshChatGPTAccount() async {
        let captured = account.credentialScope.snapshot()
        let session = try? await chatGPTSession()
        guard captured == account.credentialScope.snapshot() else { return }
        chatGPTEmail = session?.email
        if session?.canUsePlan != true { connectedProviders.remove(.chatgpt) }
    }

    /// A valid access token, refreshed shortly before it expires (one refresh at a time).
    private func chatGPTAccessToken() async throws -> String? {
        let captured = account.credentialScope.snapshot()
        if let running = chatGPTRefresh, chatGPTRefreshScope == captured {
            let value = try await running.value
            guard captured == account.credentialScope.snapshot() else { throw CredentialScopeError.changed }
            return value
        }
        guard let session = try await chatGPTSession() else { return nil }
        guard captured == account.credentialScope.snapshot() else { throw CredentialScopeError.changed }
        guard session.hasValidatedIdentity else { throw ChatGPTPlanAuth.AuthError.reauthorizationRequired }
        guard session.canUsePlan else { throw ChatGPTPlanAuth.AuthError.missingPlanAccess }
        if session.isFresh { return session.accessToken }
        guard let request = ChatGPTPlanAuth.refreshRequest(session) else { throw ChatGPTPlanAuth.AuthError.reauthorizationRequired }
        let refresh = Task { @MainActor [weak self] () throws -> String? in
            let http = ChatGPTPlanAuth.networkSession()
            defer { http.invalidateAndCancel() }
            let (data, response) = try await http.data(for: request)
            try Task.checkCancellation()
            guard self?.account.credentialScope.snapshot() == captured else { throw CredentialScopeError.changed }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 400 || status == 401 { throw ChatGPTPlanAuth.AuthError.reauthorizationRequired }
                throw ChatGPTPlanAuth.AuthError.invalidResponse
            }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let jwks = payload?["id_token"] == nil ? nil : try await ChatGPTPlanAuth.fetchJWKS(using: http)
            try Task.checkCancellation()
            guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked, self?.account.credentialScope.snapshot() == captured else { throw CredentialScopeError.changed }
            let renewed = try ChatGPTPlanAuth.session(from: data, clientID: session.clientID, hostID: session.hostID, previous: session, jwks: jwks)
            try self?.saveChatGPTSession(renewed, expectedScope: captured)
            guard renewed.canUsePlan else { throw ChatGPTPlanAuth.AuthError.missingPlanAccess }
            return renewed.accessToken
        }
        chatGPTRefresh = refresh; chatGPTRefreshScope = captured
        defer { if chatGPTRefreshScope == captured { chatGPTRefresh = nil; chatGPTRefreshScope = nil } }
        let value = try await refresh.value
        guard captured == account.credentialScope.snapshot() else { throw CredentialScopeError.changed }
        return value
    }

    func disconnectChatGPT() {
        providerInventoryRevision &+= 1
        try? providerStore.removeData(forKey: ChatGPTPlanAuth.sessionKey)
        try? providerStore.removeData(forKey: ChatProvider.chatgpt.rawValue)
        chatGPTEmail = nil
        connectedProviders.remove(.chatgpt)
        Task { await ModelCatalogCache.shared.invalidate(.chatgpt) }
    }

    func saveProviderKey(_ key: String, provider: ChatProvider, expectedScope: CredentialStorageScope.Snapshot? = nil) throws {
        if let expectedScope, expectedScope != account.credentialScope.snapshot() { throw CredentialScopeError.changed }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        try providerStore.store(Data(value.utf8), forKey: provider.rawValue)
        providerInventoryRevision &+= 1
        let revision = providerInventoryRevision
        let scope = account.credentialScope.snapshot()
        Task { [weak self] in
            await ModelCatalogCache.shared.invalidate(provider)
            guard let self, self.providerInventoryRevision == revision,
                  self.account.credentialScope.snapshot() == scope else { return }
            do {
                // Catalog metadata only; never creates a generation or transfers a key.
                let models = try await self.catalog(for: provider)
                guard self.providerInventoryRevision == revision,
                      self.account.credentialScope.snapshot() == scope,
                      self.connectedProviders.contains(provider) else { return }
                try await ModelCatalogCache.shared.save(models, for: provider)
            } catch {
                // Existing catalog/error handling remains available in the Mac picker.
                if self.providerInventoryRevision == revision, self.account.credentialScope.snapshot() == scope, self.selectedProvider == provider {
                    self.catalogError = "The model catalog could not be loaded. Check your connection and try again."
                }
            }
        }
        connectedProviders.insert(provider)
        if provider == .openAI { DictationEngine.adoptOpenAI() }
        if provider == selectedProvider { availableModels = []; catalogError = nil }
    }

    func transcribeWithOpenAI(_ audio: Data, language: String? = nil) async throws -> String {
        guard let saved = try await providerKeyData(.openAI),
              let key = String(data: saved, encoding: .utf8) else {
            throw OpenAITranscriptionError.missingKey
        }
        return try await OpenAITranscriptionService(meter: spendMeter).transcribe(m4a: audio, apiKey: key, language: language)
    }

    /// A separate, explicitly requested Images API call using the user's OpenAI key.
    /// The conversation is untouched until a validated image is ready to persist.
    func generateImage(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                       quality: OpenAIImageQuality, flux: FluxImageModel? = nil) async throws {
        guard mode == .chat, !isSending, !isGeneratingImage, !isShuttingDown,
              !isLoadingConversation, !isBranchingConversation, responseSaveError == nil else {
            throw OpenAIImageGenerationError.unavailable
        }
        let keyReadNavigation = navigationID
        let keyData = flux == nil ? try await providerKeyData(.openAI) : try await imageKeyData(BlackForestLabsImageService.keyName)
        guard let data = keyData, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw OpenAIImageGenerationError.missingKey
        }
        guard mode == .chat, !isSending, !isGeneratingImage, !isShuttingDown,
              !isLoadingConversation, !isBranchingConversation, responseSaveError == nil,
              navigationID == keyReadNavigation else { throw OpenAIImageGenerationError.unavailable }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate before starting a charged request.
        if let flux { _ = try BlackForestLabsImageService.request(prompt: text, model: flux, size: size, apiKey: key) }
        else {
            _ = try OpenAIImageGenerationService.request(prompt: text, model: model, size: size,
                                                         quality: quality, apiKey: key)
        }
        let originalConversationID = selectedConversationID
        let originalProjectID = selectedProjectID
        let originalNavigationID = navigationID
        let chatProvider = selectedProvider
        let chatModelID = selectedModelID
        let generator = imageGenerator
        let meter = spendMeter
        let task = Task {
            if let flux { return try await BlackForestLabsImageService(meter: meter).generate(prompt: text, model: flux, size: size, apiKey: key) }
            return try await generator.generate(prompt: text, model: model, size: size, quality: quality, apiKey: key)
        }
        imageGenerationTask = task
        imageGenerationCancelled = false
        isGeneratingImage = true
        defer { imageGenerationTask = nil; isGeneratingImage = false }
        let image: ImageAttachment
        do { image = try await task.value }
        catch {
            if imageGenerationCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard !isShuttingDown, !imageGenerationCancelled else { throw CancellationError() }

        let existing = originalConversationID.flatMap { id in
            conversations.first { $0.id == id && $0.mode == .chat }
        }
        let conversation = existing ?? Conversation(title: String(text.prefix(80)), mode: .chat,
                                                     projectID: originalProjectID, provider: chatProvider,
                                                     modelID: chatModelID.isEmpty ? nil : chatModelID)
        let history = existing == nil ? [] : try await conversationRepository.messages(conversationID: conversation.id)
        guard !isShuttingDown, !imageGenerationCancelled else { throw CancellationError() }
        let sequence = (history.last?.sequence ?? -1) + 1
        let request = ConversationMessage(conversationID: conversation.id, role: .user,
                                          content: text, sequence: sequence)
        let result = ConversationMessage(conversationID: conversation.id, role: .assistant,
                                         content: flux.map { "Generated with Black Forest Labs · \($0.title)" } ?? "Generated with OpenAI · \(model.title)",
                                         sequence: sequence + 1, images: [image])
        if existing == nil { try await conversationRepository.save(conversation) }
        try await conversationRepository.appendPair(request, result)
        conversations = try await nonemptyConversations()
        if navigationID == originalNavigationID, mode == .chat,
           selectedConversationID == originalConversationID {
            if existing == nil { await selectConversation(conversation.id) }
            else { messages = history + [request, result] }
        }
    }

    func cancelImageGeneration() {
        imageGenerationCancelled = true
        imageGenerationTask?.cancel()
        mediaGenerationTask?.cancel()
    }

    // MARK: Images and videos from Black Forest Labs and OpenRouter

    /// Where generated videos are kept (next to the database; a temporary folder without one).
    var mediaDirectory: URL {
        let folder = paths?.media ?? FileManager.default.temporaryDirectory.appending(path: "AIM-Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func videoURL(_ video: VideoAttachment) -> URL { mediaDirectory.appending(path: video.fileName) }

    /// Media models the person can use now: FLUX with a Black Forest Labs key, and every
    /// image or video model of OpenRouter's catalog when OpenRouter is connected.
    func availableMediaModels() async -> [AIMApplication.MediaModel] {
        var result = hasFluxKey ? AIMApplication.MediaModel.blackForestLabs : []
        if connectedProviders.contains(.openRouter) {
            let catalog: [ChatModel]
            if let cached = await ModelCatalogCache.shared.cached(.openRouter) { catalog = cached }
            else { catalog = (try? await self.catalog(for: .openRouter)) ?? [] }
            for model in catalog.compactMap(AIMApplication.MediaModel.from) where !result.contains(where: { $0.id == model.id }) {
                result.append(model)
            }
        }
        return result
    }

    func openMediaCreator(preset: String? = nil) {
        mediaCreatorPreset = preset
        showModelPicker = false
        if mode != .chat { selectMode(.chat) }
        showMediaCreator = true
    }

    /// One explicit, possibly billed request; the result is saved as a new exchange.
    func generateMedia(prompt: String, model media: AIMApplication.MediaModel, route: AIMApplication.MediaRoute, options: AIMApplication.MediaOptions) async throws {
        guard mode == .chat, !isSending, !isGeneratingImage, !isShuttingDown,
              !isLoadingConversation, !isBranchingConversation, responseSaveError == nil else {
            throw OpenAIImageGenerationError.unavailable
        }
        let keyReadNavigation = navigationID
        let keyData = route == .blackForestLabs ? try await imageKeyData(BlackForestLabsImageService.keyName)
                                                : try await providerKeyData(.openRouter)
        guard let data = keyData, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw MediaGenerationError.missingKey(route == .blackForestLabs ? "Black Forest Labs" : "OpenRouter")
        }
        guard navigationID == keyReadNavigation, !isShuttingDown else { throw OpenAIImageGenerationError.unavailable }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate before starting a charged request.
        if route == .blackForestLabs { _ = try BlackForestLabsImageService.mediaRequest(prompt: text, model: media, options: options, apiKey: key) }
        else { _ = try OpenRouterMediaService.request(prompt: text, model: media, options: options, apiKey: key) }
        let originalConversationID = selectedConversationID
        let originalProjectID = selectedProjectID
        let originalNavigationID = navigationID
        let chatProvider = selectedProvider
        let chatModelID = selectedModelID
        let meter = spendMeter
        let task = Task {
            if route == .blackForestLabs {
                return try await BlackForestLabsImageService(meter: meter).generate(prompt: text, model: media, options: options, apiKey: key)
            }
            return try await OpenRouterMediaService(meter: meter).generate(prompt: text, model: media, options: options, apiKey: key)
        }
        mediaGenerationTask = task
        imageGenerationCancelled = false
        isGeneratingImage = true
        defer { mediaGenerationTask = nil; isGeneratingImage = false }
        let generated: GeneratedMedia
        do { generated = try await task.value }
        catch {
            if imageGenerationCancelled { throw CancellationError() }
            throw error
        }
        guard !isShuttingDown, !imageGenerationCancelled else { throw CancellationError() }

        let label = "Generated with \(route == .blackForestLabs ? "Black Forest Labs" : "OpenRouter") · \(media.name)"
        var images: [ImageAttachment]?
        var videos: [VideoAttachment]?
        switch generated {
        case .image(let image): images = [image]
        case .video(let bytes):
            let video = VideoAttachment(byteCount: bytes.count, title: media.name)
            try bytes.write(to: videoURL(video), options: .atomic)
            videos = [video]
        }
        let existing = originalConversationID.flatMap { id in conversations.first { $0.id == id && $0.mode == .chat } }
        let conversation = existing ?? Conversation(title: String(text.prefix(80)), mode: .chat,
                                                     projectID: originalProjectID, provider: chatProvider,
                                                     modelID: chatModelID.isEmpty ? nil : chatModelID)
        let history = existing == nil ? [] : try await conversationRepository.messages(conversationID: conversation.id)
        let sequence = (history.last?.sequence ?? -1) + 1
        let request = ConversationMessage(conversationID: conversation.id, role: .user, content: text, sequence: sequence)
        let result = ConversationMessage(conversationID: conversation.id, role: .assistant, content: label,
                                         sequence: sequence + 1, images: images, videos: videos)
        if existing == nil { try await conversationRepository.save(conversation) }
        try await conversationRepository.appendPair(request, result)
        conversations = try await nonemptyConversations()
        if navigationID == originalNavigationID, mode == .chat, selectedConversationID == originalConversationID {
            if existing == nil { await selectConversation(conversation.id) }
            else { messages = history + [request, result] }
        }
    }

    func reuseImageInComposer(_ image: ImageAttachment) {
        guard canImportAttachments else { return }
        do { try ImageAttachment.validate(pendingImages + [image]); pendingImages.append(image) }
        catch { alertMessage = error.localizedDescription }
    }

    func checkProviderKey(_ enteredKey: String, provider: ChatProvider) async throws -> ProviderChatService.CredentialCheck {
        let key = try await resolvedProviderKey(enteredKey, provider: provider)
        return try await ProviderChatService().checkCredential(provider: provider, apiKey: key)
    }

    func testProviderInference(_ enteredKey: String, provider: ChatProvider, modelID: String) async throws -> String {
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw ChatServiceError.invalidResponse }
        let key = try await resolvedProviderKey(enteredKey, provider: provider)
        return try await ProviderInferenceProbe(service: ProviderChatService(meter: spendMeter))
            .run(provider: provider, modelID: modelID, apiKey: key)
    }

    private func resolvedProviderKey(_ enteredKey: String, provider: ChatProvider) async throws -> String {
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredKey.isEmpty && entered.isEmpty { throw ChatServiceError.missingKey }
        if entered.isEmpty {
            guard let saved = try await providerKeyData(provider),
                  let value = String(data: saved, encoding: .utf8) else { throw ChatServiceError.missingKey }
            return value
        }
        return entered
    }

    // MARK: Remote (control from the phone)

    /// Off by default (protocol v2 §3.6); the person turns it on in Settings → Remote.
    func setRemoteEnabled(_ enabled: Bool) async {
        guard !isChangingRemote else { return }
        isChangingRemote = true; defer { isChangingRemote = false }
        do { _ = try await remoteControl(.init(action: .setEnabled, enabled: enabled)) }
        catch {
            remoteStatus = .failed(error.localizedDescription)
            // Re-observe a lost mutation ACK; never replay enable/revoke/pairing.
            await refreshRemoteState(preservingFailure: true)
        }
    }

    func refreshRemoteState(preservingFailure: Bool = false) async {
        do { _ = try await remoteControl(.init(action: .status)) }
        catch { if !preservingFailure { remoteStatus = .failed(error.localizedDescription); remoteHostAvailable = false } }
    }
    func remoteDiagnosticReport() async throws -> RemoteDiagnosticReport {
        guard let report = try await remoteControl(.init(action: .diagnostics)).diagnosticReport else { throw RuntimeRemoteControlError.unavailable }
        return report
    }
    func remoteDevices() async throws -> [RemoteHostDevice] { try await remoteControl(.init(action: .devices)).devices }
    func remotePairingCode() async throws -> RemotePairingCode {
        guard let code = try await remoteControl(.init(action: .pairingCode)).pairingCode else { throw RuntimeRemoteControlError.invalidRequest }
        return code
    }
    func revokeRemoteDevice(_ id: String) async throws { _ = try await remoteControl(.init(action: .revoke, deviceID: id)) }
    private func remoteControl(_ control: RuntimeRemoteControl) async throws -> RuntimeRemoteState {
        let command = AgentHostCommand(action: .remote, accountID: account.accessUser?.id, payload: try JSONEncoder().encode(control))
        let data: Data
        if let continuityRuntime { data = try await continuityRuntime.send(command) }
        else { data = try await handleIntegratedRemoteControl(command) }
        let state = try JSONDecoder().decode(RuntimeRemoteState.self, from: data)
        guard state.version == 1, state.accountID == account.accessUser?.id else { throw RuntimeRemoteControlError.unauthorized }
        remoteEnabled = state.enabled; remoteStatus = state.status; remoteHostAvailable = state.hostAvailable
        return state
    }
    private func handleIntegratedRemoteControl(_ command: AgentHostCommand) async throws -> Data {
        guard settings.continuity?.permanent != true, command.accountID == account.accessUser?.id,
              let payload = command.payload else { throw RuntimeRemoteControlError.unauthorized }
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
            remoteEnabled = control.enabled!
            AIMInstallationContext.sharedPreferences.set(remoteEnabled, forKey: "AIMRemoteEnabled")
            AIMInstallationContext.sharedPreferences.synchronize()
            if remoteEnabled { await startRemoteHostIfEnabled() } else { await stopRemoteHost() }
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
        guard account.accessUser?.id == current else { await stopRemoteHost(); throw RuntimeRemoteControlError.unauthorized }
        return try JSONEncoder().encode(RuntimeRemoteState(accountID: current, enabled: remoteEnabled,
            hostAvailable: remoteHost != nil, status: remoteStatus, devices: devices, pairingCode: code, diagnosticReport: diagnosticReport))
    }

    func makeDirectSessionBridge(profileID: UUID, authorizeOperation: @escaping @Sendable () throws -> Void) async throws -> RuntimeRemoteSessionBridge {
        guard account.identity?.isLocal == true, account.identity?.storageID == profileID,
              let continuityRuntime else { throw DirectRemoteError.unauthorized }
        return try await continuityRuntime.directSessionBridge(localProfileID: profileID, authorizeOperation: authorizeOperation)
    }

    func refreshDirectRemote() async {
        guard !isShuttingDown, let identity = account.identity, case let .local(profile) = identity else {
            await directRemote?.stop(); directRemote = nil; return
        }
        if directRemote?.profileID != profile.id {
            await directRemote?.stop(); directRemote = nil
            do { directRemote = try MacDirectRemoteCoordinator(model: self, profile: profile); directRemoteError = nil }
            catch { directRemoteError = "Direct pairing could not securely open this profile. Existing data is preserved." }
        }
        await directRemote?.start()
    }

    func startRemoteHostIfEnabled() async {
        await refreshDirectRemote()
        guard remoteRuntimeReady, !remoteHostStarting, !isShuttingDown else { return }
        let expectedAccount = account.accessUser?.id
        remoteHostStarting = true
        defer {
            remoteHostStarting = false
            if account.accessUser?.id != expectedAccount, hasAccess, !isShuttingDown {
                Task { [weak self] in await self?.startRemoteHostIfEnabled() }
            }
        }
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { await stopRemoteHost(); return }
        if settings.continuity?.permanent == true { await refreshRemoteState(); return }
        AIMInstallationContext.sharedPreferences.synchronize()
        remoteEnabled = AIMInstallationContext.sharedPreferences.bool(forKey: "AIMRemoteEnabled")
        if remoteHost != nil, remoteHostAccountID != expectedAccount { await stopRemoteHost() }
        guard account.accessUser?.id == expectedAccount, remoteEnabled, remoteHost == nil, !isShuttingDown else { return }
        guard let expectedAccount, let client = account.supabaseClient, account.user != nil else {
            remoteStatus = .failed(RemoteHostError.notSignedIn.localizedDescription)
            return
        }
        let bridge = RemoteHostBridge(model: self)
        let delegate: any RemoteHostDelegate
        let journal: (any RemoteHostCommandJournal)?
        if let continuityRuntime {
            do {
                delegate = try await continuityRuntime.remoteDelegate(legacy: bridge)
                journal = try await continuityRuntime.remoteJournal(database: database)
            } catch {
                if account.accessUser?.id == expectedAccount { remoteStatus = .failed(error.localizedDescription) }
                return
            }
        } else { delegate = bridge; journal = nil }
        guard account.accessUser?.id == expectedAccount, remoteEnabled, hasAccess, !isShuttingDown, settings.continuity?.permanent != true else { return }
        let host = RemoteHost(backend: SupabaseRemoteHostBackend(client: client),
            store: RemoteHostIdentityStore(accountID: expectedAccount),
            currentAccountID: { [weak self] in await MainActor.run { self?.account.accessUser?.id } }, delegate: delegate,
            machineName: HostBundleResources.remoteMachineName, journal: journal)
        remoteBridge = bridge
        remoteHost = host; remoteHostAccountID = expectedAccount; remoteHostAvailable = true
        let statuses = await host.statusUpdates()
        remoteTasks.append(Task { [weak self] in
            for await status in statuses {
                guard let self, self.remoteHost === host, self.account.accessUser?.id == expectedAccount, !Task.isCancelled else { return }
                self.remoteStatus = status
            }
        })
        // Resync cadence of the desktop app: 400 ms while a run is going, 1 s at rest.
        remoteTasks.append(Task { [weak self] in
            var last = 0
            var lastCatalogRevision: UInt64?
            while !Task.isCancelled {
                guard let self, self.remoteHost === host, self.account.accessUser?.id == expectedAccount, !Task.isCancelled else { return }
                let fingerprint = self.remoteFingerprint
                let catalogRevision = await ModelCatalogCache.shared.revision
                if fingerprint != last || catalogRevision != lastCatalogRevision {
                    last = fingerprint; lastCatalogRevision = catalogRevision
                    await host.mirrorChanged()
                }
                try? await Task.sleep(for: .milliseconds(self.isSending ? 400 : 1_000))
            }
        })
        await host.start()
        guard remoteHost === host, account.accessUser?.id == expectedAccount, !isShuttingDown else {
            await host.stop(); return
        }
        if case .online = await host.status {
            guard remoteHost === host, account.accessUser?.id == expectedAccount, !isShuttingDown,
                  settings.continuity?.permanent != true else { return }
            // Peers require confirmed account-scoped registration; their failure
            // does not prevent the phone Remote host or local runtime from starting.
            try? await continuityRuntime?.configurePeers(relay: SupabaseRemotePeerRelay(client: client))
        }
    }

    /// Entry preserves account data/credentials; it closes managed remote and
    /// opaque extension channels rather than signing the person out.
    private(set) var applicationPrivacyTransition = false
    var hasPendingApplicationPrivacyChange: Bool { AIMNetworkPrivacyAdmission.isPreparing }
    var applicationPrivacyPendingDiagnostic: String? {
        hasPendingApplicationPrivacyChange
            ? "A private-mode change is pending. AIM network admission remains closed. Retry with the current runtime owner, or explicitly cancel the pending change to reopen admission."
            : nil
    }
    func setApplicationPrivateMode(_ enabled: Bool) async throws {
        guard !applicationPrivacyTransition else { throw AIMNetworkPrivacyTransactionError.conflictingTransaction }
        applicationPrivacyTransition = true; defer { applicationPrivacyTransition = false }
        if !enabled {
            try RuntimePrivacyPolicy.setGlobalEnabled(false)
            await account.applyNetworkPrivacy()
            _ = ProcessSupervisor.shared.resumeAfterCancelledShutdown()
            await startRemoteHostIfEnabled()
            return
        }
        try updateController.requirePrivateModeActivation()
        let runtime = continuityRuntime
        let ownerStatus: RuntimePrivacyAcknowledgement?
        var absenceLease: RuntimeLease?
        if let runtime {
            let payload = try JSONEncoder().encode(RuntimePrivacyControl(action: .status))
            let response = try await runtime.send(AgentHostCommand(action: .privacy, payload: payload))
            let status = try JSONDecoder().decode(RuntimePrivacyAcknowledgement.self, from: response)
            guard status.version == 1, status.phase == .status, status.processID > 0 else {
                throw AIMNetworkPrivacyTransactionError.invalidReceipt
            }
            ownerStatus = status
        } else {
            guard settings.continuity?.permanent != true, let paths else { throw AgentHostTransportError.disconnected }
            // Prove there is no disconnected runtime, and prevent one acquiring
            // ownership until this application's no-runtime commit completes.
            absenceLease = try RuntimeLease(url: paths.applicationSupport.appending(path: "agent-runtime.lock"))
            ownerStatus = nil
        }
        defer { absenceLease?.release() }
        let preparation: AIMNetworkPrivacyPreparation
        if let pending = try AIMNetworkPrivacyAdmission.pending(), !(try AIMNetworkPrivacyAdmission.isCommitted(pending)) {
            guard pending.ownerGeneration == ownerStatus?.ownerGeneration else { throw AIMNetworkPrivacyTransactionError.ownerChanged }
            preparation = AIMNetworkPrivacyPreparation(transactionID: pending.transactionID, ownerGeneration: pending.ownerGeneration)
        } else { preparation = AIMNetworkPrivacyPreparation(ownerGeneration: ownerStatus?.ownerGeneration) }
        // This marker is the admission boundary in both processes. The visible
        // preference stays unchanged until the owner commits matching receipts.
        try AIMNetworkPrivacyAdmission.begin(preparation)
        do {
            await account.applyNetworkPrivacy()
            await stopRemoteHost()
            await AgentPluginRegistry.shared.stop()
            await MCPServerManager.shared.closeAll()
            LocalModelRuntime.stopOpaqueServers()
            for id in AgentEngineID.allCases where id != .aim { await engineRegistry.engine(id)?.stop() }
            ProcessSupervisor.shared.beginShutdown()
            try await ProcessSupervisor.shared.waitForPrivacyIdle()
            try await AIMManagedNetworkSession.quiesceDisallowedTasks()
            try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
            if let runtime, let ownerStatus {
                let prepared = try await privacyAcknowledgement(runtime, action: .prepare, preparation: preparation)
                try validatePrivacyAcknowledgement(prepared, status: ownerStatus, preparation: preparation, phase: .prepared)
            }
            // Re-drain the application after waiting for the other participant.
            try await AIMManagedNetworkSession.quiesceDisallowedTasks()
            try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
            try AIMNetworkPrivacyAdmission.acknowledgeApplication(preparation)
            try updateController.requirePrivateModeActivation()
            if let runtime, let ownerStatus {
                let committed = try await privacyAcknowledgement(runtime, action: .commit, preparation: preparation)
                try validatePrivacyAcknowledgement(committed, status: ownerStatus, preparation: preparation, phase: .committed)
            } else { try AIMNetworkPrivacyAdmission.commit(preparation, ownerReceipt: nil) }
            guard RuntimePrivacyPolicy.isGlobalEnabled, try AIMNetworkPrivacyAdmission.isCommitted(preparation) else {
                throw AIMNetworkPrivacyTransactionError.invalidReceipt
            }
            updateController.suspendNetworkForPrivateMode()
            _ = ProcessSupervisor.shared.resumeAfterCancelledShutdown()
        } catch {
            // A lost ACK or owner change must keep admission closed. Only an
            // explicit setter(false) may reopen a failed/pending transaction.
            throw error
        }
    }

    private func privacyAcknowledgement(_ runtime: AgentRuntimeController, action: RuntimePrivacyControl.Action,
        preparation: AIMNetworkPrivacyPreparation) async throws -> RuntimePrivacyAcknowledgement {
        let payload = try JSONEncoder().encode(RuntimePrivacyControl(action: action, preparation: preparation))
        let response = try await runtime.send(AgentHostCommand(action: .privacy, payload: payload))
        return try JSONDecoder().decode(RuntimePrivacyAcknowledgement.self, from: response)
    }
    private func validatePrivacyAcknowledgement(_ acknowledgement: RuntimePrivacyAcknowledgement,
        status: RuntimePrivacyAcknowledgement, preparation: AIMNetworkPrivacyPreparation,
        phase: RuntimePrivacyAcknowledgement.Phase) throws {
        guard acknowledgement.version == 1, acknowledgement.phase == phase,
              acknowledgement.ownerGeneration == status.ownerGeneration,
              acknowledgement.processID == status.processID,
              acknowledgement.preparation == preparation else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
    }

    /// Switches storage scope and cancels work from the previous identity.
    func accountAccessChanged() async {
        guard didStart, !isShuttingDown else { return }
        await directRemote?.stop(); directRemote = nil
        let draftSaved = flushComposer()
        await cancelCurrentTurn()
        try? await continuityRuntime?.suspendUnauthorized()
        voiceSession?.stop(); voiceSession = nil
        await stopRemoteHost()
        guard draftSaved else { return }
        selectedConversationID = nil; messages = []; selectedProjectID = nil
        _ = restoreComposer(scope: newComposerScope)
        do {
            if accountPreferenceScopeReady { try prepareAccountPreferenceScope(); await persistSettings() }
        }
        catch { accountSyncMessage = "Account preferences could not be loaded safely. Previous settings are preserved." }
        if let id = selectedConversationID,
           (try? await accountChatSync.isVisible(id, identity: account.identity)) != true {
            await cancelCurrentTurn()
            selectedConversationID = nil; messages = []
        }
        do { try await reloadConversations(); projects = try await visibleProjects() }
        catch { conversations = []; projects = []; selectedConversationID = nil; messages = [] }
        if hasAccess {
            if remoteHost != nil, remoteHostAccountID != account.accessUser?.id { await stopRemoteHost() }
            await startScheduledTasks()
            await startRemoteHostIfEnabled()
            return
        }
        try? await continuityRuntime?.suspendUnauthorized()
        if settings.continuity?.permanent == true, account.sharedSessionSuspended { _ = try? await continuityRuntime?.send(AgentHostCommand(action: .logout)) }
        await cancelCurrentTurn()
        voiceSession?.stop()
        voiceSession = nil
        await stopRemoteHost()
        triggerMonitor?.stopAll()
        triggerMonitor = nil
        await taskScheduler?.stop()
        taskScheduler = nil
        settingsSection = nil
        showModelPicker = false
        isShowingArchives = false
    }

    func stopRemoteHost() async {
        await directRemote?.stop()
        let host = remoteHost
        remoteHost = nil; remoteHostAccountID = nil
        remoteBridge = nil; remoteHostAvailable = false; remoteStatus = .stopped
        for task in remoteTasks { task.cancel() }
        remoteTasks.removeAll()
        await host?.stop()
        try? await continuityRuntime?.configurePeers(relay: nil)
    }

    var directRemoteFingerprint: Int {
        var hash = Hasher(); hash.combine(remoteFingerprint); hash.combine(messages.last?.content)
        return hash.finalize()
    }

    private var remoteFingerprint: Int {
        var hasher = Hasher()
        for conversation in conversations where conversation.mode == .agent || conversation.mode == .chat {
            hasher.combine(conversation.id); hasher.combine(conversation.updatedAt); hasher.combine(conversation.title)
        }
        hasher.combine(providerInventoryRevision)
        hasher.combine(connectedProviders.map(\.rawValue).sorted())
        hasher.combine(RemoteModelCatalogMetadata.additions().sorted())
        for favorite in settings.favoriteModels ?? [] {
            hasher.combine(favorite.provider.rawValue); hasher.combine(favorite.modelID); hasher.combine(favorite.name)
        }
        hasher.combine(isSending); hasher.combine(selectedConversationID); hasher.combine(messages.count)
        hasher.combine(messages.last?.content.count); hasher.combine(pendingToolApprovals.map(\.id))
        hasher.combine(pendingAgentQuestions.map(\.id))
        return hasher.finalize()
    }

    // MARK: Voice

    /// Starts or ends a live spoken conversation. OpenAI Realtime by default when an
    /// OpenAI key exists; otherwise (or by choice) on-device recognition → AIM with any
    /// model → the chosen speech voice. Work goes to the agent with its usual approvals.
    func toggleVoiceConversation() async {
        if let session = voiceSession {
            session.stop()
            voiceSession = nil
            return
        }
        let engine = VoicePreferences.resolvedEngine(connected: connectedProviders)
        let session: any VoiceConversation
        if engine == .openAIRealtime {
            guard let key = await providerKey(.openAI) else {
                alertMessage = "OpenAI Realtime needs an OpenAI key. Add one in Settings → Providers, or choose “Any model” in Settings → Voice."
                return
            }
            session = RealtimeVoiceSession(apiKey: key, voice: VoicePreferences.realtimeVoice,
                instructions: RealtimeVoiceSession.defaultInstructions, meter: spendMeter) { [weak self] request in
                await self?.askAgentFromVoice(request) ?? "AIM is not available."
            }
        } else {
            session = CascadeVoiceSession(answer: { [weak self] said in
                await self?.askAgentFromVoice(said) ?? "AIM is not available."
            }, speak: { [weak self] reply in
                guard let self else { return }
                try await self.speakNow(reply, summarizeTo: 900)
            })
        }
        voiceSession = session
        await session.start()
    }

    private func providerKey(_ provider: ChatProvider) async -> String? {
        guard connectedProviders.contains(provider) else { return nil }
        return (try? await providerKeyData(provider)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Speaks with the person's voice settings (ChatGPT's voice by default when available).
    func speakNow(_ text: String, summarizeTo limit: Int = 4_000) async throws {
        let configuration = VoicePreferences.resolved(connected: connectedProviders)
        let key: String? = switch configuration.provider {
        case .openAI: await providerKey(.openAI)
        case .openRouter: await providerKey(.openRouter)
        default: nil
        }
        try await SpeechPlayer.shared.speak(String(text.prefix(limit)), configuration: configuration, key: key, meter: spendMeter)
    }

    /// Runs one request as a normal message in the current conversation and returns the answer.
    func askAgentFromVoice(_ request: String) async -> String {
        for _ in 0..<600 {
            guard isSending else { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let before = messages.count
        composerText = request
        await sendComposer()
        for _ in 0..<2_400 {
            if !isSending && messages.count > before { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let answer = messages.last(where: { $0.role == .assistant }), messages.count > before else {
            return "AIM could not complete the request (it may be waiting for an approval on screen)."
        }
        return answer.content.isEmpty ? "AIM finished without a written answer." : answer.content
    }

    func readAloud(_ text: String) async {
        if SpeechPlayer.shared.isSpeaking { SpeechPlayer.shared.stop(); return }
        do { try await speakNow(text) } catch { alertMessage = error.localizedDescription }
    }

    /// Local models need no key; a placeholder marks the provider as connected so
    /// every existing flow (picker, runner, catalog) works unchanged.
    // MARK: Built-in local models

    /// The engine's state, for the composer and the model picker.
    var localEngineState: BuiltInLocalEngine.State = .idle
    private var localEngineObserver: Task<Void, Never>?
    private static let builtInModelsKey = "aim.local.builtin"

    /// How a local model is started: the person's context and cache settings, else the
    /// largest usual context that fits this Mac next to the weights.
    static func localLaunch(name: String, file: URL) -> BuiltInLocalEngine.Configuration {
        let settings = LocalModelSettingsStore.shared.settings(for: name)
        let quantized = settings.kvCacheQuantized ?? false
        let architecture = LocalModelMemory.architecture(file)
        let context = settings.contextTokens ?? LocalModelMemory.recommendedContext(
            weightsBytes: LocalModelMemory.weightsBytes(file), architecture: architecture, quantizedCache: quantized)
        return .init(contextTokens: min(context, architecture?.maxContext ?? context), kvCacheQuantized: quantized)
    }

    private func loadBuiltIn(_ file: URL, name: String) async throws -> URL {
        observeLocalEngine()
        let launch = Self.localLaunch(name: name, file: file)
        let url = try await BuiltInLocalEngine.shared.load(file, name: name, contextTokens: launch.contextTokens,
                                                           kvCacheQuantized: launch.kvCacheQuantized)
        var known = UserDefaults.standard.dictionary(forKey: Self.builtInModelsKey) as? [String: String] ?? [:]
        known[name] = file.path
        UserDefaults.standard.set(known, forKey: Self.builtInModelsKey)
        return url
    }

    /// Loads a downloaded GGUF model in AIM's own engine and selects it.
    func useBuiltInModel(_ installed: HuggingFaceModelHub.InstalledModel) async throws {
        let url = try await loadBuiltIn(installed.file, name: installed.name)
        try await connectLocalModels(baseURL: url)
        selectProvider(.local)
        availableModels = [localChatModel(installed.name)]
        rememberModel(name: installed.name, creator: LocalModelBrowser.creator(for: installed.repo), provider: .local, id: installed.name)
        selectModel(installed.name)
    }

    /// Loads a downloaded MLX model (Hugging Face cache) in AIM's MLX engine and selects it.
    func useBuiltInMLXModel(repo: String, folder: URL) async throws {
        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        let url = try await loadBuiltIn(folder, name: name)
        try await connectLocalModels(baseURL: url)
        selectProvider(.local)
        availableModels = [localChatModel(name)]
        rememberModel(name: name, creator: LocalModelBrowser.creator(for: repo), provider: .local, id: name)
        selectModel(name)
    }

    /// The Customize page (skills, connectors, plugins) fills the main area.
    var showCustomize = false

    /// Set to open the model picker directly on a local model's settings page.
    var pendingLocalModelSettings: String?

    /// Opens the selected local model's settings in the model picker.
    func openLocalModelSettings(name: String? = nil) {
        let name = name ?? selectedModelID
        guard let file = builtInModelFile(name) else { return }
        pendingLocalModelSettings = LocalModelBrowser.settingsDetail(name: name, file: file)
        showModelPicker = true
    }

    /// The file or folder of a built-in model, by the name sent to the engine.
    func builtInModelFile(_ name: String) -> URL? {
        (UserDefaults.standard.dictionary(forKey: Self.builtInModelsKey) as? [String: String])?[name].map { URL(fileURLWithPath: $0) }
    }

    /// The local model as the rest of AIM sees it; its context is what the engine was started with,
    /// so history summaries keep requests inside it.
    private func localChatModel(_ name: String) -> ChatModel {
        let context = builtInModelFile(name).map { Self.localLaunch(name: name, file: $0).contextTokens }
        return ChatModel(id: name, name: name, contextLength: context)
    }

    /// Before sending to a built-in model, (re)load it if the engine unloaded it or its
    /// context or cache settings changed.
    private func ensureBuiltInModelLoaded() async -> Bool {
        guard selectedProvider == .local, let file = builtInModelFile(selectedModelID) else { return true }
        let launch = Self.localLaunch(name: selectedModelID, file: file)
        let engine = BuiltInLocalEngine.shared
        if await engine.loadedModelFile == file, await engine.loadedModelConfiguration == launch {
            await engine.touch()
            return true
        }
        do {
            LocalModelEndpoint.baseURL = try await loadBuiltIn(file, name: selectedModelID)
            if let index = availableModels.firstIndex(where: { $0.id == selectedModelID }) {
                availableModels[index] = localChatModel(selectedModelID)
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func observeLocalEngine() {
        guard localEngineObserver == nil else { return }
        localEngineObserver = Task { [weak self] in
            for await state in await BuiltInLocalEngine.shared.updates() {
                guard !Task.isCancelled else { return }
                self?.localEngineState = state
            }
        }
    }

    func connectLocalModels(baseURL: URL) async throws {
        LocalModelEndpoint.baseURL = baseURL
        _ = try await ProviderChatService().models(provider: .local, apiKey: nil)
        try providerStore.store(Data("local".utf8), forKey: ChatProvider.local.rawValue)
        connectedProviders.insert(.local)
        await ModelCatalogCache.shared.invalidate(.local)
    }

    /// Keys of image-only providers (Black Forest Labs), kept beside the chat providers' keys.
    private func imageKeyData(_ name: String) async throws -> Data? {
        let store = providerStore
        let captured = account.credentialScope.snapshot()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try store.readData(forKey: name, expectedScope: captured) })
            }
        }
    }

    func saveFluxKey(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        try providerStore.store(Data(value.utf8), forKey: BlackForestLabsImageService.keyName)
        hasFluxKey = true
    }

    func removeFluxKey() {
        try? providerStore.removeData(forKey: BlackForestLabsImageService.keyName)
        hasFluxKey = false
    }

    func refreshFluxKey() async {
        let captured = account.credentialScope.snapshot()
        let exists = ((try? await imageKeyData(BlackForestLabsImageService.keyName)) ?? nil) != nil
        guard captured == account.credentialScope.snapshot() else { return }
        hasFluxKey = exists
    }

    func removeProviderKey(_ provider: ChatProvider) {
        if provider == .chatgpt { disconnectChatGPT(); return }
        do {
            try providerStore.removeData(forKey: provider.rawValue)
            providerInventoryRevision &+= 1
            connectedProviders.remove(provider)
            Task { await ModelCatalogCache.shared.invalidate(provider) }
        }
        catch { alertMessage = "Could not remove the key from Keychain." }
    }

    func catalog(for provider: ChatProvider) async throws -> [ChatModel] {
        let captured = account.credentialScope.snapshot()
        let key = provider == .openRouter ? nil : try await providerKeyData(provider).flatMap { String(data: $0, encoding: .utf8) }
        let models = try await ProviderChatService().models(provider: provider, apiKey: key)
        guard captured == account.credentialScope.snapshot() else { throw CredentialScopeError.changed }
        return models
    }

    func loadModels() async {
        let captured = account.credentialScope.snapshot()
        let requestID = UUID()
        catalogRequestID = requestID
        let provider = selectedProvider
        if provider != .openRouter && !hasProviderKey {
            // A missing key is onboarding state, not a network/catalog failure.
            isLoadingModels = false
            availableModels = []
            catalogError = nil
            return
        }
        if let cached = await ModelCatalogCache.shared.cached(provider) { availableModels = cached }
        if await ModelCatalogCache.shared.isFresh(provider) { isLoadingModels = false; return }
        isLoadingModels = true
        catalogError = nil
        defer { if catalogRequestID == requestID { isLoadingModels = false } }
        do {
            let key = provider == .openRouter ? nil : try await providerKeyData(provider).flatMap { String(data: $0, encoding: .utf8) }
            let models = try await ProviderChatService().models(provider: provider, apiKey: key)
            guard captured == account.credentialScope.snapshot(), selectedProvider == provider, catalogRequestID == requestID, !Task.isCancelled else { return }
            try? await ModelCatalogCache.shared.save(models, for: provider)
            guard captured == account.credentialScope.snapshot(), selectedProvider == provider, catalogRequestID == requestID, !Task.isCancelled else { return }
            availableModels = models
        } catch {
            guard selectedProvider == provider, catalogRequestID == requestID, !Task.isCancelled else { return }
            catalogError = (error as? ChatServiceError)?.localizedDescription ?? "The model catalog could not be loaded. Check your connection and try again."
        }
    }

    func selectProvider(_ provider: ChatProvider) {
        guard provider != selectedProvider else { return }
        if mode == .agent, [.openClaw, .hermes].contains(selectedAgentEngineID), provider != .openRouter {
            alertMessage = "Les bridges OpenClaw et Hermes utilisent actuellement OpenRouter. Choisis AIM Agent pour utiliser ce fournisseur."
            return
        }
        workspaceToolsEnabled = false
        selectedProvider = provider; selectedModelID = ""; availableModels = []; catalogError = nil
        settings.selectedProvider = provider; settings.selectedModelID = nil
        Task { await persistSettings() }
    }

    func needsProviderSwitchDisclosure(to provider: ChatProvider) -> Bool {
        selectedConversationID != nil && provider != selectedProvider
    }

    private static let modelNamesKey = "aim.models.names"
    private static let modelCreatorsKey = "aim.models.creators"

    /// What the composer shows for the selected model, even before its catalog has loaded:
    /// the catalog name, else the name remembered when it was chosen, else a tidied id.
    /// The effort in effect for the selected model: the saved one, else the model's default
    /// (local models answer without thinking unless asked).
    var effectiveReasoningEffort: OpenAIReasoningEffort? {
        reasoningEffort(provider: selectedProvider, modelID: selectedModelID)
            ?? modeDefaultEffort
            ?? (selectedProvider == .local ? OpenAIReasoningEffort.none
                : OpenAIReasoningEffort.defaultLevel(info: modelInfo(provider: selectedProvider, modelID: selectedModelID)?.reasoning))
    }

    /// Settings › Configuration: the mode's default effort, when this model offers it.
    private var modeDefaultEffort: OpenAIReasoningEffort? {
        guard let raw = preferences.modeDefaults[mode.rawValue]?.effort, let effort = OpenAIReasoningEffort(rawValue: raw),
              OpenAIReasoningEffort.levels(provider: selectedProvider, modelID: selectedModelID,
                                           info: modelInfo(provider: selectedProvider, modelID: selectedModelID)?.reasoning).contains(effort)
        else { return nil }
        return effort
    }

    var selectedModelPresentation: (name: String, creator: String) {
        presentation(provider: selectedProvider, modelID: selectedModelID)
    }

    /// A model's display name and maker: the catalog, else what was remembered when it was chosen.
    func presentation(provider: ChatProvider, modelID: String) -> (name: String, creator: String) {
        let key = provider.rawValue + ":" + modelID
        var creators = UserDefaults.standard.dictionary(forKey: Self.modelCreatorsKey) as? [String: String] ?? [:]
        // A local model's maker comes from its name (e.g. "Qwen3-8B" → Qwen), never "local".
        if provider == .local, creators[key] == nil { creators[key] = LocalModelBrowser.creator(for: modelID) }
        if provider == selectedProvider, let model = availableModels.first(where: { $0.id == modelID }) {
            return (ModelIdentity.displayName(model, via: provider),
                    creators[key] ?? ModelIdentity.creator(for: model, via: provider))
        }
        let names = UserDefaults.standard.dictionary(forKey: Self.modelNamesKey) as? [String: String] ?? [:]
        let fallback = ChatModel(id: modelID, name: modelID)
        return (names[key] ?? Self.tidy(modelID), creators[key] ?? ModelIdentity.creator(for: fallback, via: provider))
    }

    /// "claude-fable-5-1" → "Claude Fable 5.1" (only until the real name is known).
    static func tidy(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let words = last.split(separator: "-").map { String($0) }
        var parts: [String] = []
        for word in words {
            if let previous = parts.last, Int(word) != nil, Int(previous.split(separator: ".").last ?? "") != nil, previous.last?.isNumber == true {
                parts[parts.count - 1] = previous + "." + word
            } else {
                parts.append(word.prefix(1).uppercased() + word.dropFirst())
            }
        }
        return parts.joined(separator: " ")
    }

    func rememberModel(name: String, creator: String?, provider: ChatProvider, id: String) {
        let key = provider.rawValue + ":" + id
        var names = UserDefaults.standard.dictionary(forKey: Self.modelNamesKey) as? [String: String] ?? [:]
        names[key] = name
        UserDefaults.standard.set(names, forKey: Self.modelNamesKey)
        if let creator {
            var creators = UserDefaults.standard.dictionary(forKey: Self.modelCreatorsKey) as? [String: String] ?? [:]
            creators[key] = creator
            UserDefaults.standard.set(creators, forKey: Self.modelCreatorsKey)
        }
    }

    func selectModel(_ id: String) {
        if let chosen = availableModels.first(where: { $0.id == id }) {
            rememberModel(name: ModelIdentity.displayName(chosen, via: selectedProvider), creator: nil, provider: selectedProvider, id: id)
        }
        selectedModelID = id
        // The current conversation can have a different route from global defaults.
        // Persist the pair atomically, including when selectProvider was a no-op.
        settings.selectedProvider = selectedProvider
        settings.selectedModelID = id.isEmpty ? nil : id
        showModelPicker = false
        Task { await persistSettings() }
    }

    func isFavoriteModel(_ id: String, provider: ChatProvider) -> Bool {
        let identity = ModelRouting.identity(id, provider: provider)
        return (settings.favoriteModels ?? []).contains { ModelRouting.identity($0.modelID, provider: $0.provider) == identity }
    }

    func toggleFavoriteModel(_ item: ChatModel, provider: ChatProvider) async {
        do {
            try prepareAccountPreferenceScope()
            let owner = memoryOwner
            let favorite = try FavoriteModel(provider: provider, modelID: item.id, name: item.name)
            let previous = settings.favoriteModels
            let identity = ModelRouting.identity(item.id, provider: provider)
            let matching = (previous ?? []).filter { ModelRouting.identity($0.modelID, provider: $0.provider) == identity }
            let updated = matching.isEmpty ? try FavoriteModel.toggling(favorite, in: previous ?? []) : (previous ?? []).filter { ModelRouting.identity($0.modelID, provider: $0.provider) != identity }
            settings.favoriteModels = updated
            do { try persistAccountPreferenceScope(); try await settingsRepository.save(settings) }
            catch {
                if memoryOwner == owner, settings.favoriteModels == updated { settings.favoriteModels = previous; try? persistAccountPreferenceScope() }
                throw error
            }
        } catch { alertMessage = error.localizedDescription }
    }

    func setAddedModel(modelID: String, provider: ChatProvider, added: Bool) async throws {
        try prepareAccountPreferenceScope()
        let owner = accountPreferenceScopeOwner
        let previous = RemoteModelCatalogMetadata.additions()
        try RemoteModelCatalogMetadata.setAdded(modelID: modelID, provider: provider, added: added)
        do { try persistAccountPreferenceScope() }
        catch {
            if accountPreferenceScopeOwner == owner { try? RemoteModelCatalogMetadata.replaceAdditions(previous) }
            throw error
        }
        await synchronizeAccountChat()
    }
    func toggleAddedModel(_ item: ChatModel, provider: ChatProvider) async {
        do {
            try prepareAccountPreferenceScope()
            let selected = ModelRouting.canonicalIdentity(item.id, provider: provider)
            let alreadyAdded = RemoteModelCatalogMetadata.additions().contains { entry in
                guard let colon = entry.firstIndex(of: ":"), let route = ChatProvider(rawValue: String(entry[..<colon])) else { return false }
                return ModelRouting.canonicalIdentity(String(entry[entry.index(after: colon)...]), provider: route) == selected
            }
            try await setAddedModel(modelID: item.id, provider: provider, added: !alreadyAdded)
        } catch { alertMessage = error.localizedDescription }
    }

    func searchConversationHits(_ query: String) async -> [ConversationSearchHit] {
        do {
            let hits = try await conversationRepository.searchHits(query, limit: 100)
            var result: [ConversationSearchHit] = []
            for hit in hits where (hit.conversation.mode == .code) == (mode == .code) {
                if try await !conversationRepository.messages(conversationID: hit.conversation.id).isEmpty { result.append(hit) }
            }
            return result
        }
        catch { return [] }
    }

    func openSearchHit(_ hit: ConversationSearchHit) async {
        await selectConversation(hit.conversation.id)
        guard selectedConversationID == hit.conversation.id, !isLoadingConversation,
              let id = hit.messageID, messages.contains(where: { $0.id == id }) else { return }
        searchTargetMessageID = id
    }

    func savePersonalization(_ value: Personalization, expectedOwner: AccountMemoryOwner? = nil) async throws {
        try value.validate()
        if let expectedOwner { guard expectedOwner == memoryOwner else { throw AccountServiceError.conflict } }
        try prepareAccountPreferenceScope()
        let owner = memoryOwner
        let previous = settings.personalization
        settings.personalization = value
        do { try persistAccountPreferenceScope(); try await settingsRepository.save(settings) }
        catch {
            if memoryOwner == owner, settings.personalization == value { settings.personalization = previous; try? persistAccountPreferenceScope() }
            throw error
        }
    }

    func conversationExport(_ id: UUID) async throws -> ConversationExport {
        guard !isSending, responseSaveError == nil, assistantSaveTask == nil,
              let conversation = try await conversationRepository.conversation(id: id) else { throw ExportError.unavailable }
        let history = try await conversationRepository.messages(conversationID: id)
        guard !isSending, responseSaveError == nil, assistantSaveTask == nil else { throw ExportError.unavailable }
        return try ConversationExport(conversation: conversation, messages: history)
    }

    var canBranchConversation: Bool {
        responseSaveError == nil && assistantSaveTask == nil && !isSending && !isLoadingConversation && !isBranchingConversation && !isImportingAttachment && !isImportingProjectDocument && !isShuttingDown
        && composerText.isEmpty && pendingAttachments.isEmpty && pendingImages.isEmpty
    }

    var canRegenerateChatResponse: Bool {
        canBranchConversation && mode == .chat && hasProviderKey && !selectedModelID.isEmpty
    }

    func canRegenerateChatResponse(after assistant: ConversationMessage) -> Bool {
        guard canRegenerateChatResponse, assistant.role == .assistant,
              assistant.conversationID == selectedConversationID,
              let index = messages.firstIndex(where: { $0.id == assistant.id }), index > 0 else { return false }
        return messages[index - 1].role == .user
    }

    /// Regenerate into an independent branch. In particular, do not append the
    /// copied user prompt again or replay Code/Agent tool effects.
    func regenerateChatResponse(after assistant: ConversationMessage) async {
        guard canRegenerateChatResponse(after: assistant),
              let index = messages.firstIndex(where: { $0.id == assistant.id }) else { return }
        let prompt = messages[index - 1]
        let navigation = navigationID
        let identity = account.identity
        let capturedScope = account.credentialScope.snapshot()
        let provider = selectedProvider
        let modelID = selectedModelID
        let personalization = settings.personalization
        let memoryEnabled = settings.memoryEnabled != false
        let outputTokens = provider == .anthropic ? settings.anthropicOutputTokensByModel?[modelID] : nil
        let reasoningEffort = reasoningEffort(provider: provider, modelID: modelID)
        isBranchingConversation = true
        pendingSends += 1
        defer {
            isBranchingConversation = false
            pendingSends -= 1
            if pendingSends == 0 {
                let waiters = sendWaiters
                sendWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            guard let source = try await conversationRepository.conversation(id: assistant.conversationID),
                  source.mode == .chat else { return }
            if provider == .deepSeek {
                let history = try await conversationRepository.messages(conversationID: source.id)
                guard !history.prefix(while: { $0.id != prompt.id }).contains(where: { !($0.images ?? []).isEmpty }),
                      (prompt.images ?? []).isEmpty else {
                    alertMessage = ImageAttachmentError.unsupportedProvider.localizedDescription
                    return
                }
            }
            var branch = try await conversationRepository.branch(conversationID: source.id, at: prompt.id, includingMessage: true)
            guard account.identity == identity, let identity else { throw CredentialScopeError.changed }
            try await accountChatSync.markOwned(branch.id, identity: identity)
            branch.provider = provider
            branch.modelID = modelID
            try await conversationRepository.save(branch)
            guard navigationID == navigation, selectedConversationID == source.id, !isShuttingDown else { return }
            try await reloadConversations()
            guard navigationID == navigation, selectedConversationID == source.id, !isShuttingDown else { return }
            await selectConversation(branch.id)
            guard selectedConversationID == branch.id, !isLoadingConversation, composerText.isEmpty,
                  pendingAttachments.isEmpty, pendingImages.isEmpty, messages.last?.role == .user,
                  selectedProvider == provider, selectedModelID == modelID else { return }
            let conversationID = branch.id
            let sequence = (messages.last?.sequence ?? -1) + 1
            activeToolName = nil
            completedToolCount = 0
            toolProgress = ToolProgressWindow()
            toolRunProvider = nil
            toolRunConversationID = conversationID
            toolRunModelID = modelID
            isSending = true
            activeTurnConversationID = conversationID
            draftAssistantMessage = ConversationMessage(conversationID: conversationID, role: .assistant, content: "", sequence: sequence)
            startDraftTimeline()
            lastTranscriptUpdate = .distantPast
            do {
                guard account.credentialScope.snapshot() == capturedScope else { throw CredentialScopeError.changed }
                try await ProfileScopedCredentialStore.$requiredOwnerID.withValue(identity.storageID) {
                try await aimEngine.send(AgentRequest(conversationID: conversationID, text: prompt.content,
                    modelID: modelID, mode: .chat, provider: provider, personalization: personalization,
                    anthropicOutputTokens: outputTokens, openAIReasoningEffort: reasoningEffort,
                    memoryEnabled: memoryEnabled))
                }
            } catch {
                guard activeTurnConversationID == conversationID else { return }
                draftAssistantMessage?.completionStatus = .failed
                await persistDraft(conversationID: conversationID)
                activeTurnConversationID = nil
                isSending = false
                alertMessage = error.localizedDescription
            }
        } catch {
            if navigationID == navigation { alertMessage = error.localizedDescription }
        }
    }

    func branchConversation(at message: ConversationMessage, edit: Bool) async {
        guard canBranchConversation, message.conversationID == selectedConversationID,
              messages.contains(where: { $0.id == message.id }), !edit || message.role == .user else { return }
        let navigation = navigationID
        let identity = account.identity
        isBranchingConversation = true
        defer { isBranchingConversation = false }
        do {
            let branch = try await conversationRepository.branch(conversationID: message.conversationID,
                                                                 at: message.id, includingMessage: !edit)
            guard account.identity == identity, let identity else { throw CredentialScopeError.changed }
            try await accountChatSync.markOwned(branch.id, identity: identity)
            try await reloadConversations()
            guard navigationID == navigation, composerText.isEmpty, pendingAttachments.isEmpty, pendingImages.isEmpty else { return }
            await selectConversation(branch.id)
            guard selectedConversationID == branch.id, !isLoadingConversation, composerText.isEmpty, pendingAttachments.isEmpty, pendingImages.isEmpty else { return }
            composerText = edit ? message.content : ""
            pendingAttachments = edit ? message.attachments ?? [] : []
            pendingImages = edit ? message.images ?? [] : []
        } catch { if navigationID == navigation { alertMessage = error.localizedDescription } }
    }

    /// The usage shown in the gauge, measured against the model chosen now (it may have changed).
    var displayedContextUsage: ContextUsage? {
        let limit = currentContextLimit
        guard var usage = contextUsage else { return ContextUsage(limit: limit) }
        if let limit {
            usage.limit = limit
            usage.autoCompactAt = (SessionCompactionContext.triggerBytes(contextLength: limit) + 3) / 4
        }
        return usage
    }

    /// The selected model's context window: the catalog's, or the local model's own setting.
    var currentContextLimit: Int? {
        if selectedProvider == .local {
            return builtInModelFile(selectedModelID).map { Self.localLaunch(name: selectedModelID, file: $0).contextTokens }
                ?? availableModels.first { $0.id == selectedModelID }?.contextLength
        }
        return modelInfo(provider: selectedProvider, modelID: selectedModelID)?.contextLength
            ?? availableModels.first { $0.id == selectedModelID }?.contextLength
    }

    /// Before any measured turn: the conversation's own messages (and summary) against the model's window.
    func estimatedContextUsage(_ messages: [ConversationMessage], checkpoint: SessionCompaction?) -> ContextUsage {
        let history = (try? SessionCompactionContext.requestHistory(messages, checkpoint: checkpoint)) ?? messages
        let limit = currentContextLimit
        return ContextUsage.estimate(messages: history, limit: limit,
                                     autoCompactBytes: SessionCompactionContext.triggerBytes(contextLength: limit))
    }

    /// "Compact the session": the conversation's model summarizes everything but the last two
    /// exchanges, as Claude's /compact does; the original messages stay in the history.
    func compactConversation() async {
        guard let id = selectedConversationID, !isSending, !isCompacting,
              let conversation = conversations.first(where: { $0.id == id }) else { return }
        let provider = conversation.provider ?? selectedProvider
        let modelID = conversation.modelID ?? selectedModelID
        isCompacting = true
        defer { isCompacting = false }
        do {
            let key: String
            if provider == .local {
                guard await ensureBuiltInModelLoaded() else { return }
                key = "local"
            } else {
                guard let data = try await providerKeyData(provider), let stored = String(data: data, encoding: .utf8),
                      !stored.isEmpty else { throw ChatServiceError.missingKey }
                key = stored
            }
            let history = try await conversationRepository.messages(conversationID: id)
            _ = try await SessionCompactionService(repository: compactionRepository, chatService: ProviderChatService(meter: spendMeter))
                .prepare(history, conversationID: id, provider: provider, modelID: modelID, apiKey: key,
                         contextLength: currentContextLimit, force: true)
            let checkpoint = try await compactionRepository.load(conversationID: id)
            guard selectedConversationID == id else { return }
            compactedThroughSequence = checkpoint?.throughSequence
            // Keep the fixed parts (instructions, tools, memory…) and recount the conversation itself.
            var usage = estimatedContextUsage(history, checkpoint: checkpoint)
            if let previous = contextUsage {
                for part in ContextUsage.Part.allCases where ![.messages, .summary, .attachments].contains(part) {
                    usage.parts[part.rawValue] = previous.tokens(part)
                }
            }
            contextUsage = usage
            try? await metricsRepository.saveContextUsage(usage, conversationID: id)
        } catch { alertMessage = error.localizedDescription }
    }

    enum SpendWindow: String, CaseIterable { case daily, weekly, monthly }

    struct SpendOverview: Equatable {
        var conversationUSD: Double = 0
        var conversationEstimated = false
        var periodUSD: Double = 0
        var periodEstimated = false
        /// The spending limit, when one is on.
        var limitUSD: Double?
        var limitUsedUSD: Double = 0
        var limitPeriodName: String?
        var limitResetsAt: Date?
    }

    /// Spend for the context popover: this conversation, the chosen period, and the limit.
    func spendOverview(period: SpendWindow) async -> SpendOverview {
        var overview = SpendOverview()
        if let id = selectedConversationID, let value = try? await metricsRepository.conversationSpend(id) {
            overview.conversationUSD = value.usd; overview.conversationEstimated = value.estimated
        }
        let calendar = Calendar.current
        let start: Date
        switch period {
        case .daily: start = calendar.startOfDay(for: .now)
        case .weekly: start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? calendar.startOfDay(for: .now)
        case .monthly: start = calendar.dateInterval(of: .month, for: .now)?.start ?? calendar.startOfDay(for: .now)
        }
        if let value = try? await metricsRepository.spend(since: start) {
            overview.periodUSD = value.usd; overview.periodEstimated = value.estimated
        }
        if let snapshot = try? await spendLedger.snapshot(), snapshot.policy.enabled,
           let limit = snapshot.policy.limitUSD.flatMap(Double.init), limit > 0 {
            overview.limitUSD = limit
            overview.limitUsedUSD = Double(snapshot.countedUSD) ?? 0
            overview.limitResetsAt = snapshot.periodEnd
            switch snapshot.policy.period {
            case .day: overview.limitPeriodName = "Daily limit"
            case .calendarMonth: overview.limitPeriodName = "Monthly limit"
            case .envelope: overview.limitPeriodName = "Budget"
            }
        }
        return overview
    }

    func markRead(_ id: UUID) {
        guard (account.accessUser?.id == nil || conversationContinuityAccountMatches), selectedConversationID == id, NSApplication.shared.isActive,
              let window = NSApplication.shared.keyWindow, window.isVisible, !window.isMiniaturized,
              settingsSection == nil, !projectPageVisible else { return }
        let visibleResponse = account.accessUser?.id == nil ? knownLegacyReads[id]?.response : conversationResponseVersions[id]
        guard messages.contains(where: { $0.role == .assistant && $0.completionStatus == nil && !$0.content.isEmpty && (visibleResponse == nil || $0.id.uuidString.lowercased() == visibleResponse?.id) }) else { return }
        let now = Date.now
        lastReadAt[id] = now
        Task { try? await metricsRepository.markRead(conversationID: id, at: now) }
        if let legacy = knownLegacyReads[id], messages.contains(where: { $0.id.uuidString.lowercased() == legacy.response.id }) {
            knownLegacyReads[id]?.lastReadAt = now
        }
        // Only the loaded answer is acknowledged. A future response has a different identity.
        guard let owner = account.accessUser?.id, readReceiptAccountID == owner,
              let response = conversationResponseVersions[id], selectedConversationID == id,
              messages.contains(where: { $0.role == .assistant && $0.id.uuidString.lowercased() == response.id && $0.completionStatus == nil }),
              NSApplication.shared.isActive, !accountReadReceipts.contains(conversationID: id.uuidString, response: response) else { return }
        accountReadReceipts.acknowledge(conversationID: id.uuidString, response: response)
        Task { try? await accountChatSync.acknowledge(conversationID: id, response: response, accountID: owner); await synchronizeAccountReadReceipts() }
    }

    typealias ConversationStatus = ConversationActivityState

    /// The sidebar dot: running, a failed last answer, an answer not read yet, or nothing.
    func status(of conversation: Conversation) -> ConversationStatus {
        let running = activeTurnConversationID == conversation.id || debugRunningConversationID == conversation.id
        let waiting = pendingToolApprovals.contains { $0.sessionID == conversation.id } || pendingAgentQuestions.contains { $0.conversationID == conversation.id }
        let status = waiting ? "waiting_approval" : running ? "running" : failedConversations.contains(conversation.id) ? "failed" : "idle"
        return ConversationActivityState.resolve(status: status, latestResponse: account.accessUser?.id == nil ? knownLegacyReads[conversation.id]?.response : conversationContinuityAccountMatches ? conversationResponseVersions[conversation.id] : nil, read: !isUnread(conversation))
    }

    /// The conversation finished an answer the user has not opened yet.
    func isUnread(_ conversation: Conversation) -> Bool {
        if conversationContinuityAccountMatches, let response = conversationResponseVersions[conversation.id] {
            return !accountReadReceipts.contains(conversationID: conversation.id.uuidString, response: response)
        }
        guard account.accessUser?.id == nil else { return false }
        return knownLegacyReads[conversation.id].map { !$0.wasRead } ?? false
    }

    func loadReadState() async {
        lastReadAt = (try? await metricsRepository.lastRead()) ?? [:]
        knownLegacyReads = (try? await metricsRepository.knownLegacyReadState()) ?? [:]
        if let owner = account.accessUser?.id { try? await accountChatSync.restoreKnownLegacyReadState(accountID: owner) }
        failedConversations = (try? await metricsRepository.failedConversationIDs()) ?? []
    }

    /// The model's title replaces the first words of the request, never a title the user chose.
    private func applyGeneratedTitle(_ title: String, conversationID: UUID) async {
        awaitingTitle.remove(conversationID)
        guard let cleaned = ConversationTitleProtocol.clean(title),
              (try? await metricsRepository.titleSource(conversationID: conversationID)) != .user,
              var conversation = try? await conversationRepository.conversation(id: conversationID) else { return }
        conversation.title = cleaned
        do { try await conversationRepository.save(conversation) } catch { return }
        try? await metricsRepository.setTitleSource(.generated, conversationID: conversationID)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].title = cleaned
        }
    }

    /// One small request when the first answer came without a title (small models, an Agent
    /// that started with tools). Free for local models; at most once per conversation.
    private func generateFallbackTitle(conversationID: UUID) async {
        let captured = account.credentialScope.snapshot()
        guard let conversation = try? await conversationRepository.conversation(id: conversationID),
              let provider = conversation.provider, let modelID = conversation.modelID, !modelID.isEmpty,
              (try? await metricsRepository.titleSource(conversationID: conversationID)) == nil,
              let history = try? await conversationRepository.messages(conversationID: conversationID),
              let question = history.first(where: { $0.role == .user }) else { return }
        let answer = history.first { $0.role == .assistant }?.content ?? ""
        let key: String
        if provider == .local { key = "local" } else {
            guard let data = try? await providerKeyData(provider), let stored = String(data: data, encoding: .utf8), !stored.isEmpty else { return }
            key = stored
        }
        guard captured == account.credentialScope.snapshot() else { return }
        let prompt = "User: " + String(question.content.prefix(1_500)) + "\n\nAssistant: " + String(answer.prefix(800))
            + "\n\n" + ConversationTitleProtocol.fallbackInstruction
        let effort: OpenAIReasoningEffort? = provider == .local ? OpenAIReasoningEffort.none : nil
        var text = ""
        do {
            for try await part in ProviderChatService(meter: spendMeter).stream(provider: provider, modelID: modelID,
                messages: [ConversationMessage(conversationID: conversationID, role: .user, content: prompt, sequence: 0)],
                apiKey: key, mode: .chat, anthropicOutputTokens: provider == .anthropic ? 64 : nil, openAIReasoningEffort: effort,
                useWebSearch: false, billingFeature: "title") {
                text += part
                if text.count > 400 { break }
            }
        } catch { return }
        guard captured == account.credentialScope.snapshot() else { return }
        await applyGeneratedTitle(text, conversationID: conversationID)
    }

    func renameConversation(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            guard var conversation = try await conversationRepository.conversation(id: id) else { return }
            conversation.title = String(trimmed.prefix(160))
            try await conversationRepository.save(conversation)
            try? await metricsRepository.setTitleSource(.user, conversationID: id)
            awaitingTitle.remove(id)
            try await reloadConversations()
        } catch { alertMessage = error.localizedDescription }
    }

    func sideChatStream(messages: [ConversationMessage]) async throws -> AsyncThrowingStream<String, Error> {
        let provider = selectedProvider, modelID = selectedModelID
        let outputTokens = settings.anthropicOutputTokensByModel?[modelID]
        let reasoning = reasoningEffort(provider: provider, modelID: modelID)
        guard let data = try await providerKeyData(provider),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw ChatServiceError.missingKey }
        return ProviderChatService(meter: spendMeter).stream(provider: provider, modelID: modelID,
            messages: ProviderHistory.completedContext(messages), apiKey: key, mode: .chat,
            anthropicOutputTokens: outputTokens, openAIReasoningEffort: reasoning,
            billingFeature: "side-chat")
    }

    func copyConversation(_ id: UUID) async {
        do {
            let transcript = try await conversationRepository.messages(conversationID: id)
            let text = transcript.filter { $0.role == .user || $0.role == .assistant }.map {
                "## \($0.role == .user ? "You" : "AIM")\n\n\($0.content)"
            }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch { alertMessage = error.localizedDescription }
    }

    func setArchived(_ id: UUID, _ archived: Bool) async {
        guard id != activeTurnConversationID else {
            alertMessage = "Stop the response before archiving this conversation."
            return
        }
        do {
            guard var conversation = try await conversationRepository.conversation(id: id) else { return }
            conversation.isArchived = archived
            try await conversationRepository.save(conversation)
            if selectedConversationID == id { await newConversation() }
            try await reloadConversations()
            archivedConversations = try await conversationRepository.list(includeArchived: true).filter(\.isArchived)
        } catch { alertMessage = error.localizedDescription }
    }

    func setPinned(_ id: UUID, _ pinned: Bool) async {
        do {
            guard var conversation = try await conversationRepository.conversation(id: id) else { return }
            conversation.pinnedAt = pinned ? .now : nil
            try await conversationRepository.save(conversation)
            try await reloadConversations()
        } catch { alertMessage = error.localizedDescription }
    }

    func deleteConversation(_ id: UUID) async {
        guard id != activeTurnConversationID else {
            alertMessage = "Stop the response before deleting this conversation."
            return
        }
        do {
            try await conversationRepository.delete(id: id)
            if selectedConversationID == id { await newGeneralConversation() }
            try await reloadConversations()
        } catch { alertMessage = error.localizedDescription }
    }

    func loadArchives() async {
        do { archivedConversations = try await conversationRepository.list(includeArchived: true).filter(\.isArchived) }
        catch { alertMessage = error.localizedDescription }
    }

    func requestPermission(_ kind: MacPermissionKind) async {
        permissionStates[kind] = await permissions.request(kind)
    }

    func refreshPermissions() async {
        for kind in MacPermissionKind.allCases { permissionStates[kind] = await permissions.state(for: kind) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            settings.launchAtLogin = enabled
            Task { await persistSettings() }
        } catch { alertMessage = error.localizedDescription }
    }

    func virtualMachineControl(_ control: RuntimeVirtualMachineControl) async throws -> LocalVirtualMachineStatus {
        guard let continuityRuntime, let accountID = account.identity?.storageID else { throw AgentHostTransportError.disconnected }
        let response = try await continuityRuntime.send(AgentHostCommand(action: .virtualMachine, accountID: accountID, payload: JSONEncoder().encode(control)))
        return try JSONDecoder().decode(LocalVirtualMachineStatus.self, from: response)
    }

    func ambientAudioControl(_ control: RuntimeAmbientAudioControl) async throws -> RuntimeAmbientAudioSnapshot {
        guard let continuityRuntime, let accountID = account.identity?.storageID else { throw AgentHostTransportError.disconnected }
        let response = try await continuityRuntime.send(AgentHostCommand(action: .ambientAudio, accountID: accountID, payload: JSONEncoder().encode(control)))
        return try JSONDecoder().decode(RuntimeAmbientAudioSnapshot.self, from: response)
    }

    func peerControl(_ control: RuntimePeerControl) async throws -> Data {
        guard let continuityRuntime, let accountID = account.accessUser?.id else { throw AgentHostTransportError.disconnected }
        return try await continuityRuntime.send(AgentHostCommand(action: .peers, accountID: accountID, payload: RemotePeerCoding.encode(control)))
    }

    func channelControl(_ control: RuntimeChannelControl) async throws -> Data {
        guard let continuityRuntime, let accountID = account.identity?.storageID else { throw AgentHostTransportError.disconnected }
        return try await continuityRuntime.send(AgentHostCommand(action: .channels, accountID: accountID, payload: JSONEncoder().encode(control)))
    }

    func storeChannelToken(_ token: String, key: String) throws {
        guard account.identity != nil, key.hasPrefix("channel.telegram."), key.count <= 160,
              key.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }),
              token.count <= 512, !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw RuntimeChannelError.invalidConfiguration }
        try providerStore.store(Data(token.utf8), forKey: key)
    }

    func setActivitySettings(_ activity: ActivitySettings) {
        let wasEnabled = settings.activity.isEnabled
        let previousRetention = settings.activity.retentionDays
        settings.activity = ActivitySettings(
            isEnabled: activity.isEnabled,
            retentionDays: activity.retentionDays,
            excludedApplications: activity.excludedApplications,
            excludedDomains: activity.excludedDomains
        )
        if previousRetention != settings.activity.retentionDays {
            activityTask?.cancel()
            Task {
                await activityTracker.discard()
                if await purgeActivity(now: .now), settings.activity.isEnabled { configureActivityTracking() }
            }
        } else if wasEnabled != settings.activity.isEnabled {
            configureActivityTracking()
        }
        Task { await persistSettings(); await loadActivityEntries() }
    }

    func prepareActivitySuggestion(_ suggestion: ActivitySuggestion) {
        guard !RuntimePrivacyPolicy.isEnabled, settings.activity.isEnabled,
              let current = ActivitySuggestion.proposals(entries: activityEntries, settings: settings.activity).first(where: { $0.id == suggestion.id }) else { return }
        // Preserve the user's current draft and attachments. Never auto-send.
        composerText += (composerText.isEmpty ? "" : "\n\n") + current.draft
    }

    func loadActivityEntries() async {
        do {
            let loaded = try await activityRepository.search("", since: nil, until: nil, limit: 200)
            activityEntries = loaded.filter { !ActivityPrivacyPolicy.shouldExclude(application: $0.application, title: $0.title, url: $0.url, isPrivate: false, settings: settings.activity) }
            activityError = nil
        } catch { activityError = "Could not read the local activity journal." }
    }

    func clearActivityEntries() async {
        await activityTracker.discard()
        do {
            _ = try await activityRepository.purge(olderThan: .distantFuture)
            activityEntries = []
            activityError = nil
        } catch { activityError = "Could not clear the local activity journal." }
    }

    @discardableResult
    private func purgeActivity(now: Date) async -> Bool {
        let days = min(max(settings.activity.retentionDays, 1), 30)
        do {
            _ = try await activityRepository.purge(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
            activityError = nil
            return true
        } catch {
            activityError = "Could not apply the activity retention period. Activity recording remains stopped."
            return false
        }
    }

    private func configureActivityTracking() {
        activityTask?.cancel()
        let taskID = UUID()
        activityTaskID = taskID
        guard settings.activity.isEnabled else {
            activityTask = nil
            Task { await activityTracker.discard() }
            return
        }
        activityTask = Task { [weak self] in
            guard let self else { return }
            var nextPurge = Date.distantPast
            while !Task.isCancelled {
                do {
                    let now = Date.now
                    if now >= nextPurge {
                        guard await purgeActivity(now: now) else { break }
                        nextPurge = now.addingTimeInterval(86_400)
                    }
                    if settings.continuity?.permanent == true {
                        await activityTracker.discard()
                    } else {
                        try await activityTracker.tick(settings: settings.activity, now: now)
                    }
                    try await Task.sleep(for: .seconds(5))
                } catch is CancellationError { break }
                catch {
                    activityError = "The local activity journal stopped after a storage error."
                    break
                }
            }
            if activityTaskID == taskID { activityTask = nil }
        }
    }

    var updateSidebarTitle: LocalizedStringResource? {
        Self.updateSidebarTitle(for: updateController.state)
    }
    static func updateSidebarTitle(for state: MacUpdateController.State) -> LocalizedStringResource? {
        switch state {
        case .unavailable, .checking: nil
        case .available: LocalizedStringResource("Update available", bundle: .atURL(Bundle.module.bundleURL))
        }
    }
    func checkForUpdates() { updateController.checkForUpdates() }

    func prepareForTermination() async -> Bool {
        guard flushComposer() else { return false }
        isShuttingDown = true
        await directRemote?.stop(); directRemote = nil
        let installations = Array(agentInstallTasks.values)
        for task in installations { task.cancel() }
        for task in installations { await task.value }
        voiceSession?.stop()
        voiceSession = nil
        await stopRemoteHost()
        await BuiltInLocalEngine.shared.stop()
        LocalModelRuntime.stopStartedServers()
        await cuaDriverDiagnostics.stop()
        await MCPServerManager.shared.closeAll()
        triggerMonitor?.stopAll()
        await taskScheduler?.stop()
        cancelImageGeneration()
        _ = await imageGenerationTask?.result
        _ = await mediaGenerationTask?.result
        let memoryTasks = memoryCaptureTasks.values.map(\.1)
        for task in memoryTasks { task.cancel() }
        for task in memoryTasks { await task.value }
        memoryCaptureTasks.removeAll()
        if pendingSends > 0 {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        let listeners = Array(eventTasks.values)
        for listener in listeners { listener.cancel() }
        eventTasks.removeAll()
        if let continuityRuntime {
            await aimEngine.detach()
            if settings.continuity?.permanent != true { try? await continuityRuntime.shutdownIntegrated() }
            continuityTask?.cancel(); continuityTask = nil
        } else { await aimEngine.stop() }
        for id in AgentEngineID.allCases where id != .aim {
            if let engine = await engineRegistry.engine(id) {
                if continuityRuntime != nil, let coordinated = engine as? NativeAIMEngine { await coordinated.detach() }
                else { await engine.stop() }
            }
        }
        for listener in listeners { await listener.value }
        if let id = draftAssistantMessage?.conversationID, !(await persistDraft(conversationID: id)) {
            isShuttingDown = false
            await listenToEngine()
            return false
        }
        activityTask?.cancel()
        if settings.activity.isEnabled { try? await activityTracker.stop() }
        else { await activityTracker.discard() }
        activeTurnConversationID = nil
        isSending = false
        activeToolName = nil
        toolProgress.interruptRunning()
        approvalTask?.cancel()
        await spendExceptions.close()
        spendExceptionTask?.cancel()
        questionTask?.cancel()
        pendingToolApprovals = []
        pendingSpendExceptions = []
        pendingAgentQuestions = []
        return true
    }

    // Old interrupted sends may have persisted a conversation before its first message.
    // Hide those records without destroying any saved drafts or attachments.
    /// What the connected OpenRouter key has spent, and its limit if one is set (`/api/v1/key`).
    func openRouterKeyUsage() async -> (usage: Double, limit: Double?)? {
        guard connectedProviders.contains(.openRouter),
              let data = try? await providerKeyData(.openRouter), let key = String(data: data, encoding: .utf8) else { return nil }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (body, response) = try? await RuntimeManagedNetworkSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["data"] as? [String: Any],
              let usage = (info["usage"] as? NSNumber)?.doubleValue else { return nil }
        return (usage, (info["limit"] as? NSNumber)?.doubleValue)
    }

    /// Adds conversations exported from ChatGPT or Claude as Chat conversations (text only).
    func importChats(_ chats: [ChatExportReader.Conversation]) async throws -> Int {
        var imported = 0
        for chat in chats where !chat.messages.isEmpty {
            let conversation = Conversation(title: String(chat.title.prefix(120)), mode: .chat)
            try await conversationRepository.save(conversation)
            for (index, message) in chat.messages.prefix(2_000).enumerated() {
                try await conversationRepository.append(ConversationMessage(
                    conversationID: conversation.id, role: message.isUser ? .user : .assistant,
                    content: String(message.text.prefix(200_000)), sequence: index, createdAt: chat.createdAt ?? .now))
            }
            imported += 1
        }
        conversations = try await nonemptyConversations()
        return imported
    }

    private func nonemptyConversations() async throws -> [Conversation] {
        let stored = try await conversationRepository.list(includeArchived: false)
        var result: [Conversation] = []
        for conversation in stored {
            guard try await accountChatSync.isVisible(conversation.id, identity: account.identity) else { continue }
            if try await !conversationRepository.messages(conversationID: conversation.id).isEmpty {
                result.append(conversation)
            }
        }
        return result
    }

    private func visibleProjects() async throws -> [AIMApplication.AIMProject] {
        var result: [AIMApplication.AIMProject] = []
        for project in try await projectRepository.list() {
            if try await accountChatSync.isVisible(project.id, identity: account.identity) { result.append(project) }
        }
        return result
    }

    func openProjects(_ id: UUID? = nil) async {
        guard !isSending, !isShuttingDown else { return }
        guard await selectProject(id) else { return }
        settingsSection = nil
        projectPageVisible = true
    }

    func refreshAccountActivity() async { await synchronizeAccountChat() }

    var automaticWebSearch: Bool { accountChatPreferences.automaticWebSearch != false }
    func setAutomaticWebSearch(_ enabled: Bool) {
        do {
            try prepareAccountPreferenceScope()
            accountChatPreferences.automaticWebSearch = enabled
            try persistAccountPreferenceScope()
            Task { await persistSettings(); await synchronizeAccountChat() }
        } catch { alertMessage = error.localizedDescription }
    }

    var researchMode: AIMResearchMode { accountChatPreferences.resolvedResearchMode }
    func setResearchMode(_ mode: AIMResearchMode) {
        do {
            try prepareAccountPreferenceScope()
            accountChatPreferences.researchMode = mode
            try persistAccountPreferenceScope()
            Task { await persistSettings(); await synchronizeAccountChat() }
        } catch { alertMessage = error.localizedDescription }
    }
    func saveResearchAPIKey(_ value: String, mode: AIMResearchMode) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode.isOrchestrated, !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: \.isWhitespace), !key.contains("\0") else { throw AIMResearchError.missingKey }
        try providerStore.boundToCurrentScope().store(Data(key.utf8), forKey: mode.credentialKey)
    }
    func removeResearchAPIKey(mode: AIMResearchMode) throws {
        guard mode.isOrchestrated else { return }
        try providerStore.boundToCurrentScope().removeData(forKey: mode.credentialKey)
    }

    private func synchronizeAccountReadReceipts() async {
        guard let owner = account.accessUser?.id, let client = account.supabaseClient else {
            readReceiptAccountID = nil; accountReadReceipts = .init(); conversationResponseVersions = [:]; conversationExecutionDevices = [:]; return
        }
        if readReceiptAccountID != owner {
            readReceiptAccountID = owner; accountReadReceipts = .init(); conversationResponseVersions = [:]; conversationExecutionDevices = [:]
            try? await accountChatSync.restoreKnownLegacyReadState(accountID: owner)
            if let cached = try? await accountChatSync.continuityState(accountID: owner), account.accessUser?.id == owner {
                accountReadReceipts = cached.receipts; conversationResponseVersions = cached.responseVersions; conversationExecutionDevices = cached.executionDeviceIDs
            }
        }
        do {
            let value = try await accountChatSync.synchronizeReadReceipts(accountID: owner, service: AccountContentSyncService(client: client), currentAccount: { [weak account] in await account?.accessUser?.id })
            guard account.accessUser?.id == owner else { return }
            accountReadReceipts = accountReadReceipts.merging(value.receipts)
            for (id, response) in value.responseVersions where conversationResponseVersions[id] == nil || conversationResponseVersions[id]!.completedAt <= response.completedAt { conversationResponseVersions[id] = response }
            for (id, devices) in value.executionDeviceIDs { conversationExecutionDevices[id] = Array(Set((conversationExecutionDevices[id] ?? []) + devices)).sorted() }
            if let selectedConversationID { markRead(selectedConversationID) }
        } catch { /* Local acknowledgements are retained for the next account sync. */ }
    }

    private func synchronizeAccountChat() async {
        guard didStart, !isShuttingDown, accountPreferenceScopeReady, let accountID = account.accessUser?.id, let client = account.supabaseClient else { return }
        do { try prepareAccountPreferenceScope() }
        catch { accountSyncMessage = "Account preferences could not be loaded safely. Previous settings are preserved."; return }
        do {
            let localRecords = try await accountActivityRepository.records(accountID: accountID)
            guard account.accessUser?.id == accountID else { return }
            accountActivityRecords = localRecords
            let records = try await accountActivityRepository.synchronize(accountID: accountID, service: AccountContentSyncService(client: client))
            guard account.accessUser?.id == accountID else { return }
            accountActivityRecords = records; accountActivitySyncedAt = .now; accountActivityError = nil
        } catch { if account.accessUser?.id == accountID { accountActivityError = "Account activity could not sync. Recorded data is kept on this Mac." } }
        await synchronizeAccountReadReceipts()
        guard account.accessUser?.id == accountID, !isSending else { return }
        if settingsSection == .personalization { await loadMemories() }
        let favorites = Set((settings.favoriteModels ?? []).map { $0.provider.rawValue + ":" + $0.modelID })
        let additions = Set(RemoteModelCatalogMetadata.additions())
        var preferences = accountChatPreferences
        preferences.customInstructions = settings.personalization?.isEnabled == true ? settings.personalization?.instructions : nil
        do {
            let result = try await accountChatSync.synchronize(accountID: accountID, service: AccountContentSyncService(client: client), favorites: favorites, preferences: preferences, addedModels: additions,
                currentAccount: { [weak account] in await account?.accessUser?.id })
            guard account.accessUser?.id == accountID, !isSending else { return }
            settings.favoriteModels = result.favorites.compactMap { entry in
                let parts = entry.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let provider = ChatProvider(rawValue: String(parts[0])) else { return nil }
                return try? FavoriteModel(provider: provider, modelID: String(parts[1]), name: String(parts[1]))
            }
            let latestAdditions = Set(RemoteModelCatalogMetadata.additions())
            let mergedAdditions = result.addedModels.union(latestAdditions.subtracting(additions)).subtracting(additions.subtracting(latestAdditions))
            try RemoteModelCatalogMetadata.replaceAdditions(mergedAdditions.sorted())
            accountChatPreferences = result.preferences
            for (target, value) in result.preferences.subagentDefaults ?? [:] {
                try SubagentPreferenceStore.save(value, accountID: accountID, target: target)
            }
            if result.preferences.customInstructions != nil || settings.personalization?.isEnabled != false {
                settings.personalization = .init(isEnabled: result.preferences.customInstructions?.isEmpty == false, instructions: result.preferences.customInstructions ?? "")
            }
            await persistSettings()
            if result.changed {
                try await reloadConversations(); projects = try await visibleProjects()
                if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                    self.selectedProjectID = nil
                    alertMessage = "This project was deleted on another device. Its conversations, your draft and local source files have been preserved."
                }
            }
            await synchronizeAccountReadReceipts()
            accountSyncMessage = nil
        } catch { accountSyncMessage = error.localizedDescription }
    }

    func projectRuntimeActivity(_ messages: [ConversationMessage]) async throws -> [ConversationMessage] {
        try await RuntimeConversationActivity.apply(repository: SQLiteAgentExecutionRepository(database: database), to: messages)
    }

    private func reloadConversations(select id: UUID? = nil) async throws {
        let navigation = navigationID
        if lastReadAt.isEmpty { await loadReadState() }
        conversations = try await nonemptyConversations()
        guard navigationID == navigation else { return }
        if let id { await selectConversation(id) }
    }

    private func listenToEngine() async {
        for listener in eventTasks.values { listener.cancel() }
        eventTasks.removeAll()
        for id in AgentEngineID.allCases {
            guard let engine = await engineRegistry.engine(id) else { continue }
            let events = await engine.events()
            eventTasks[id] = Task { [weak self] in
                guard let self else { return }
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await handle(event)
                }
            }
        }
    }

    func handle(_ event: EngineEvent) async {
        switch event {
        case let .planUpdated(plan):
            if selectedConversationID == plan.conversationID { agentPlan = plan }
        case let .contextCompacted(conversationID, throughSequence):
            if selectedConversationID == conversationID { compactedThroughSequence = throughSequence }
            if activeTurnConversationID == conversationID { toolProgress.markCompacted() }
        case let .runStage(conversationID, stage):
            if activeTurnConversationID == conversationID {
                toolProgress.setStage(stage)
                if var assistant = draftAssistantMessage, assistant.conversationID == conversationID {
                    let actionID = assistant.id.uuidString + ":network"
                    var actions = assistant.actions ?? []
                    if stage == .waitingForNetwork {
                        if let index = actions.firstIndex(where: { $0.id == actionID }) {
                            actions[index].state = .waiting; actions[index].finishedAt = nil
                        } else {
                            actions.append(.init(id: actionID, conversationID: conversationID, turnID: assistant.id,
                                ordinal: actions.count, name: "network", state: .waiting, startedAt: .now,
                                detail: "Waiting for network before submission. Cancel stops waiting; the selected target and model are retained."))
                        }
                    } else if let index = actions.firstIndex(where: { $0.id == actionID && $0.state == .waiting }) {
                        actions[index].state = .completed; actions[index].finishedAt = .now
                    }
                    assistant.actions = actions.isEmpty ? nil : actions
                    draftAssistantMessage = assistant
                    if stage == .waitingForNetwork { recordTimeline(conversationID) { $0.action(actionID) } }
                    updateVisibleDraft()
                }
                if stage == .waitingForModel, selectedConversationID == conversationID {
                    if let latest = try? await missionRepository.latest(conversationID: conversationID) {
                        if agentMission?.id != latest.id {
                            missionAuthorization = try? await missionRepository.authorization(missionID: latest.id)
                        }
                        agentMission = latest
                    }
                }
            }
        case let .textDelta(conversationID, text):
            guard draftAssistantMessage?.conversationID == conversationID else { return }
            recordTimeline(conversationID) { $0.text(text) }
            draftAssistantMessage?.content += text
            if Date.now.timeIntervalSince(lastTranscriptUpdate) >= 0.05 {
                updateVisibleDraft()
                lastTranscriptUpdate = .now
            }
        case let .reasoningDelta(conversationID, text):
            guard draftAssistantMessage?.conversationID == conversationID else { return }
            recordTimeline(conversationID) { $0.reasoning(text) }
            if Date.now.timeIntervalSince(lastTranscriptUpdate) >= 0.05 {
                updateVisibleDraft()
                lastTranscriptUpdate = .now
            }
        case let .contextUsage(conversationID, usage):
            turnContextUsage[conversationID] = usage
            if selectedConversationID == conversationID { contextUsage = usage }
            try? await metricsRepository.saveContextUsage(usage, conversationID: conversationID)
        case let .routeAttempt(conversationID, attempt):
            // Read, change, then write back once: `draft?.x = f(draft?.x)` reads the property while
            // its write access is open, which Swift's exclusivity checks stop with a crash.
            guard var assistant = draftAssistantMessage, assistant.conversationID == conversationID else { return }
            assistant.routeAttempts = ConversationRouteAttempt.merge(assistant.routeAttempts, [attempt])
            draftAssistantMessage = assistant
            if attempt.ordinal > 0 {
                let id = assistant.id.uuidString + ":route:" + String(attempt.ordinal)
                var action = assistant.actions?.first(where: { $0.id == id }) ?? ConversationAction(id: id, conversationID: conversationID, turnID: assistant.id, ordinal: assistant.actions?.count ?? 0, name: "Provider · " + attempt.provider.name, state: .running, input: attempt.modelID)
                action.state = attempt.state == .trying ? .running : attempt.state == .accepted ? .completed : attempt.state == .rejected ? .failed : .needsReview
                if attempt.state != .trying { action.finishedAt = .now }
                assistant.actions = ConversationAction.merge(assistant.actions, [action]); draftAssistantMessage = assistant
            }
            updateVisibleDraft()
        case let .turnMetrics(conversationID, metrics):
            if var usage = turnContextUsage.removeValue(forKey: conversationID), let input = metrics.usage.inputTokens {
                // The provider's count: this prompt plus the answer, which the next turn will carry.
                usage.reportedTotal = input + metrics.outputTokens
                if selectedConversationID == conversationID { contextUsage = usage }
                try? await metricsRepository.saveContextUsage(usage, conversationID: conversationID)
            }
            guard draftAssistantMessage?.conversationID == conversationID else { return }
            draftMetrics = metrics
            if var merged = draftAssistantMessage {
                merged.routeAttempts = ConversationRouteAttempt.merge(merged.routeAttempts, metrics.routeAttempts)
                merged.sources = ConversationSource.merge(merged.sources, metrics.sources)
                draftAssistantMessage = merged
            }
            if let assistant = draftAssistantMessage {
                let searches = (metrics.webSearchActivities ?? []).enumerated().map { ordinal, activity in
                    let progress = toolProgress.items.first { $0.id == activity.id }
                    return ConversationAction(id: "web:" + activity.id, conversationID: conversationID, turnID: assistant.id,
                        ordinal: ordinal, name: "web_search", state: activity.status == .failed ? .failed : activity.status == .running ? .running : .completed,
                        startedAt: progress?.startedAt ?? metrics.startedAt, finishedAt: progress?.finishedAt ?? (activity.status == .running ? nil : .now),
                        input: activity.input, output: activity.output)
                }
                draftAssistantMessage?.actions = ConversationAction.merge(assistant.actions, searches.isEmpty ? nil : searches)
            }
        case let .titleGenerated(conversationID, title):
            await applyGeneratedTitle(title, conversationID: conversationID)
        case let .completed(conversationID):
            if var assistant = draftAssistantMessage, assistant.conversationID == conversationID,
               let source = messages.last(where: { $0.role == .user && $0.conversationID == conversationID }) {
                var actions: [ConversationAction] = []
                for image in source.images ?? [] {
                    actions.append(.init(id: assistant.id.uuidString + ":" + image.id.uuidString, conversationID: conversationID,
                        turnID: assistant.id, ordinal: actions.count, name: "view_image", state: .completed,
                        startedAt: source.createdAt, finishedAt: source.visualReport?.createdAt ?? .now,
                        detail: image.name, mediaID: image.id, previewJPEG: InputMediaPreview.jpeg(image.data)))
                }
                for input in source.attachments ?? [] {
                    if let video = input.video {
                        for frame in video.frames {
                            actions.append(.init(id: assistant.id.uuidString + ":" + frame.id.uuidString, conversationID: conversationID,
                                turnID: assistant.id, ordinal: actions.count, name: "view_image", state: .completed,
                                startedAt: source.createdAt, finishedAt: source.visualReport?.createdAt ?? .now,
                                detail: input.name, mediaID: frame.id, timestamp: frame.seconds, previewJPEG: InputMediaPreview.jpeg(frame.jpeg)))
                        }
                    }
                }
                if let report = source.visualReport {
                    actions.append(.init(id: assistant.id.uuidString + ":visual:" + report.id.uuidString, conversationID: conversationID,
                        turnID: assistant.id, ordinal: -1, name: "visual_analysis", state: .completed,
                        startedAt: source.createdAt, finishedAt: report.createdAt,
                        detail: report.choice.provider.rawValue + " · " + report.choice.modelID + "\n" + report.text))
                }
                assistant.actions = ConversationAction.merge(assistant.actions, actions.isEmpty ? nil : actions)
                draftAssistantMessage = assistant
            }

            guard activeTurnConversationID == conversationID else { return }
            failedConversations.remove(conversationID)
            await settlePendingCorrection()
            if selectedConversationID == conversationID {
                agentMission = try? await missionRepository.latest(conversationID: conversationID)
                if let agentMission { missionAuthorization = try? await missionRepository.authorization(missionID: agentMission.id) }
                else { missionAuthorization = nil }
            }
            toolProgress.interruptRunning()
            // Metrics mean a real provider answered; only then can a missing title be asked for.
            let providerAnswered = draftMetrics != nil
            let responseSaved = await persistDraft(conversationID: conversationID)
            if responseSaved, let owner = account.accessUser?.id,
               let response = messages.last(where: { $0.role == .assistant && $0.completionStatus == nil && !$0.content.isEmpty }) {
                let version = ConversationResponseVersion(id: response.id.uuidString, completedAt: .now)
                conversationResponseVersions[conversationID] = version
                try? await accountChatSync.recordResponse(conversationID: conversationID, response: version, accountID: owner)
            }
            activeTurnConversationID = nil
            activeTurnEngineID = nil
            isSending = false
            activeToolName = nil
            try? await reloadConversations()
            if selectedConversationID == conversationID { markRead(conversationID) }
            if awaitingTitle.remove(conversationID) != nil, responseSaved, providerAnswered {
                Task { await generateFallbackTitle(conversationID: conversationID) }
            }
            if responseSaved, settings.memoryEnabled != false { await scheduleMemoryCapture(conversationID: conversationID) }
            if responseSaved { await scheduleSkillLearning(conversationID: conversationID) }
        case let .failed(conversationID, diagnostic):
            guard conversationID == activeTurnConversationID else { return }
            await settlePendingCorrection()
            if let conversationID, selectedConversationID == conversationID {
                agentMission = try? await missionRepository.latest(conversationID: conversationID)
                if let agentMission { missionAuthorization = try? await missionRepository.authorization(missionID: agentMission.id) }
                else { missionAuthorization = nil }
            }
            toolProgress.interruptRunning()
            if let conversationID {
                if draftAssistantMessage?.completionStatus == nil { draftAssistantMessage?.completionStatus = .failed }
                if draftAssistantMessage?.completionStatus == .failed { failedConversations.insert(conversationID) }
                await persistDraft(conversationID: conversationID)
            }
            activeTurnConversationID = nil
            activeTurnEngineID = nil
            isSending = false
            activeToolName = nil
            alertMessage = diagnostic.message
        case let .state(status):
            if let index = engineStatuses.firstIndex(where: { $0.id == status.id }) { engineStatuses[index] = status }
        case let .toolStarted(conversationID, callID, name):
            guard activeTurnConversationID == conversationID else { return }
            activeToolName = name
            recordTimeline(conversationID) { $0.action(callID) }; updateVisibleDraft()
            toolProgress.start(id: callID, name: name)
        case let .toolStartedDetailed(conversationID, callID, name, detail):
            guard activeTurnConversationID == conversationID else { return }
            activeToolName = name
            recordTimeline(conversationID) { $0.action(callID) }; updateVisibleDraft()
            toolProgress.start(id: callID, name: name, detail: detail)
        case let .toolFinished(conversationID, callID, isError):
            guard activeTurnConversationID == conversationID else { return }
            activeToolName = nil
            completedToolCount += 1
            toolProgress.finish(id: callID, isError: isError)
        default:
            break
        }
    }

    /// Adds what the person saw while the turn ran (actions, sources, timeline and the streamed
    /// text the timeline indexes) to the answer message the durable task already saved.
    private func completeDeliveredMessage(_ stored: inout ConversationMessage, with live: ConversationMessage) async throws {
        // Durable projection already owns the stable network action for this turn.
        let hasDurableNetwork = stored.actions?.contains { $0.name == "network" } == true
        let turnID = stored.id
        let mapped = (live.actions ?? []).filter { !hasDurableNetwork || $0.name != "network" }
            .map { value in var value = value; value.turnID = turnID; return value }
        stored.routeAttempts = ConversationRouteAttempt.merge(stored.routeAttempts, live.routeAttempts)
        stored.sources = ConversationSource.merge(stored.sources, live.sources)
        stored.actions = ConversationAction.merge(stored.actions, mapped)
        stored.timeline = TurnTimeline.merge(stored.timeline, live.timeline)
        guard let sqlite = conversationRepository as? SQLiteConversationRepository else { return }
        try await sqlite.savePresentation(sources: stored.sources, routeAttempts: stored.routeAttempts, timeline: stored.timeline,
                                          streamedContent: live.timeline == nil ? nil : live.content, messageID: stored.id)
        if live.timeline != nil, live.content.count > stored.content.count,
           live.content.contains(stored.content.trimmingCharacters(in: .whitespacesAndNewlines)) { stored.content = live.content }
        if let actions = stored.actions { try await sqlite.saveActions(actions, messageID: stored.id) }
    }

    @discardableResult private func persistDraft(conversationID: UUID) async -> Bool {
        if let assistantSaveTask { return await assistantSaveTask.value }
        recordTimeline(conversationID) { $0.finish() }
        if runtimeManagedConversations.contains(conversationID) {
            do {
                let persisted = try await conversationRepository.messages(conversationID: conversationID)
                var stored = try await projectRuntimeActivity(persisted)
                let sourceSequence = stored.last(where: { $0.role == .user })?.sequence
                if !stored.contains(where: { $0.role == .assistant && $0.sequence > (sourceSequence ?? -1) }),
                   var live = draftAssistantMessage, live.conversationID == conversationID,
                   !live.content.isEmpty || live.timeline?.entries.isEmpty == false || live.actions?.isEmpty == false {
                    // The run stopped, paused or is waiting before delivering an answer: keep what the
                    // person saw (text, actions, timeline). A later answer completes this same message.
                    live.sequence = (stored.map(\.sequence).max() ?? -1) + 1
                    live.actions = live.actions?.map { value in
                        var value = value
                        if value.state == .waiting || value.state == .running {
                            value.state = live.completionStatus == nil ? .needsReview : .cancelled; value.finishedAt = .now
                        }
                        return value
                    }
                    do { try await conversationRepository.append(live) }
                    catch {
                        // The task delivered its answer at the same moment (same position): that
                        // message is completed with what the person saw instead of a second one.
                        var reloaded = try await projectRuntimeActivity(try await conversationRepository.messages(conversationID: conversationID))
                        guard let index = reloaded.firstIndex(where: { $0.role == .assistant && $0.sequence > (sourceSequence ?? -1) }) else { throw error }
                        try await completeDeliveredMessage(&reloaded[index], with: live)
                    }
                    stored = try await projectRuntimeActivity(try await conversationRepository.messages(conversationID: conversationID))
                } else if let index = stored.firstIndex(where: { $0.role == .assistant && $0.sequence > (sourceSequence ?? -1) }), let live = draftAssistantMessage {
                    try await completeDeliveredMessage(&stored[index], with: live)
                }
                if let assistant = stored.last, assistant.role == .assistant, let metrics = draftMetrics {
                    try? await metricsRepository.save(metrics, messageID: assistant.id, conversationID: conversationID)
                }
                draftAssistantMessage = nil; draftMetrics = nil
                if selectedConversationID == conversationID { messages = stored }
                return true
            } catch { responseSaveError = error.localizedDescription; return false }
        }
        if var assistant = draftAssistantMessage, assistant.conversationID == conversationID {
            assistant.actions = assistant.actions?.map { value in
                var value = value
                if value.state == .waiting || value.state == .running {
                    value.state = assistant.completionStatus == nil ? .completed : .cancelled; value.finishedAt = .now
                }
                return value
            }
            draftAssistantMessage = assistant
        }
        guard let draftAssistantMessage,
              draftAssistantMessage.conversationID == conversationID else { return true }
        updateVisibleDraft()
        let task = Task { @MainActor in
            if !draftAssistantMessage.content.isEmpty || draftAssistantMessage.completionStatus != nil {
                do { try await conversationRepository.append(draftAssistantMessage) }
                catch {
                    // A durable task may have delivered this answer at the same position first:
                    // complete that message with what the person saw rather than failing the save.
                    let stored = (try? await conversationRepository.messages(conversationID: conversationID)) ?? []
                    let prompt = stored.last(where: { $0.role == .user && $0.sequence < draftAssistantMessage.sequence })?.sequence ?? -1
                    if var delivered = stored.last(where: { $0.role == .assistant && $0.sequence > prompt && $0.id != draftAssistantMessage.id }),
                       (try? await completeDeliveredMessage(&delivered, with: draftAssistantMessage)) != nil {
                        if selectedConversationID == conversationID {
                            messages = (try? await conversationRepository.messages(conversationID: conversationID)) ?? messages
                        }
                    } else {
                        responseSaveError = error.localizedDescription
                        return false
                    }
                }
                if let metrics = draftMetrics, draftAssistantMessage.completionStatus == nil {
                    try? await metricsRepository.save(metrics, messageID: draftAssistantMessage.id, conversationID: conversationID)
                    if let task = activeAccountTask {
                        var row = AccountActivityRecord(id: draftAssistantMessage.id, accountID: task.accountID, deviceID: accountActivityRepository.deviceID, deviceName: Host.current().localizedName ?? "Mac", conversationID: conversationID, parentTaskID: task.id,
                            provider: metrics.provider, modelID: metrics.modelID, mode: metrics.mode, startedAt: metrics.startedAt, completedAt: metrics.startedAt.addingTimeInterval(metrics.totalSeconds),
                            totalTokens: metrics.usage.inputTokens.flatMap { input in metrics.usage.outputTokens.map { input + $0 } })
                        row.costTrackedSeparately = true
                        try? await accountActivityRepository.record(row)
                        if metrics.mode == "chat", account.accessUser?.id == task.accountID, let client = account.supabaseClient {
                            let eventID = draftAssistantMessage.id
                            Task { [weak self] in
                                guard self?.account.accessUser?.id == task.accountID else { return }
                                try? await AccountNotificationService(client: client).notify(accountID: task.accountID,
                                    event: eventID, task: task.id, conversation: conversationID, category: .response)
                            }
                        }
                    }
                    if selectedConversationID == conversationID { messageMetrics[draftAssistantMessage.id] = metrics }
                }
            }
            draftMetrics = nil
            self.draftAssistantMessage = nil
            responseSaveError = nil
            return true
        }
        assistantSaveTask = task
        let saved = await task.value
        assistantSaveTask = nil
        return saved
    }

    func retryResponseSave() async {
        guard !isRetryingResponseSave, !isSending, let response = unsavedResponse else { return }
        isRetryingResponseSave = true
        defer { isRetryingResponseSave = false }
        if await persistDraft(conversationID: response.conversationID) { try? await reloadConversations() }
    }

    private func startDraftTimeline() {
        draftTimeline = TurnTimelineBuilder()
        draftTimelineMessageID = draftAssistantMessage?.id
    }

    /// Applies one timeline change to the draft of this conversation; a turn that started
    /// without `startDraftTimeline` (restored or external drafts) begins at its first event.
    private func recordTimeline(_ conversationID: UUID, _ change: (inout TurnTimelineBuilder) -> Void) {
        guard var assistant = draftAssistantMessage, assistant.conversationID == conversationID else { return }
        if draftTimelineMessageID != assistant.id {
            draftTimeline = TurnTimelineBuilder(existingContent: assistant.content)
            draftTimelineMessageID = assistant.id
        }
        change(&draftTimeline)
        assistant.timeline = draftTimeline.timeline
        draftAssistantMessage = assistant
    }

    private func updateVisibleDraft() {
        guard let draftAssistantMessage,
              draftAssistantMessage.conversationID == selectedConversationID,
              !draftAssistantMessage.content.isEmpty || draftAssistantMessage.completionStatus != nil || !(draftAssistantMessage.actions ?? []).isEmpty
                || draftAssistantMessage.timeline?.entries.isEmpty == false else { return }
        if let index = messages.firstIndex(where: { $0.id == draftAssistantMessage.id }) {
            messages[index] = draftAssistantMessage
        } else {
            messages.append(draftAssistantMessage)
        }
    }

    // MARK: Follow-ups queued while a turn runs

    struct QueuedMessage: Identifiable, Equatable {
        let id = UUID()
        let conversationID: UUID?
        let text: String
        let attachments: [TextAttachment]
        let images: [ImageAttachment]
    }

    func queueComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty else { return }
        queuedMessages.append(QueuedMessage(conversationID: activeTurnConversationID ?? selectedConversationID, text: text,
                                            attachments: pendingAttachments, images: pendingImages))
        composerText = ""
        pendingAttachments = []
        pendingImages = []
    }

    func removeQueuedMessage(_ id: UUID) { queuedMessages.removeAll { $0.id == id } }

    /// Sends the oldest message queued for the open conversation once nothing is running.
    private func sendNextQueuedMessage() {
        guard !isSending, !isShuttingDown,
              let index = queuedMessages.firstIndex(where: { $0.conversationID == selectedConversationID }) else { return }
        let next = queuedMessages.remove(at: index)
        // A draft typed meanwhile is kept after the queued text.
        let draft = composerText
        composerText = draft.isEmpty ? next.text : next.text + "\n\n" + draft
        pendingAttachments = next.attachments + pendingAttachments
        pendingImages = next.images + pendingImages
        Task { await sendComposer() }
    }

    /// A turn started or ended: keep the Mac awake if asked, report the end, send what was queued.
    private func sendingChanged() {
        if !isSending, var task = activeAccountTask {
            activeAccountTask = nil
            task.completedAt = .now; task.updatedAt = .now
            Task { [accountActivityRepository] in try? await accountActivityRepository.record(task) }
        }

        let keepAwake = isSending && preferences.preventSleepWhileRunning
        Task { await powerActivity.setEnabled(keepAwake) }
        guard !isSending else { return }
        if let answer = messages.last, answer.role == .assistant, !answer.content.isEmpty {
            let title = conversations.first { $0.id == selectedConversationID }?.title ?? "AIM AI"
            AIMNotifier.post(.completion, title: title, body: answer.content, preferences: preferences)
        }
        sendNextQueuedMessage()
    }

    /// The settings pages' preferences (defaults when never changed).
    var preferences: AppPreferences { settings.preferences ?? AppPreferences() }

    func updatePreferences(_ change: (inout AppPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        guard updated != preferences else { return }
        settings.preferences = updated
        AppearancePreferences.mirror(updated)
        Task { await persistSettings() }
    }

    func setConversationAppearance(_ appearance: ConversationAppearance) {
        settings.conversationAppearance = appearance
        Task { await persistSettings() }
    }

    func setMemoryEnabled(_ enabled: Bool) {
        if let shared = memoryRepository as? AccountMemoryRepository, account.accessUser != nil {
            let revision = accountMemoryRevision, owner = memoryOwner
            Task {
                do { try await shared.setEnabled(enabled, expectedRevision: revision, expectedOwner: owner); await loadMemories() }
                catch { memoryError = "Memory changed on another device or could not sync. Your entries are kept." }
            }
            if !enabled { for (_, task) in memoryCaptureTasks.values { task.cancel() } }
            return
        }
        settings.memoryEnabled = enabled
        if !enabled {
            for (_, task) in memoryCaptureTasks.values { task.cancel() }
        }
        Task { await persistSettings() }
    }

    func setExternalMemoryCaptureEnabled(_ enabled: Bool) {
        settings.externalMemoryCaptureEnabled = enabled
        if !enabled {
            for (_, task) in memoryCaptureTasks.values { task.cancel() }
        }
        Task { await persistSettings() }
    }

    func loadMemories() async {
        let expectedAccount = account.accessUser?.id
        do {
            if let shared = memoryRepository as? AccountMemoryRepository, var snapshot = try await shared.snapshot() {
                guard account.accessUser?.id == expectedAccount else { return }
                // First sign-in on this Mac with an account that has no memory yet: the memories
                // kept on this Mac move into the account (the local originals stay).
                if snapshot.revision == 0, snapshot.entries.isEmpty, let owner = expectedAccount {
                    let local = try await shared.legacyPreview().filter { $0.status != .archived }
                    if !local.isEmpty {
                        try? await shared.importSelected(Set(local.map(\.id)), expectedRevision: 0, expectedOwner: .account(owner))
                        if let refreshed = try await shared.snapshot() { snapshot = refreshed }
                    }
                }
                memories = snapshot.entries.compactMap(AccountMemoryRepository.item)
                accountMemoryRevision = snapshot.revision; settings.memoryEnabled = snapshot.enabled
                await persistSettings()
            } else {
                let items = try await memoryRepository.list(status: nil)
                guard account.accessUser?.id == expectedAccount else { return }
                memories = items; accountMemoryRevision = nil
            }
            memoryError = nil
        } catch { memoryError = "Saved memories could not be loaded." }
    }

    var memoryOwner: AccountMemoryOwner { account.accessUser.map { .account($0.id) } ?? .local }

    #if DEBUG
    /// Qualification: each step of the memory store, with its exact error.
    func memoryProbe() async -> [String: String] {
        var result: [String: String] = ["repository": String(describing: type(of: memoryRepository)), "signed_in": "\(account.accessUser != nil)"]
        if let shared = memoryRepository as? AccountMemoryRepository {
            do {
                let snapshot = try await shared.snapshot()
                result["snapshot"] = snapshot.map { "enabled=\($0.enabled) revision=\($0.revision ?? -1) entries=\($0.entries.count)" } ?? "local (no account binding)"
            } catch { result["snapshot_error"] = String(describing: error) }
        }
        let probe = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "AIM-TEST-36 probe", content: "Probe entry, deleted at once.")
        AccountSessionService.lastFailureDescription = nil
        do { try await memoryRepository.save(probe); result["save"] = "ok" }
        catch { result["save_error"] = String(describing: error) + " / server: " + (AccountSessionService.lastFailureDescription ?? "none") }
        do { try await memoryRepository.delete(id: probe.id); result["delete"] = "ok" }
        catch { result["delete_error"] = String(describing: error) }
        return result
    }
    #endif

    func saveMemory(_ item: MemoryItem, expectedRevision: Int? = nil, expectedOwner: AccountMemoryOwner? = nil) async throws {
        guard expectedOwner == nil || expectedOwner == memoryOwner else { throw AccountServiceError.conflict }
        var edited = item
        edited.status = .verified
        edited.updatedAt = .now
        try MemoryContext.validate(edited)
        if let shared = memoryRepository as? AccountMemoryRepository, account.accessUser != nil {
            try await shared.save(edited, expectedRevision: expectedRevision ?? accountMemoryRevision, expectedOwner: expectedOwner ?? memoryOwner)
        } else { try await memoryRepository.save(edited) }
        await loadMemories()
    }

    func setMemoryPinned(_ item: MemoryItem, _ pinned: Bool) async {
        var updated = item
        updated.isPinned = pinned
        updated.updatedAt = .now
        do {
            if let shared = memoryRepository as? AccountMemoryRepository, account.accessUser != nil { try await shared.save(updated, expectedRevision: accountMemoryRevision, expectedOwner: memoryOwner) }
            else { try await memoryRepository.save(updated) }
            await loadMemories()
        }
        catch { memoryError = "The memory could not be updated." }
    }

    func loadLegacyMemoryPreview() async {
        guard let shared = memoryRepository as? AccountMemoryRepository, account.accessUser != nil else { return }
        do { legacyMemoryPreview = try await shared.legacyPreview() }
        catch { memoryError = "Earlier local memories could not be previewed." }
    }
    func importLegacyMemories(_ ids: Set<UUID>, expectedRevision: Int?, expectedOwner: AccountMemoryOwner) async -> Bool {
        guard let shared = memoryRepository as? AccountMemoryRepository, !ids.isEmpty else { return false }
        do { try await shared.importSelected(ids, expectedRevision: expectedRevision, expectedOwner: expectedOwner); await loadMemories(); return true }
        catch { memoryError = "The import could not sync or the account memories changed. Your originals and selection are kept."; return false }
    }

    func consolidateDuplicateMemories(keeping: UUID, archiving: [UUID]) async {
        do { try await memoryRepository.consolidateDuplicates(keeping: keeping, archiving: archiving); await loadMemories() }
        catch { memoryError = "This duplicate proposal changed or could not be saved. Review the memories again." }
    }

    func archiveMemory(_ id: UUID) async {
        do { try await memoryRepository.archive(id: id); await loadMemories() }
        catch { memoryError = "The memory could not be archived." }
    }

    func restoreMemory(_ item: MemoryItem) async {
        var restored = item
        restored.status = .verified
        restored.updatedAt = .now
        do { try MemoryContext.validate(restored); try await memoryRepository.save(restored); await loadMemories() }
        catch { memoryError = "The memory could not be restored." }
    }

    func deleteMemory(_ id: UUID) async {
        do { try await memoryRepository.delete(id: id); await loadMemories() }
        catch { memoryError = "The memory could not be deleted." }
    }

    private func scheduleMemoryCapture(conversationID: UUID) async {
        guard settings.memoryEnabled != false, settings.externalMemoryCaptureEnabled != false else { return }
        let captureAccountID = account.accessUser?.id
        // Settings › Personalization: Agent and Code use tools, so they may be left out.
        if !preferences.memoriesFromToolChats,
           conversations.first(where: { $0.id == conversationID })?.mode != .chat { return }
        guard let conversation = try? await conversationRepository.conversation(id: conversationID),
              let history = try? await conversationRepository.messages(conversationID: conversationID),
              let prompt = history.last(where: { $0.role == .user }), !prompt.content.isEmpty else { return }
        // The reply that answered it: context for the capture, never evidence.
        let reply = history.last(where: { $0.role == .assistant && $0.sequence > prompt.sequence })?.content
        let sourceMessageID = prompt.id
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if memoryCaptureTasks[sourceMessageID]?.0 == token { memoryCaptureTasks[sourceMessageID] = nil }
            }
            do {
                guard account.accessUser?.id == captureAccountID, settings.memoryEnabled != false, settings.externalMemoryCaptureEnabled != false else { return }
                let capture = MemoryCaptureService(repository: memoryRepository, secureStore: providerStore.boundToCurrentScope(),
                    chatService: ProviderChatService(meter: spendMeter),
                    expectedOwner: captureAccountID.map(AccountMemoryOwner.account) ?? .local)
                var proposals = try await capture.proposals(userText: prompt.content, assistantText: reply,
                                                            sourceMessageID: sourceMessageID, conversation: conversation)
                // Order updates by source message, not by variable provider latency.
                for index in proposals.indices { proposals[index].updatedAt = prompt.createdAt }
                guard account.accessUser?.id == captureAccountID, !Task.isCancelled, !isShuttingDown, settings.memoryEnabled != false,
                      settings.externalMemoryCaptureEnabled != false else { return }
                if try await capture.saveNew(proposals,
                    explicitRequest: MemoryExtraction.requestsRemembering(prompt.content)) > 0 {
                    await loadMemories()
                    // A discreet line under the answer, as in ChatGPT ("Memory updated").
                    memoryNotices[conversationID] = MemoryNotice(after: prompt.id,
                        text: proposals.prefix(3).map(\.content).joined(separator: " · "))
                }
                if proposals.isEmpty && MemoryExtraction.requestsRemembering(prompt.content) {
                    memoryError = "AIM could not verify a safe fact to remember from that request. Add it in Settings → Memory if needed."
                    memoryNotices[conversationID] = MemoryNotice(after: prompt.id, text: "nothing saved, no safe fact found to remember", saved: false)
                }
            } catch is CancellationError { }
            catch {
                Self.memoryLog.error("Memory capture failed: \(String(describing: error), privacy: .public)")
                // Never a blocking alert: the answer is there; the note under it says what happened.
                memoryError = "Automatic memory capture failed (\(error.localizedDescription)). Your conversation remains saved."
                if MemoryExtraction.requestsRemembering(prompt.content) {
                    memoryNotices[conversationID] = MemoryNotice(after: prompt.id, text: "not saved (\(error.localizedDescription))", saved: false)
                }
            }
        }
        memoryCaptureTasks[sourceMessageID] = (token, task)
    }

    /// Learning loop (opt-in): after a long, normally ended Agent run, one
    /// review request may leave an inactive skill proposal for the person.
    private func scheduleSkillLearning(conversationID: UUID) async {
        let level = SkillPreferences.learningLevel
        guard level != .off,
              let conversation = try? await conversationRepository.conversation(id: conversationID),
              conversation.mode == .agent,
              let run = try? await workspaceRunRepository.history(conversationID: conversationID, limit: 1).first,
              run.calls.count >= SkillLearning.minimumToolCalls,
              let messages = try? await conversationRepository.messages(conversationID: conversationID) else { return }
        let service = SkillLearningService(secureStore: providerStore.boundToCurrentScope(), meter: spendMeter)
        Task.detached {
            guard let (proposal, outcome) = try? await service.learn(from: conversation, messages: messages, run: run,
                                                                    level: level) else { return }
            switch outcome {
            case .applied(let replaced):
                await SchedulerNotifier.post(title: replaced ? "AIM improved a skill" : "AIM learned a skill",
                    body: "“\(proposal.name)”: \(proposal.description) The previous version can be restored in Settings → Skills.")
            case .proposed(let reason):
                await SchedulerNotifier.post(title: "AIM proposed a skill",
                    body: "“\(proposal.name)”\(reason.map { " (\($0))" } ?? ""): review it in Settings → Skills.")
            }
        }
    }

    private func persistSettings() async {
        do { try prepareAccountPreferenceScope(); try persistAccountPreferenceScope(); try await settingsRepository.save(settings) }
        catch { alertMessage = error.localizedDescription }
    }

    private var scopedPreferenceSnapshot: AccountChatPreferenceScopeStore.Snapshot {
        var portable = accountChatPreferences
        portable.customInstructions = settings.personalization?.isEnabled == true ? settings.personalization?.instructions : nil
        return .init(favorites: settings.favoriteModels ?? [], preferences: portable, personalization: settings.personalization, addedModels: RemoteModelCatalogMetadata.additions())
    }
    var chatPreferenceOwner: AccountMemoryOwner {
        accountPreferenceScopeOwner.map { .account($0) } ?? .local
    }
    private func prepareAccountPreferenceScope(restoringStored: Bool = false) throws {
        guard accountPreferenceScopeReady else { return }
        let owner = account.accessUser?.id
        guard restoringStored || !accountPreferenceScopeInitialized || owner != accountPreferenceScopeOwner || pendingPreferenceSnapshot != nil else { return }
        let current = pendingPreferenceSnapshot ?? scopedPreferenceSnapshot
        do {
            let selected = try accountPreferenceScopes.activate(accountID: owner, current: current,
                currentAccountID: accountPreferenceScopeOwner, captureCurrent: accountPreferenceScopeInitialized && !restoringStored)
            accountChatPreferences = selected.preferences
            settings.favoriteModels = selected.favorites; settings.personalization = selected.personalization
            try RemoteModelCatalogMetadata.replaceAdditions(selected.addedModels ?? [])
            accountPreferenceScopeOwner = owner; accountPreferenceScopeInitialized = true; pendingPreferenceSnapshot = nil
            accountActivityRecords = []; accountActivitySyncedAt = nil; accountActivityError = nil
        } catch {
            pendingPreferenceSnapshot = current
            accountChatPreferences = .init(); settings.favoriteModels = []; settings.personalization = nil
            try? RemoteModelCatalogMetadata.replaceAdditions([])
            throw error
        }
    }
    private func persistAccountPreferenceScope() throws {
        guard accountPreferenceScopeReady else { return }
        guard accountPreferenceScopeInitialized, accountPreferenceScopeOwner == account.accessUser?.id,
              pendingPreferenceSnapshot == nil else { throw AccountServiceError.conflict }
        try accountPreferenceScopes.save(scopedPreferenceSnapshot, accountID: accountPreferenceScopeOwner)
    }

    private func scheduleComposerSave() {
        guard !restoringComposer, !isShuttingDown else { return }
        composerRevision = UUID()
        composerSaveTask?.cancel()
        composerSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = self?.flushComposer()
        }
    }

    private func scopedComposerKey(_ scope: String) -> String {
        (composerStorageID?.uuidString ?? "unavailable") + ":" + scope
    }

    private var newComposerScope: String {
        "new:\(mode.rawValue)" + (selectedProjectID.map { ":project:\($0.uuidString)" } ?? "")
    }

    @discardableResult func flushComposer() -> Bool {
        composerSaveTask?.cancel()
        composerSaveTask = nil
        guard composerLoaded else { return false }
        do {
            let pending = pendingVisualApproval.flatMap { value -> DraftVisualApproval? in
                guard value.context == currentVisualDraftContext else { return nil }
                return .init(id: value.id, accountID: value.ownerID, primaryProvider: value.primaryProvider, primaryModel: value.primaryModel, sources: value.sources, conversationID: value.conversationID, target: value.target)
            }
            try composerDraftStore.save(ComposerDraft(text: composerText, attachments: pendingAttachments, images: pendingImages.isEmpty ? nil : pendingImages, visualReport: visualDraftReport, visualApproval: pending), key: scopedComposerKey(composerScope))
            return true
        } catch { alertMessage = "Could not save your draft: \(error.localizedDescription)"; return false }
    }

    private func restoreComposer(scope: String) -> Bool {
        do {
            let storageID = account.identity?.storageID
            let draft = try composerDraftStore.load(key: (storageID?.uuidString ?? "unavailable") + ":" + scope)
            composerStorageID = storageID
            restoringComposer = true
            composerScope = scope
            composerLoaded = true
            composerText = draft.text
            pendingAttachments = draft.attachments
            pendingImages = draft.images ?? []
            visualDraftReport = draft.visualReport
            pendingVisualApproval = nil
            composerRevision = UUID()
            if let pending = draft.visualApproval, pending.accountID == account.identity?.storageID {
                var restored = PendingMacVisualApproval(scope: scope, navigation: navigationID, draftRevision: composerRevision, ownerID: pending.accountID,
                    primaryProvider: pending.primaryProvider, primaryModel: pending.primaryModel, sources: pending.sources,
                    conversationID: pending.conversationID, target: pending.target, credentialScope: account.credentialScope.snapshot())
                restored.id = pending.id; pendingVisualApproval = restored
            }
            restoringComposer = false
            return true
        } catch { alertMessage = "Could not restore your draft: \(error.localizedDescription)"; return false }
    }
}


// MARK: Scheduled tasks

extension AppModel {
    func startScheduledTasks() async {
        if continuityRuntime != nil { await reloadScheduledTasks(); return }
        guard settings.continuity?.permanent != true else { return }
        guard runsScheduledTasks, taskScheduler == nil, hasAccess, !isShuttingDown else { return }
        // Learned skills nobody used for 60 days retire to the restorable archive.
        _ = try? SkillUsage.archiveStale()
        let dependencies = ScheduledRunDependencies(conversations: conversationRepository, missions: missionRepository,
            runs: workspaceRunRepository, secureStore: providerStore, memory: memoryRepository,
            settings: settingsRepository, plans: planRepository, ledger: spendLedger,
            cuaQualifications: cuaQualificationRepository, mcpServers: mcpServerRepository,
            projects: projectRepository, documents: projectDocuments, sourceIndex: projectSourceIndex,
            activity: activityRepository, compaction: compactionRepository, jobs: subagentJobRepository,
            workspaces: subagentWorkspaceRepository, scheduler: schedulerRepository)
        let scheduler = TaskScheduler(repository: schedulerRepository,
            executor: ScheduledAgentRunner(dependencies: dependencies),
            notify: { [weak self] title, body in
                await MainActor.run { AIMNotifier.post(.automation, title: title, body: body, preferences: self?.preferences ?? AppPreferences()) }
            })
        taskScheduler = scheduler
        triggerMonitor = TaskTriggerMonitor { id, reason, payload in
            Task { await scheduler.fire(taskID: id, reason: reason, payload: payload) }
        }
        await scheduler.start()
        await reloadScheduledTasks()
    }

    var continuitySettings: ContinuitySettings { settings.continuity ?? ContinuitySettings() }
    var conversationIsWorking: Bool {
        isSending || selectedContinuityExecution?.state.isRecoverable == true
    }
    var selectedContinuityExecution: AgentExecution? {
        continuityExecutions.filter { $0.conversationID == selectedConversationID }.max { $0.updatedAt < $1.updatedAt }
    }
    /// Durable approval session IDs belong to executions/children, not conversations.
    func toolApproval(_ approval: PendingToolApproval, belongsTo conversationID: UUID) -> Bool {
        if let root = continuityApprovalRoots[approval.id] {
            return continuityExecutions.contains { $0.id == root && $0.conversationID == conversationID && !$0.state.isTerminal }
        }
        return approval.sessionID == conversationID
    }

    func updateContinuityInteractions(approvals: [PendingToolApproval], questions: [AgentQuestion], roots: [UUID: UUID]) {
        continuityApprovalRoots = roots
        pendingToolApprovals = approvals
        pendingAgentQuestions = questions
    }

    var selectedToolApproval: PendingToolApproval? {
        pendingToolApprovals.first { approval in
            if let root = continuityApprovalRoots[approval.id] { return root == selectedContinuityExecution?.id }
            return approval.sessionID == selectedConversationID
        }
    }
    private func startContinuityObservation() {
        guard let continuityRuntime, continuityTask == nil else { return }
        continuityTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let records = try JSONDecoder().decode([AgentExecution].self, from: await continuityRuntime.send(AgentHostCommand(action: .list)))
                    var approvals: [PendingToolApproval] = [], questions: [AgentQuestion] = [], approvalRoots: [UUID: UUID] = [:]
                    var phoneEvents: [(AgentExecution, String, AIMNotificationCategory)] = []
                    for record in records where !record.state.isTerminal {
                        let pending = try JSONDecoder().decode(ContinuityInteractions.self, from: await continuityRuntime.send(AgentHostCommand(action: .interactions, executionID: record.id)))
                        approvals += pending.approvals; questions += pending.questions
                        for approval in pending.approvals { approvalRoots[approval.id] = record.id }
                        if let approval = pending.approvals.first { phoneEvents.append((record, "approval:\(approval.id)", .approval)) }
                        if let question = pending.questions.first { phoneEvents.append((record, "question:\(question.id)", .question)) }
                        if record.state == .blocked { phoneEvents.append((record, "intervention:\(record.revision)", .failure)) }
                    }
                    for record in records where record.state.isTerminal {
                        if [.verified, .accepted].contains(record.state) { phoneEvents.append((record, "completed", .task)) }
                        else if record.state == .failed { phoneEvents.append((record, "intervention:\(record.revision)", .failure)) }
                    }
                    guard let self else { return }
                    let changed = self.continuityExecutions.map(\.revision) != records.map(\.revision)
                    self.continuityExecutions = records
                    for record in records {
                        self.continuitySpend[record.id] = try await self.spendLedger.executionSnapshot(record.id)
                        self.continuityProcesses[record.id] = try JSONDecoder().decode([DurableProcess].self, from: await continuityRuntime.send(AgentHostCommand(action: .processes, executionID: record.id)))
                    }
                    self.updateContinuityInteractions(approvals: approvals, questions: questions, roots: approvalRoots)
                    self.notifyPhone(phoneEvents)
                    if changed, !self.isSending, let id = self.selectedConversationID {
                        self.messages = try await self.conversationRepository.messages(conversationID: id)
                        try await self.reloadConversations()
                    }
                } catch { /* reconnect polling keeps local history usable */ }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    /// Tasks run in this app (not only in the permanent host) reach the person's iPhone: an
    /// approval or question waiting, a task finished or needing them. Event IDs are the host's,
    /// so the server ignores a duplicate when both report the same event.
    private func notifyPhone(_ events: [(AgentExecution, String, AIMNotificationCategory)]) {
        guard let owner = account.accessUser?.id, let client = account.supabaseClient else { return }
        for (record, key, category) in events where record.accountID == owner && record.updatedAt >= phoneEventsSince {
            let eventID = AccountRuntimeActivity.stableID(record.id, "notification:" + key)
            guard sentPhoneEvents.insert(eventID).inserted else { continue }
            let task = record.id, conversation = record.conversationID
            Task { [weak self] in
                do { try await AccountNotificationService(client: client).notify(accountID: owner, event: eventID, task: task, conversation: conversation, category: category) }
                catch {
                    // Retried at most every 30 s (offline, server busy): never a burst of requests.
                    try? await Task.sleep(for: .seconds(30))
                    await MainActor.run { _ = self?.sentPhoneEvents.remove(eventID) }
                }
            }
        }
    }
    func acknowledgeContinuityProcess(_ process: UUID) async {
        guard let execution = selectedContinuityExecution, let continuityRuntime else { return }
        do { _ = try await continuityRuntime.send(AgentHostCommand(action: .acknowledgeProcess, executionID: execution.id, processID: process)) }
        catch { alertMessage = "The uncertain process could not be acknowledged: \(error.localizedDescription)" }
    }
    /// The TypeSafe key used only to rank sub-agent model candidates with Jev.
    var hasJevKey: Bool { ((try? providerStore.readData(forKey: JevDecisionClient.keychainKey)) ?? nil)?.isEmpty == false }
    func saveJevKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        try providerStore.store(Data(key.utf8), forKey: JevDecisionClient.keychainKey)
    }
    func removeJevKey() throws { try providerStore.removeData(forKey: JevDecisionClient.keychainKey) }

    /// Stops one sub-agent from its panel; its parent keeps running and sees it as cancelled.
    func cancelSubagent(executionID: UUID, childID: UUID) async {
        guard let continuityRuntime else { alertMessage = "The agent runtime is unavailable; the sub-agent was not stopped."; return }
        do { _ = try await continuityRuntime.send(AgentHostCommand(action: .cancelChild, executionID: executionID, sessionID: childID)) }
        catch { alertMessage = "The sub-agent could not be stopped: \(error.localizedDescription)" }
    }
    func controlContinuityExecution(_ action: AgentHostCommand.Action) async {
        guard let execution = selectedContinuityExecution, let continuityRuntime else { return }
        do {
            let data = try await continuityRuntime.send(AgentHostCommand(action: action, executionID: execution.id))
            let updated = try JSONDecoder().decode(AgentExecution.self, from: data)
            guard updated.id == execution.id else { return }
            if let index = continuityExecutions.firstIndex(where: { $0.id == updated.id }),
               continuityExecutions[index].revision <= updated.revision { continuityExecutions[index] = updated }
        }
        catch { alertMessage = "The mission could not be updated: \(error.localizedDescription)" }
    }
    func updateContinuityResources(keepAwake: Bool? = nil, maximumRoots: Int? = nil, maximumChildren: Int? = nil) {
        var value = continuitySettings
        if let keepAwake { value.keepAwake = keepAwake }
        if let maximumRoots { value.maximumRoots = max(1, maximumRoots) }
        if let maximumChildren { value.maximumChildren = max(1, maximumChildren) }
        settings.continuity = value
        Task {
            await persistSettings()
            try? await continuityRuntime?.integratedCoordinator()?.configure(maximumRoots: value.maximumRoots)
            await SubagentConcurrencyGate.shared.configure(value.maximumChildren)
        }
    }
    func setPermanentContinuity(_ enabled: Bool) async {
        guard !isChangingContinuityService, let continuityRuntime, let paths else { return }
        isChangingContinuityService = true
        defer { isChangingContinuityService = false }
        let service = AgentHostServiceController()
        do {
            if enabled {
                // Stop ingress before the checkpoint transfer; no second owner.
                await stopRemoteHost(); triggerMonitor?.stopAll(); triggerMonitor = nil
                await taskScheduler?.stop(); taskScheduler = nil
                var value = continuitySettings; value.permanent = true; value.keepAwake = true
                settings.continuity = value; try await settingsRepository.save(settings)
                try await continuityRuntime.transferToHelper()
                try service.enable()
                if service.status == .requiresApproval {
                    alertMessage = "Allow AIM Agent Host in macOS Login Items, then reopen AIM. Missions remain checkpointed while approval is pending."
                } else {
                    try await continuityRuntime.waitForHelperReadiness()
                    await refreshRemoteState()
                }
            } else {
                // Stopping is distinct from quitting the UI and preserves checkpoints.
                _ = try await continuityRuntime.send(AgentHostCommand(action: .stop))
                try await service.disable()
                var value = continuitySettings; value.permanent = false; settings.continuity = value
                try await settingsRepository.save(settings)
                let lease = try RuntimeLease(url: paths.applicationSupport.appending(path: "agent-runtime.lock"))
                try await continuityRuntime.becomeIntegrated(database: database, lease: lease, maximumRoots: value.maximumRoots)
                await startScheduledTasks(); await startRemoteHostIfEnabled()
            }
        } catch {
            if enabled, service.status == .enabled {
                alertMessage = "The background service is registered and is starting or reconnecting. Checkpoints are retained. Wait and refresh to reconnect; registration has not been undone. \(error.localizedDescription)"
            } else {
                alertMessage = "The background service could not be changed. Checkpoints are retained: \(error.localizedDescription)"
            }
            if enabled, service.status != .enabled, service.status != .requiresApproval {
                var value = continuitySettings; value.permanent = false; settings.continuity = value
                try? await settingsRepository.save(settings)
                if let lease = try? RuntimeLease(url: paths.applicationSupport.appending(path: "agent-runtime.lock")) {
                    try? await continuityRuntime.becomeIntegrated(database: database, lease: lease, maximumRoots: value.maximumRoots)
                }
                await startScheduledTasks(); await startRemoteHostIfEnabled()
            }
        }
    }

    func reloadScheduledTasks() async {
        scheduledTasks = (try? await schedulerRepository.list()) ?? []
        triggerMonitor?.update(scheduledTasks)
        if scheduledTasks.contains(where: { $0.spec != nil }) { await SchedulerNotifier.requestAuthorization() }
    }

    func saveScheduledTask(_ task: ScheduledTask) async throws {
        guard task.spec?.isValid == true else { throw AgentMissionError.invalidInput }
        var task = task
        task.nextRunAt = task.nextRunAt ?? task.spec?.nextRun(after: .now)
        task.updatedAt = .now
        try await schedulerRepository.save(task)
        await reloadScheduledTasks()
    }

    /// Re-enabling clears a pause or an automatic disable and restarts the schedule from now.
    func setScheduledTask(_ id: UUID, enabled: Bool) async {
        guard var task = try? await schedulerRepository.task(id: id), task.runningSince == nil else { return }
        task.state = enabled ? .enabled : .disabled
        if enabled {
            task.consecutiveFailures = 0
            task.pausedReason = nil
            task.nextRunAt = task.spec?.nextRun(after: .now)
        }
        task.updatedAt = .now
        try? await schedulerRepository.save(task)
        await reloadScheduledTasks()
    }

    func runScheduledTaskNow(_ id: UUID) async -> Bool {
        if let continuityRuntime {
            do { _ = try await continuityRuntime.send(AgentHostCommand(action: .fireSchedule, scheduledTaskID: id)); await reloadScheduledTasks(); return true }
            catch { alertMessage = error.localizedDescription; return false }
        }
        let started = await taskScheduler?.fire(taskID: id, reason: "run now") ?? false
        await reloadScheduledTasks()
        return started
    }

    func deleteScheduledTask(_ id: UUID) async {
        try? await schedulerRepository.delete(id: id)
        await reloadScheduledTasks()
    }

    func scheduledExecutions(_ id: UUID) async -> [ScheduledExecution] {
        (try? await schedulerRepository.executions(taskID: id, limit: 5)) ?? []
    }
}
