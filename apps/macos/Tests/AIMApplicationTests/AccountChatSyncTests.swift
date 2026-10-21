import AIMCore
import XCTest
@testable import AIMApplication

private final class SyncSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private actor SyncFixture: AccountContentSyncing {
    var values: [UUID: AccountDocument] = [:]
    var writes = 0
    func documents(accountID: UUID) async throws -> [AccountDocument] { Array(values.values) }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard document.revision == (values[document.id]?.revision ?? 0) else { throw AccountServiceError.conflict }
        var next = document; next.revision += 1; values[next.id] = next; writes += 1; return next
    }
    func insert(_ value: AccountDocument) { values[value.id] = value }
}

final class AccountChatSyncTests: XCTestCase {
    func testAddedModelsSyncAutomaticallyWithoutBecomingPinsAndMergeRemovals() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID()
        let sync = AccountChatSync(repository: SQLiteConversationRepository(database: db), projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let service = SyncFixture()
        let addedID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C101")!
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        await service.insert(.init(id: addedID, kind: "favorites", payload: String(decoding: try encoder.encode(["anthropic:phone-added"]), as: UTF8.self), revision: 1))
        let first = try await sync.synchronize(accountID: account, service: service, favorites: ["openrouter:pinned"], preferences: .init(), addedModels: ["openrouter:mac-added"], currentAccount: { account })
        XCTAssertEqual(first.addedModels, ["openrouter:mac-added", "anthropic:phone-added"])
        XCTAssertEqual(first.favorites, ["openrouter:pinned"])
        let documents = try await service.documents(accountID: account)
        let document = try XCTUnwrap(documents.first { $0.id == addedID })
        await service.insert(.init(id: addedID, kind: "favorites", payload: String(decoding: try encoder.encode(first.addedModels.union(["openai:new-phone-model"]).sorted()), as: UTF8.self), revision: document.revision + 1))
        let second = try await sync.synchronize(accountID: account, service: service, favorites: first.favorites, preferences: .init(), addedModels: first.addedModels.subtracting(["openrouter:mac-added"]), currentAccount: { account })
        XCTAssertEqual(second.addedModels, ["anthropic:phone-added", "openai:new-phone-model"])
        XCTAssertEqual(second.favorites, first.favorites)
    }

    func testInputAttachmentsImportAndLegacyRoundTripRemainLossless() async throws {
        let db = try AIMDatabase(inMemory: true), inputID = UUID()
        let repo = SQLiteConversationRepository(database: db)
        let input = NativeChatAttachment(id: inputID, name: "notes.txt", kind: .document, mimeType: "text/plain", text: "Reference")
        let message = NativeChatMessage(role: .user, text: "", attachments: [input])
        let value = NativeChatConversation(title: "With input", provider: .openRouter, modelID: "fixture", messages: [message])
        try await repo.mergePlainChat(value)
        var oldClient = value; oldClient.messages[0].attachments = nil
        try await repo.mergePlainChat(oldClient)
        let restored = try await repo.messages(conversationID: value.id)
        XCTAssertEqual(restored[0].attachments?.first?.id, inputID)
        XCTAssertEqual(restored[0].attachments?.first?.content, "Reference")
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let account = UUID(), service = SyncFixture()
        try await sync.markOwned(value.id, accountID: account)
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let documents = try await service.documents(accountID: account).filter { $0.kind == "chat" }
        let document = try XCTUnwrap(documents.first)
        let exported = try JSONDecoder().decode(NativeChatConversation.self, from: Data(document.payload.utf8))
        XCTAssertEqual(exported.messages[0].attachments, [input])
    }

    func testRound24SourcesRoutesAndActionsSurviveOldClientAndAccountExport() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db)
        var value = chat()
        let source = try XCTUnwrap(ConversationSource(url: "https://example.com/page", title: "Example", references: [1]))
        value.messages[0].sources = [source]
        value.messages[0].routeAttempts = [.init(provider: .openRouter, modelID: "fixture", ordinal: 1, state: .accepted)]
        value.messages[0].actions = [.init(id: "search:1", conversationID: value.id, turnID: value.messages[0].id, ordinal: 0, name: "web_search", state: .completed, input: "actual query", output: "actual output")]
        try await repo.mergePlainChat(value)
        var old = value; old.messages[0].sources = nil; old.messages[0].actions = nil; old.messages[0].routeAttempts = nil
        try await repo.mergePlainChat(old)
        let source2 = try XCTUnwrap(ConversationSource(url: "https://other.example/page", references: [2]))
        try await repo.savePresentation(sources: [source2], routeAttempts: nil, messageID: value.messages[0].id)
        let restored = try await repo.messages(conversationID: value.id)
        XCTAssertEqual(restored[0].sources?.count, 2); XCTAssertEqual(restored[0].routeAttempts, value.messages[0].routeAttempts)
        let account = UUID(), service = SyncFixture()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        try await sync.markOwned(value.id, accountID: account)
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let documents = try await service.documents(accountID: account)
        let document = try XCTUnwrap(documents.first { $0.id == value.id })
        let exported = try JSONDecoder().decode(NativeChatConversation.self, from: Data(document.payload.utf8))
        XCTAssertEqual(exported.messages[0].sources?.count, 2)
        XCTAssertEqual(exported.messages[0].routeAttempts, value.messages[0].routeAttempts)
        XCTAssertEqual(exported.messages[0].actions?.first?.input, "actual query")
        XCTAssertEqual(exported.messages[0].actions?.first?.output, "actual output")
    }

    private func chat() -> NativeChatConversation {
        let message = NativeChatMessage(role: .assistant, text: "An answer", createdAt: Date(timeIntervalSince1970: 10))
        return .init(title: "Portable", provider: .openRouter, modelID: "fixture", messages: [message],
                     turns: [.init(id: message.id, completedAt: Date(timeIntervalSince1970: 11))], updatedAt: Date(timeIntervalSince1970: 12))
    }
    func testRepeatedSyncDoesNotDuplicateMessagesMetricsOrWrites() async throws {
        let db = try AIMDatabase(inMemory: true)
        let repo = SQLiteConversationRepository(database: db), metrics = SQLiteMessageMetricsRepository(database: db)
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: metrics, secureStore: SyncSecrets())
        let service = SyncFixture(), account = UUID(), value = chat()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        await service.insert(.init(id: value.id, kind: "chat", payload: String(decoding: try encoder.encode(value), as: UTF8.self), revision: 1))
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let writes = await service.writes
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let finalWrites = await service.writes, messages = try await repo.messages(conversationID: value.id), reports = try await metrics.metrics(conversationID: value.id)
        XCTAssertEqual(finalWrites, writes); XCTAssertEqual(messages.map(\.id), value.messages.map(\.id)); XCTAssertEqual(reports.count, 1)
    }
    func testAccountChangedWhileFetchingCannotImportOrPublish() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), value = chat()
        let repo = SQLiteConversationRepository(database: db)
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let service = SyncFixture()
        await service.insert(.init(id: value.id, kind: "chat", payload: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), revision: 1))
        do {
            _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { nil })
            XCTFail("Changed account must refuse sync")
        } catch AccountServiceError.revoked { }
        let local = try await repo.list(includeArchived: true), writes = await service.writes
        XCTAssertTrue(local.isEmpty); XCTAssertEqual(writes, 0)
    }
    func testPartialSnapshotCannotRemoveMessagesOrAlterSequences() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db)
        let value = chat(); try await repo.mergePlainChat(value)
        var incomplete = value; incomplete.messages = []; incomplete.turns = []
        do { try await repo.mergePlainChat(incomplete); XCTFail("Lossy snapshot must be refused") } catch AccountServiceError.conflict { }
        let messages = try await repo.messages(conversationID: value.id)
        XCTAssertEqual(messages.map(\.content), ["An answer"]); XCTAssertEqual(messages.map(\.sequence), [0])
    }
    func testUnattributedHistoricalChatIsNeverUploadedImplicitly() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db), value = chat(), account = UUID()
        try await repo.mergePlainChat(value)
        let service = SyncFixture()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let cloud = try await service.documents(accountID: account), local = try await repo.messages(conversationID: value.id)
        XCTAssertFalse(cloud.contains { $0.kind == "chat" }); XCTAssertEqual(local.count, 1)
    }
    func testAddedLibraryCannotBecomeMacPinsAndWebReportsSurviveRoundTrip() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db), account = UUID()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let service = SyncFixture()
        var value = chat()
        value.messages[0].webSearchUsage = .init(requests: 2, additionalCostUSD: 0.01)
        value.messages[0].webSearchActivities = [.init(id: "search-fixture", status: .completed)]
        value.messages[0].skillActivities = [.init(id: "skill-fixture", name: "skill_view", skill: "research")]
        value.messages[0].mediaAssetIDs = [UUID()]
        let addedID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C101")!
        let pinsID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C103")!
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let addedPayload = String(decoding: try encoder.encode(["openrouter:added-only"]), as: UTF8.self)
        await service.insert(.init(id: addedID, kind: "favorites", payload: addedPayload, revision: 1))
        await service.insert(.init(id: pinsID, kind: "favorites", payload: String(decoding: try encoder.encode(["openrouter:pinned"]), as: UTF8.self), revision: 1))
        await service.insert(.init(id: value.id, kind: "chat", payload: String(decoding: try encoder.encode(value), as: UTF8.self), revision: 1))
        let result = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        XCTAssertEqual(result.favorites, ["openrouter:pinned"])
        let docs = try await service.documents(accountID: account)
        XCTAssertEqual(docs.first { $0.id == addedID }?.payload, addedPayload)
        let payload = try XCTUnwrap(docs.first { $0.id == value.id }?.payload)
        let roundTrip = try JSONDecoder().decode(NativeChatConversation.self, from: Data(payload.utf8))
        XCTAssertEqual(roundTrip.messages[0].webSearchUsage, value.messages[0].webSearchUsage)
        XCTAssertEqual(roundTrip.messages[0].webSearchActivities, value.messages[0].webSearchActivities)
        XCTAssertEqual(roundTrip.messages[0].skillActivities, value.messages[0].skillActivities)
        XCTAssertEqual(roundTrip.messages[0].mediaAssetIDs, value.messages[0].mediaAssetIDs)
    }
}

extension AccountChatSyncTests {
    func testContinuityMetadataImportDoesNotInventMacExecutionAndReceiptsRoundTrip() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), service = SyncFixture(), secrets = SyncSecrets()
        let repo = SQLiteConversationRepository(database: db)
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: secrets)
        var value = NativeChatConversation(title: "Phone", provider: .openRouter, modelID: "test", messages: [.init(role: .assistant, text: "done")], executionDeviceIDs: ["iphone"])
        let version = ConversationResponseVersion(id: value.messages[0].id.uuidString, completedAt: .now)
        value.latestResponseVersion = version
        await service.insert(.init(id: value.id, kind: "chat", payload: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), revision: 1))
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let imported = try await sync.continuityState(accountID: account)
        XCTAssertEqual(imported.executionDeviceIDs[value.id], ["iphone"])
        XCTAssertEqual(imported.responseVersions[value.id], version)
        try await sync.acknowledge(conversationID: value.id, response: version, accountID: account)
        let result = try await sync.synchronizeReadReceipts(accountID: account, service: service, currentAccount: { account })
        XCTAssertTrue(result.receipts.contains(conversationID: value.id.uuidString, response: version))
        let documents = try await service.documents(accountID: account)
        let doc = try XCTUnwrap(documents.first { $0.id == ConversationReadReceiptSync.documentID })
        let phone = try JSONDecoder().decode(ConversationReadReceipts.self, from: Data(doc.payload.utf8))
        XCTAssertTrue(phone.contains(conversationID: value.id.uuidString, response: version))
        XCTAssertFalse(phone.contains(conversationID: value.id.uuidString, response: .init(id: "future", completedAt: .now)))
        try await sync.recordExecution(conversationID: value.id, deviceID: "mac", accountID: account)
        let executed = try await sync.continuityState(accountID: account)
        XCTAssertEqual(Set(executed.executionDeviceIDs[value.id] ?? []), ["iphone", "mac"])
        let other = try await sync.continuityState(accountID: UUID())
        XCTAssertTrue(other.responseVersions.isEmpty); XCTAssertTrue(other.receipts.receipts.isEmpty)
    }
    func testRuntimeLedgerIsAccountScopedAndHistoricalSnapshotsAreNeutral() async throws {
        let secrets = SyncSecrets(), account = UUID(), other = UUID(), conversation = UUID()
        XCTAssertTrue(try RuntimeConversationContinuity.load(accountID: account, store: secrets).responseVersions.isEmpty)
        var ledger = RuntimeConversationContinuity()
        let execution = UUID(), response = ConversationResponseVersion(id: UUID().uuidString, completedAt: .now)
        ledger.trackedExecutions[execution] = conversation; ledger.executionDeviceIDs[conversation] = ["mac"]
        ledger.responseVersions[conversation] = response; try ledger.save(accountID: account, store: secrets)
        XCTAssertEqual(try RuntimeConversationContinuity.load(accountID: account, store: secrets), ledger)
        XCTAssertTrue(try RuntimeConversationContinuity.load(accountID: other, store: secrets).trackedExecutions.isEmpty)
    }
}

extension AccountChatSyncTests {
    func testNewTurnMetadataOnHistoricalConversationDoesNotAdoptOrUploadItsContent() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), service = SyncFixture()
        let repo = SQLiteConversationRepository(database: db), conversation = NativeChatConversation(title: "Old local", provider: .openRouter, modelID: "test")
        try await repo.mergePlainChat(conversation)
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        try await sync.recordExecution(conversationID: conversation.id, deviceID: "mac", accountID: account)
        try await sync.recordResponse(conversationID: conversation.id, response: .init(id: "new-answer", completedAt: .now), accountID: account)
        let state = try await sync.continuityState(accountID: account)
        XCTAssertEqual(state.executionDeviceIDs[conversation.id], ["mac"])
        XCTAssertEqual(state.responseVersions[conversation.id]?.id, "new-answer")
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let docs = try await service.documents(accountID: account)
        XCTAssertFalse(docs.contains { $0.kind == "chat" })
    }
}

extension AccountChatSyncTests {
    func testKnownLegacyReadStatePreservesReadUnreadAndIgnoresRenameUnknownAndOtherAccount() async throws {
        let db = try AIMDatabase(inMemory: true), owner = UUID(), other = UUID()
        let repo = SQLiteConversationRepository(database: db), metrics = SQLiteMessageMetricsRepository(database: db)
        let secrets = SyncSecrets()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: metrics, secureStore: secrets)
        let readAt = Date(timeIntervalSince1970: 100)
        var ids: [String: UUID] = [:], responses: [String: ConversationResponseVersion] = [:]
        for (name, date, known) in [("read", 99.0, true), ("tolerance", 100.75, true), ("unread", 105.0, true), ("unknown", 105.0, false), ("other", 105.0, true)] {
            var conversation = Conversation(title: name, mode: .chat)
            try await repo.save(conversation)
            let message = ConversationMessage(conversationID: conversation.id, role: .assistant, content: "completed fixture", sequence: 0, createdAt: .init(timeIntervalSince1970: date))
            try await repo.append(message)
            // A later cancelled answer must not become the completed response version.
            try await repo.append(.init(conversationID: conversation.id, role: .assistant, content: "partial", sequence: 1, createdAt: .init(timeIntervalSince1970: 110), completionStatus: .cancelled))
            if known { try await metrics.markRead(conversationID: conversation.id, at: readAt) }
            conversation.title = "renamed"; conversation.updatedAt = .init(timeIntervalSince1970: 1000)
            try await repo.save(conversation)
            ids[name] = conversation.id; responses[name] = .init(id: message.id.uuidString, completedAt: message.createdAt)
        }
        try await sync.markOwned(ids["other"]!, accountID: other)
        let metadata = try await metrics.knownLegacyReadState()
        XCTAssertTrue(metadata[ids["read"]!]!.wasRead)
        XCTAssertTrue(metadata[ids["tolerance"]!]!.wasRead)
        XCTAssertFalse(metadata[ids["unread"]!]!.wasRead)
        XCTAssertNil(metadata[ids["unknown"]!])
        try await sync.restoreKnownLegacyReadState(accountID: owner)
        let state = try await sync.continuityState(accountID: owner)
        for name in ["read", "tolerance", "unread"] { XCTAssertEqual(state.responseVersions[ids[name]!], responses[name]!) }
        XCTAssertTrue(state.receipts.contains(conversationID: ids["read"]!.uuidString, response: responses["read"]))
        XCTAssertTrue(state.receipts.contains(conversationID: ids["tolerance"]!.uuidString, response: responses["tolerance"]))
        XCTAssertFalse(state.receipts.contains(conversationID: ids["unread"]!.uuidString, response: responses["unread"]))
        XCTAssertNil(state.responseVersions[ids["unknown"]!]); XCTAssertNil(state.responseVersions[ids["other"]!])
        XCTAssertTrue(state.executionDeviceIDs.isEmpty)
        let helperState = try AccountChatSync.cachedContinuityState(accountID: owner, secureStore: secrets)
        XCTAssertEqual(helperState.responseVersions, state.responseVersions)
        XCTAssertEqual(helperState.receipts, state.receipts)
        XCTAssertTrue(try AccountChatSync.cachedContinuityState(accountID: UUID(), secureStore: secrets).responseVersions.isEmpty)
        // Restoration never adopts the historical content or uploads it.
        let service = SyncFixture()
        _ = try await sync.synchronize(accountID: owner, service: service, favorites: [], preferences: .init(), currentAccount: { owner })
        let docs = try await service.documents(accountID: owner)
        XCTAssertFalse(docs.contains { $0.kind == "chat" })
        // Repeated restoration cannot acknowledge a new response using the old read timestamp.
        let future = ConversationResponseVersion(id: UUID().uuidString, completedAt: .init(timeIntervalSince1970: 200))
        try await sync.recordResponse(conversationID: ids["read"]!, response: future, accountID: owner)
        try await sync.restoreKnownLegacyReadState(accountID: owner)
        let repeated = try await sync.continuityState(accountID: owner)
        XCTAssertEqual(repeated.responseVersions[ids["read"]!], future)
        XCTAssertFalse(repeated.receipts.contains(conversationID: ids["read"]!.uuidString, response: future))
    }
}


extension AccountChatSyncTests {
    func testLocalOwnershipStaysSeparateFromAccountAndIsNeverUploadedAtLogin() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db)
        let store = SyncSecrets(), account = UUID(), service = SyncFixture()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: store)
        let identity = AppIdentity.local(try LocalProfile.loadOrCreate(store: store))
        let local = chat(), historical = chat()
        try await repo.mergePlainChat(local)
        try await repo.mergePlainChat(historical)
        try await sync.markOwned(local.id, identity: identity)
        let localVisible = try await sync.isVisible(local.id, identity: identity)
        let localAccountVisible = try await sync.isVisible(local.id, identity: .account(.init(id: account, email: nil, fullName: nil)))
        let historyAccountVisible = try await sync.isVisible(historical.id, accountID: account)
        XCTAssertTrue(localVisible)
        XCTAssertFalse(localAccountVisible)
        XCTAssertFalse(historyAccountVisible)
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let documents = try await service.documents(accountID: account)
        XCTAssertFalse(documents.contains { $0.kind == "chat" })
        do { try await sync.markOwned(local.id, accountID: account); XCTFail("Login cannot adopt local ownership") }
        catch AccountServiceError.conflict {}
        let afterLogout = try await sync.isVisible(local.id, identity: identity)
        XCTAssertTrue(afterLogout)
    }
}

extension AccountChatSyncTests {
    func testReviewedLocalCopyKeepsOriginalsAndDestinationSeparateAndRetriesWithoutOverwrite() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db)
        let projects = SQLiteProjectRepository(database: db), secrets = SyncSecrets(), account = UUID()
        let profile = try LocalProfile.loadOrCreate(store: secrets)
        let sync = AccountChatSync(repository: repo, projects: projects, metrics: SQLiteMessageMetricsRepository(database: db), secureStore: secrets)
        let project = AIMApplication.AIMProject(name: "Local project", instructions: "Reviewed instructions")
        try await projects.save(project)
        try await sync.markOwned(project.id, identity: .local(profile))
        var source = chat(); source.projectID = project.id.uuidString
        source.messages.insert(.init(role: .user, text: "Local input", attachments: [.init(name: "notes.txt", kind: .document, mimeType: "text/plain", text: "Selected attachment")]), at: 0)
        try await repo.mergePlainChat(source)
        try await sync.markOwned(source.id, identity: .local(profile))
        let historical = chat(); try await repo.mergePlainChat(historical)
        let destination = chat(); try await repo.mergePlainChat(destination); try await sync.markOwned(destination.id, accountID: account)
        let preview = try await sync.previewLocalCopy(profile: profile, accountID: account, currentAccount: { account })
        XCTAssertEqual(Set(preview.items.map(\.id)), [source.id, historical.id])
        XCTAssertEqual(preview.items.first { $0.id == source.id }?.projectInstructions, project.instructions)
        let before = try await repo.list(includeArchived: true)
        XCTAssertEqual(before.count, 3, "Preview and sign-in do not copy histories")
        let count = try await sync.copyLocalToAccount(preview, selectedIDs: [source.id], currentAccount: { account })
        XCTAssertEqual(count, 1)
        let all = try await repo.list(includeArchived: true)
        let copied = try XCTUnwrap(all.first { ![source.id, historical.id, destination.id].contains($0.id) })
        XCTAssertNotEqual(copied.projectID, project.id)
        let originalRows = try await repo.messages(conversationID: source.id)
        var copiedRows = try await repo.messages(conversationID: copied.id)
        XCTAssertEqual(originalRows.map(\.id), source.messages.map(\.id))
        XCTAssertEqual(copiedRows.map(\.content), originalRows.map(\.content))
        XCTAssertTrue(Set(copiedRows.map(\.id)).isDisjoint(with: originalRows.map(\.id)))
        XCTAssertEqual(copiedRows.first?.attachments?.first?.content, "Selected attachment")
        let localVisible = try await sync.isVisible(source.id, identity: .local(profile))
        let accountSourceVisible = try await sync.isVisible(source.id, accountID: account)
        let accountCopyVisible = try await sync.isVisible(copied.id, accountID: account)
        XCTAssertTrue(localVisible); XCTAssertFalse(accountSourceVisible); XCTAssertTrue(accountCopyVisible)
        copiedRows[0].content = "Local input with destination edit"
        try await repo.savePresentation(sources: nil, routeAttempts: nil, streamedContent: "Local input with destination edit", messageID: copiedRows[0].id)
        _ = try await sync.copyLocalToAccount(preview, selectedIDs: [source.id], currentAccount: { account })
        let retried = try await repo.list(includeArchived: true), afterRetry = try await repo.messages(conversationID: copied.id)
        XCTAssertEqual(retried.count, 4)
        XCTAssertEqual(afterRetry.first?.content, "Local input with destination edit", "Retry preserves destination edits")
        let service = SyncFixture()
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let uploaded = try await service.documents(accountID: account)
        XCTAssertNotNil(uploaded.first { $0.id == copied.id })
        XCTAssertNil(uploaded.first { $0.id == source.id || $0.id == historical.id })
    }

    func testReviewedCopyRefusesChangedSourceUnknownSelectionAndChangedAccount() async throws {
        let db = try AIMDatabase(inMemory: true), repo = SQLiteConversationRepository(database: db), store = SyncSecrets(), account = UUID()
        let sync = AccountChatSync(repository: repo, projects: SQLiteProjectRepository(database: db), metrics: SQLiteMessageMetricsRepository(database: db), secureStore: store)
        let profile = try LocalProfile.loadOrCreate(store: store), source = chat()
        try await repo.mergePlainChat(source) // Legacy ownerless history remains eligible for explicit copy.
        let preview = try await sync.previewLocalCopy(profile: profile, accountID: account, currentAccount: { account })
        do { _ = try await sync.copyLocalToAccount(preview, selectedIDs: [UUID()], currentAccount: { account }); XCTFail("Unreviewed selection must fail") }
        catch AccountServiceError.conflict {}
        do { _ = try await sync.copyLocalToAccount(preview, selectedIDs: [source.id], currentAccount: { nil }); XCTFail("Changed account must fail") }
        catch AccountServiceError.conflict {}
        var changed = source; changed.title = "Changed after review"; try await repo.mergePlainChat(changed)
        do { _ = try await sync.copyLocalToAccount(preview, selectedIDs: [source.id], currentAccount: { account }); XCTFail("Changed history requires a new review") }
        catch AccountServiceError.conflict {}
        let stored = try await repo.list(includeArchived: true)
        XCTAssertEqual(stored.count, 1); XCTAssertEqual(stored.first?.id, source.id)
    }
}

private actor OrderedProjectSyncFixture: AccountContentSyncing {
    var values: [AccountDocument]
    init(_ values: [AccountDocument]) { self.values = values }
    func documents(accountID: UUID) async throws -> [AccountDocument] { values }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        var value = document; value.revision += 1
        if let index = values.firstIndex(where: { $0.id == document.id }) { values[index] = value } else { values.append(value) }
        return value
    }
    func replace(_ value: AccountDocument) {
        values.removeAll { $0.id == value.id }; values.append(value)
    }
}

extension AccountChatSyncTests {
    func testIOSProjectPrivacyAndPinSurviveMacRenameAndLegacyClientPayload() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), service = SyncFixture()
        let projects = SQLiteProjectRepository(database: db)
        let sync = AccountChatSync(repository: SQLiteConversationRepository(database: db), projects: projects, metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let incoming = NativeChatProject(name: "Private source", instructions: "Retain rules", isPinned: true, memoryScope: .projectOnly, createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
        await service.insert(.init(id: incoming.id, kind: "project", payload: String(decoding: try JSONEncoder().encode(incoming), as: UTF8.self), revision: 1))
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let imported = try await projects.list()
        var retained = try XCTUnwrap(imported.first)
        XCTAssertEqual(retained.usesGlobalMemory, false); XCTAssertEqual(retained.isPinned, true)
        retained.name = "Mac rename"; retained.updatedAt = Date(timeIntervalSince1970: 20)
        try await projects.save(retained)
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        var documents = try await service.documents(accountID: account)
        var document = try XCTUnwrap(documents.first { $0.id == incoming.id })
        let exported = try JSONDecoder().decode(NativeChatProject.self, from: Data(document.payload.utf8))
        XCTAssertEqual(exported.name, "Mac rename"); XCTAssertTrue(exported.isPinned); XCTAssertEqual(exported.memoryScope, .projectOnly)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any])
        old.removeValue(forKey: "isPinned"); old.removeValue(forKey: "memoryScope")
        old["name"] = "Legacy rename"; old["updatedAt"] = Date(timeIntervalSince1970: 30).timeIntervalSinceReferenceDate
        await service.insert(.init(id: incoming.id, kind: "project", payload: String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self), revision: document.revision + 1))
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        documents = try await service.documents(accountID: account); document = try XCTUnwrap(documents.first { $0.id == incoming.id })
        let final = try JSONDecoder().decode(NativeChatProject.self, from: Data(document.payload.utf8))
        XCTAssertEqual(final.name, "Legacy rename"); XCTAssertTrue(final.isPinned); XCTAssertEqual(final.memoryScope, .projectOnly)
        let reloaded = try await SQLiteProjectRepository(database: db).list()
        XCTAssertEqual(reloaded.first?.isPinned, true); XCTAssertEqual(reloaded.first?.usesGlobalMemory, false)
    }

    func testNewerMacNameLearnsPreviouslyUnknownIOSPrivacyMetadata() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), service = SyncFixture()
        let projects = SQLiteProjectRepository(database: db)
        let sync = AccountChatSync(repository: SQLiteConversationRepository(database: db), projects: projects, metrics: SQLiteMessageMetricsRepository(database: db), secureStore: SyncSecrets())
        let local = AIMApplication.AIMProject(name: "Newer Mac name", updatedAt: Date(timeIntervalSince1970: 100))
        try await projects.save(local); try await sync.markOwned(local.id, accountID: account)
        let incoming = NativeChatProject(id: local.id, name: "Older phone name", isPinned: true, memoryScope: .projectOnly, updatedAt: Date(timeIntervalSince1970: 10))
        await service.insert(.init(id: incoming.id, kind: "project", payload: String(decoding: try JSONEncoder().encode(incoming), as: UTF8.self), revision: 1))
        _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
        let stored = try await projects.list()
        XCTAssertEqual(stored.first?.name, local.name); XCTAssertEqual(stored.first?.usesGlobalMemory, false); XCTAssertEqual(stored.first?.isPinned, true)
    }

    func testProjectTombstonesHideWithoutDeletingSourcesChatsOrAllowingResurrection() async throws {
        for tombstoneFirst in [true, false] {
            let db = try AIMDatabase(inMemory: true), account = UUID(), secrets = SyncSecrets()
            let repo = SQLiteConversationRepository(database: db), projects = SQLiteProjectRepository(database: db)
            let sync = AccountChatSync(repository: repo, projects: projects, metrics: SQLiteMessageMetricsRepository(database: db), secureStore: secrets)
            let project = AIMApplication.AIMProject(name: "Recoverable project")
            try await projects.save(project); try await sync.markOwned(project.id, accountID: account)
            let source = ProjectSource(projectID: project.id, canonicalPath: "/tmp/synthetic-source-folder", displayName: "Retained folder")
            try await projects.save(source: source)
            let documents = SQLiteProjectDocumentRepository(database: db)
            let reference = ProjectDocument(projectID: project.id, name: "private.txt", content: "Retained private source")
            try await documents.add(reference)
            var conversation = chat(); conversation.projectID = project.id.uuidString
            try await repo.mergePlainChat(conversation); try await sync.markOwned(conversation.id, accountID: account)
            let deleted = AccountDocument(id: project.id, kind: "project", payload: "{}", revision: 2, deleted: true)
            let chatRecord = AccountDocument(id: conversation.id, kind: "chat", payload: String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self), revision: 1)
            let service = OrderedProjectSyncFixture(tombstoneFirst ? [deleted, chatRecord] : [chatRecord, deleted])
            _ = try await sync.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
            let visible = try await sync.isVisible(project.id, accountID: account)
            let stored = try await projects.list(), sources = try await projects.sources(projectID: project.id)
            let retainedDocuments = try await documents.list(projectID: project.id), retained = try await repo.conversation(id: conversation.id)
            let messages = try await repo.messages(conversationID: conversation.id)
            XCTAssertFalse(visible); XCTAssertEqual(stored.map(\.id), [project.id])
            XCTAssertEqual(sources.map(\.id), [source.id]); XCTAssertEqual(sources.first?.canonicalPath, source.canonicalPath)
            XCTAssertEqual(retainedDocuments.map(\.content), [reference.content]); XCTAssertNil(retained?.projectID)
            XCTAssertEqual(messages.first?.content, conversation.messages.first?.text)
            let stale = NativeChatProject(id: project.id, name: "Stale client resurrection", updatedAt: .distantFuture)
            await service.replace(.init(id: project.id, kind: "project", payload: String(decoding: try JSONEncoder().encode(stale), as: UTF8.self), revision: 3))
            let reopened = AccountChatSync(repository: repo, projects: projects, metrics: SQLiteMessageMetricsRepository(database: db), secureStore: secrets)
            _ = try await reopened.synchronize(accountID: account, service: service, favorites: [], preferences: .init(), currentAccount: { account })
            let stillVisible = try await reopened.isVisible(project.id, accountID: account)
            let final = try await projects.list()
            XCTAssertFalse(stillVisible); XCTAssertEqual(final.first?.name, project.name)
        }
    }
}
