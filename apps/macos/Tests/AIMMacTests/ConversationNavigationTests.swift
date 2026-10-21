@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ConversationNavigationTests: XCTestCase {
    func testResumedDurableExecutionShowsWorkingWithoutOriginalSendTask() throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let conversation = UUID()
        model.selectedConversationID = conversation
        var execution = AgentExecution(commandID: UUID(), conversationID: conversation, request: Data())
        for state in ExecutionState.allCases {
            execution.state = state; model.continuityExecutions = [execution]
            XCTAssertEqual(model.conversationIsWorking, state.isRecoverable, state.rawValue)
        }
        execution.state = .running; model.continuityExecutions = [execution]
        model.selectedConversationID = UUID()
        XCTAssertFalse(model.conversationIsWorking, "Another conversation must not acquire this stop button")
        model.isSending = true
        XCTAssertTrue(model.conversationIsWorking)
    }

    func testSelectingModelRemembersItsConversationRouteForNewChat() async throws {
        let repository = MemorySettingsRepository()
        let model = AppModel(database: try AIMDatabase(inMemory: true), settingsRepository: repository)
        model.settings.selectedProvider = .openRouter
        model.settings.selectedModelID = "previous-router-model"
        // Opening a conversation changes the runtime route, not the global default.
        model.selectedProvider = .anthropic
        model.selectedModelID = "conversation-model"
        model.selectProvider(.anthropic) // No-op: the current route is already Anthropic.
        model.availableModels = [ChatModel(id: "chosen-fixture", name: "My chosen model")]
        model.selectModel("chosen-fixture")
        XCTAssertEqual(model.settings.selectedProvider, .anthropic)
        XCTAssertEqual(model.settings.selectedModelID, "chosen-fixture")
        XCTAssertEqual(model.selectedModelPresentation.name, "My chosen model")
        for _ in 0..<100 {
            if await repository.load().selectedModelID == "chosen-fixture" { break }
            await Task.yield()
        }
        let saved = await repository.load()
        XCTAssertEqual(saved.selectedProvider, .anthropic)
        XCTAssertEqual(saved.selectedModelID, "chosen-fixture")
        await model.newConversation()
        XCTAssertEqual(model.selectedProvider, .anthropic)
        XCTAssertEqual(model.selectedModelID, "chosen-fixture")
        XCTAssertEqual(model.selectedModelPresentation.name, "My chosen model")
        XCTAssertFalse(model.showModelPicker)
    }

    func testEmptyPersistedConversationsDoNotAppearInSearch() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        try await repository.save(Conversation(title: "Empty draft"))
        let model = AppModel(database: database)
        let hits = await model.searchConversationHits("Empty")
        XCTAssertTrue(hits.isEmpty)
        let stored = try await repository.list(includeArchived: false)
        XCTAssertEqual(stored.count, 1, "Do not destroy drafts while hiding empty rows")
    }

    func testNewChatAgentSwitchDoesNotOpenRecentConversationOrChangeSavedType() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let agent = Conversation(title: "Existing agent", mode: .agent)
        try await repository.save(agent)
        let model = AppModel(database: database, settingsRepository: MemorySettingsRepository())
        model.conversations = [agent]
        model.selectNewConversationMode(.agent)
        await Task.yield()
        XCTAssertEqual(model.mode, .agent)
        XCTAssertNil(model.selectedConversationID)
        await model.selectConversation(agent.id)
        model.selectNewConversationMode(.chat)
        XCTAssertEqual(model.mode, .agent)
        XCTAssertEqual(model.selectedConversationID, agent.id)
        let saved = try await repository.conversation(id: agent.id)
        XCTAssertEqual(saved?.mode, .agent)
    }

    func testChatSearchIncludesAgentButKeepsCodeSeparate() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let chat = Conversation(title: "Shared subject chat", mode: .chat)
        let agent = Conversation(title: "Shared subject agent", mode: .agent)
        let code = Conversation(title: "Shared subject code", mode: .code)
        for conversation in [chat, agent, code] {
            try await repository.save(conversation)
            try await repository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Hello", sequence: 0))
        }
        let model = AppModel(database: database, settingsRepository: MemorySettingsRepository())
        let chatHits = await model.searchConversationHits("Shared")
        XCTAssertEqual(Set(chatHits.map { $0.conversation.id }), Set([chat.id, agent.id]))
        model.selectMode(.code, restoreRecent: false)
        let codeHits = await model.searchConversationHits("Shared")
        XCTAssertEqual(codeHits.map { $0.conversation.id }, [code.id])
    }

    func testSwitchingToModeWithoutConversationRestoresNewChatRoute() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true), settingsRepository: MemorySettingsRepository())
        model.settings.workspacePath = "/tmp/default-workspace"
        model.settings.selectedProvider = .openAI
        model.settings.selectedModelID = "default-model"
        model.workspacePath = "/tmp/other-conversation"
        model.selectedProvider = .anthropic
        model.selectedModelID = "other-model"
        model.selectMode(.code)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertEqual(model.workspacePath, "/tmp/default-workspace")
        XCTAssertEqual(model.selectedProvider, .openAI)
        XCTAssertEqual(model.selectedModelID, "default-model")
    }

    func testExistingConversationDisclosesCrossProviderHistoryRouting() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Private chat", provider: .openAI, modelID: "fixture")
        try await SQLiteConversationRepository(database: database).save(conversation)
        let model = AppModel(database: database)
        await model.selectConversation(conversation.id)
        XCTAssertFalse(model.needsProviderSwitchDisclosure(to: .openAI))
        XCTAssertTrue(model.needsProviderSwitchDisclosure(to: .anthropic))
        await model.newConversation()
        XCTAssertFalse(model.needsProviderSwitchDisclosure(to: .anthropic))
    }

    func testLateLoadCannotOverrideNewConversation() async throws {
        let old = Conversation(title: "Old", provider: .anthropic, modelID: "old-model", workspacePath: "/tmp/old")
        let repository = DelayedConversationRepository(conversation: old)
        let model = AppModel(database: try AIMDatabase(inMemory: true), conversationRepository: repository)
        model.settings.selectedProvider = .google
        model.settings.selectedModelID = "new-default"
        let loading = Task { await model.selectConversation(old.id) }
        await repository.waitUntilRequested()
        XCTAssertTrue(model.isLoadingConversation)
        await model.newConversation()
        await repository.release()
        await loading.value
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isLoadingConversation)
        XCTAssertEqual(model.selectedProvider, .google)
        XCTAssertEqual(model.selectedModelID, "new-default")
    }
    func testSelectingConversationRestoresItsRouteNotGlobalDefaults() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Project", mode: .code, provider: .anthropic, modelID: "claude-test", workspacePath: "/tmp/work-a")
        try await repository.save(conversation)
        let model = AppModel(database: database)
        model.selectedProvider = .google
        model.selectedModelID = "wrong-model"
        model.workspacePath = "/tmp/wrong-workspace"
        model.workspaceToolsEnabled = true
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.selectedProvider, .anthropic)
        XCTAssertEqual(model.selectedModelID, "claude-test")
        XCTAssertEqual(model.workspacePath, "/tmp/work-a")
        XCTAssertFalse(model.isLoadingConversation)
        XCTAssertFalse(model.workspaceToolsEnabled)
    }

    func testLegacyConversationRequiresExplicitModelAndDoesNotInheritWorkspace() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let legacy = Conversation(title: "Legacy")
        try await repository.save(legacy)
        let model = AppModel(database: database)
        model.selectedModelID = "wrong-model"
        model.workspacePath = "/tmp/wrong-workspace"
        await model.selectConversation(legacy.id)
        XCTAssertEqual(model.selectedModelID, "")
        XCTAssertNil(model.workspacePath)
    }

    func testNewConversationRestoresDefaultsWithoutCreatingEmptyDatabaseRows() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        let old = Conversation(title: "Existing")
        try await SQLiteConversationRepository(database: database).save(old)
        await model.selectConversation(old.id)
        model.settings.selectedProvider = .openAI
        model.settings.selectedModelID = "default-model"
        model.settings.workspacePath = "/tmp/default"
        model.selectedProvider = .anthropic
        model.composerText = "Old draft"
        model.workspaceToolsEnabled = true
        await model.newConversation()
        XCTAssertFalse(model.workspaceToolsEnabled)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertEqual(model.selectedProvider, .openAI)
        XCTAssertEqual(model.selectedModelID, "default-model")
        XCTAssertEqual(model.workspacePath, "/tmp/default")
        XCTAssertEqual(model.composerText, "")
        let rows = try await SQLiteConversationRepository(database: database).list(includeArchived: true)
        XCTAssertEqual(rows.map(\.id), [old.id])
    }

    func testWorkspaceChoicePersistsForExistingConversationBeforeNextMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-workspace-choice-\(UUID())")
        let original = root.appendingPathComponent("original")
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let settingsRepository = MemorySettingsRepository()
        let conversation = Conversation(title: "Code", mode: .code, provider: .openAI,
                                        modelID: "fixture", workspacePath: original.path)
        try await repository.save(conversation)
        let model = AppModel(database: database, settingsRepository: settingsRepository)
        await model.selectConversation(conversation.id)
        let didChoose = await model.chooseWorkspace(replacement.path)
        XCTAssertTrue(didChoose)
        let saved = try await repository.conversation(id: conversation.id)
        XCTAssertEqual(saved?.workspacePath, replacement.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.workspacePath, replacement.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.recentWorkspacePaths.first, replacement.resolvingSymlinksInPath().path)
        let savedSettings = await settingsRepository.load()
        XCTAssertEqual(savedSettings.recentWorkspacePaths?.first, replacement.resolvingSymlinksInPath().path)
        await model.newConversation()
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.workspacePath, replacement.resolvingSymlinksInPath().path)
        let rejected = await model.chooseWorkspace(root.appendingPathComponent("missing").path)
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.workspacePath, replacement.resolvingSymlinksInPath().path)
    }

    func testMissingWorkspaceStopsToolTurnBeforeSendingAndKeepsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-missing-workspace-\(UUID())")
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        model.mode = .code
        model.selectedProvider = .openAI
        model.workspacePath = root.path
        model.workspaceToolsEnabled = true
        model.composerText = "Inspect my project"
        await model.sendComposer()
        XCTAssertEqual(model.composerText, "Inspect my project")
        XCTAssertFalse(model.workspaceToolsEnabled)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.alertMessage?.contains("missing or has moved") == true)
        XCTAssertNil(model.selectedConversationID)
    }

    func testRemoteFingerprintChangesWhenProviderOrFavoritesChangeWithoutAConversation() throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true), settingsRepository: MemorySettingsRepository())
        let initial = model.directRemoteFingerprint
        model.connectedProviders = [.anthropic]
        let connected = model.directRemoteFingerprint
        XCTAssertNotEqual(initial, connected)
        model.settings.favoriteModels = [try FavoriteModel(provider: .anthropic, modelID: "fixture", name: "Fixture")]
        let pinned = model.directRemoteFingerprint
        XCTAssertNotEqual(connected, pinned)
        model.connectedProviders = []
        XCTAssertNotEqual(pinned, model.directRemoteFingerprint)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    func testRemoteCapabilitiesReloadTheUpdatedMacCatalogWithoutGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCatalogCache(directory: directory)
        let model = AppModel(database: try AIMDatabase(inMemory: true), settingsRepository: MemorySettingsRepository())
        model.connectedProviders = [.anthropic]
        let bridge = RemoteHostBridge(model: model, catalogCache: cache)
        let before = await bridge.remoteCapabilities()
        XCTAssertFalse(before.models.contains { $0.provider == "anthropic" && $0.isAvailable == true })
        try await cache.save([ChatModel(id: "claude-sonnet-5-fixture", name: "Fixture Sonnet")], for: .anthropic)
        let after = await bridge.remoteCapabilities()
        let entry = after.models.first { $0.id == "claude-sonnet-5-fixture" && $0.provider == "anthropic" }
        XCTAssertEqual(entry?.isAvailable, true)
        XCTAssertEqual(entry?.isFeatured, false)
        XCTAssertEqual(entry?.isAdded, false)
        model.connectedProviders = []
        let disconnected = await bridge.remoteCapabilities()
        XCTAssertFalse(disconnected.models.contains { $0.provider == "anthropic" && $0.isAvailable == true })
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(model.conversations.isEmpty)
    }

}

private actor MemorySettingsRepository: SettingsRepository {
    private var value = AppSettings()
    func load() -> AppSettings { value }
    func save(_ settings: AppSettings) { value = settings }
}

private actor DelayedConversationRepository: ConversationRepository {
    let stored: Conversation
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(conversation: Conversation) { stored = conversation }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func list(includeArchived: Bool) -> [Conversation] { [stored] }
    func conversation(id: UUID) -> Conversation? { stored }
    func save(_ conversation: Conversation) {}
    func delete(id: UUID) {}
    func append(_ message: ConversationMessage) {}
    func search(_ query: String, limit: Int) -> [Conversation] { [] }
    func messages(conversationID: UUID) async -> [ConversationMessage] {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            requested = true
            requestWaiter?.resume(); requestWaiter = nil
        }
        return [ConversationMessage(conversationID: conversationID, role: .user, content: "Old content", sequence: 0)]
    }
}
