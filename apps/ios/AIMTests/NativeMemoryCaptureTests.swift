import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class CaptureTestSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { Data("fixture-key".utf8) }
    func removeData(forKey key: String) throws {}
}
private actor CaptureTestDocuments: AccountContentSyncing {
    let accountID: UUID
    private var rows: [UUID: AccountDocument] = [:]
    init(accountID: UUID) throws {
        self.accountID = accountID
        var snapshot = AccountMemorySnapshot(); snapshot.enabled = true
        rows[AccountMemoryService.documentID] = .init(id: AccountMemoryService.documentID, kind: "memory",
            payload: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self), revision: 1)
    }
    func documents(accountID: UUID) async throws -> [AccountDocument] {
        guard accountID == self.accountID else { throw AccountServiceError.conflict }
        return Array(rows.values)
    }
    func document(_ id: UUID) -> AccountDocument? { rows[id] }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard accountID == self.accountID, (rows[document.id]?.revision ?? 0) == document.revision else { throw AccountServiceError.conflict }
        var saved = document; saved.revision += 1; rows[saved.id] = saved; return saved
    }
}
private final class CaptureHTTPState: @unchecked Sendable {
    enum Mode { case normal, primaryFailure, expensivePrimary, holdCapture, holdPrimary }
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private var storedMode: Mode = .normal
    private var held: [String: CaptureHTTPProtocol] = [:]
    func reset(_ mode: Mode) { lock.lock(); defer { lock.unlock() }; bodies = []; held = [:]; storedMode = mode }
    func add(_ body: [String: Any]) -> Mode { lock.lock(); defer { lock.unlock() }; bodies.append(body); return storedMode }
    func hold(_ request: CaptureHTTPProtocol, query: String) { lock.lock(); held[query] = request; lock.unlock() }
    func complete(_ query: String) { lock.lock(); let request = held.removeValue(forKey: query); lock.unlock(); request?.emit(text: "Response for " + query) }
    func requests() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
}
private final class CaptureHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = CaptureHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
            data = result
        }
        guard let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let mode = Self.state.add(body)
        let messages = body["messages"] as? [[String: String]] ?? []
        let capture = messages.contains { ($0["content"] ?? "").contains(AccountMemoryCapture.instruction) }
        if capture && mode == .holdCapture { return }
        if !capture && mode == .holdPrimary {
            Self.state.hold(self, query: messages.last?["content"] ?? ""); return
        }
        let status = !capture && mode == .primaryFailure ? 500 : 200
        let text = capture ? #"{"memories":[{"kind":"preference","subject":"answer language","content":"The user prefers concise French answers.","evidence":"I prefer concise French answers"}]}"# : "Fixture response"
        let usage = ["prompt_tokens": capture ? 40 : 100, "completion_tokens": capture ? 10 : (mode == .expensivePrimary ? 8192 : 20)]
        let event: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]], "usage": usage]
        let payload = try! JSONSerialization.data(withJSONObject: event)
        let sse = Data("data: \(String(decoding: payload, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: sse); client?.urlProtocolDidFinishLoading(self)
    }
    func emit(text: String) {
        let event: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]], "usage": ["prompt_tokens": 10, "completion_tokens": 5]]
        let payload = try! JSONSerialization.data(withJSONObject: event)
        let sse = Data("data: \(String(decoding: payload, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: sse); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class NativeMemoryCaptureTests: XCTestCase {
    private let source = "Remember that I prefer concise French answers."
    private var budgetEnabled: Any?
    private var budgetLimit: Any?
    private var outputLimit: Any?
    private var fixtureService: CaptureTestDocuments?
    private func fixture(priced: Bool = true, notifyCompletion: (@MainActor (UUID, UUID, UUID, UUID, AIMNotificationCategory) async -> Void)? = nil) async throws -> NativeChatStore {
        budgetEnabled = UserDefaults.standard.object(forKey: "aim.budget.enabled"); budgetLimit = UserDefaults.standard.object(forKey: "aim.budget.limit"); outputLimit = UserDefaults.standard.object(forKey: "aim.chat.output-tokens"); UserDefaults.standard.removeObject(forKey: "aim.chat.output-tokens")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled"); CaptureHTTPProtocol.state.reset(.normal)
        let id = UUID(), service = try CaptureTestDocuments(accountID: id); fixtureService = service
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let store = NativeChatStore(accountID: id, sync: service, credentials: CaptureTestSecrets(),
            transport: NativeChatTransport(session: URLSession(configuration: configuration)),
            notifyCompletion: notifyCompletion ?? { _, _, _, _, _ in })
        store.provider = .openRouter; store.modelID = "fixture/model"
        var model = ChatModel(id: "fixture/model", name: "Fixture text model", maxOutputTokens: 8192)
        if priced { model.pricing = .init(prompt: "0.000001", completion: "0.000001") }
        store.models = [model]; store.preferences.automaticWebSearch = false; await store.syncAccountData()
        return store
    }
    private func clean(_ store: NativeChatStore) {
        UserDefaults.standard.set(budgetEnabled, forKey: "aim.budget.enabled"); UserDefaults.standard.set(budgetLimit, forKey: "aim.budget.limit"); UserDefaults.standard.set(outputLimit, forKey: "aim.chat.output-tokens")
        let directory = URL.applicationSupportDirectory.appending(path: "Chat/\(store.accountID.uuidString)", directoryHint: .isDirectory)
        // XCTest teardown runs after local stores (including restored copies)
        // leave scope. Never unlink a live ProjectSourceStore SQLite handle.
        addTeardownBlock { @MainActor [weak store] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while store != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard store == nil else { return XCTFail("Fixture still owns SQLite resources; retained for diagnosis") }
            try FileManager.default.removeItem(at: directory)
        }
    }
    func testSlowNotificationCannotHoldTheComposerOrExtendTaskDuration() async throws {
        let delivering = expectation(description: "Notification delivery started")
        var release: CheckedContinuation<Void, Never>?
        let store = try await fixture(notifyCompletion: { _, _, _, _, _ in
            delivering.fulfill()
            await withCheckedContinuation { release = $0 }
        })
        defer { release?.resume(); clean(store) }
        store.memory.enabled = false
        let admitted = await store.send("A short fixture question.")
        XCTAssertTrue(admitted)
        await fulfillment(of: [delivering], timeout: 3)
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.selected?.messages.last?.text, "Fixture response")
        let completedTask = try XCTUnwrap(store.activityRecords.first { $0.kind == .task })
        XCTAssertNotNil(completedTask.completedAt)
        await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 1)
        XCTAssertEqual(store.activityRecords.first { $0.kind == .task }?.completedAt, completedTask.completedAt)
    }
    func testSuccessfulCaptureUsesOriginalProviderModelProjectAndMetersAdditionalTokens() async throws {
        let store = try await fixture(); defer { clean(store) }
        let project = UUID()
        XCTAssertTrue(store.saveProject(.init(id: project, name: "QA memory project")))
        XCTAssertTrue(store.projects.contains { $0.id == project })
        store.selectedProjectID = project
        let admitted = await store.send(source); XCTAssertTrue(admitted)
        store.provider = .anthropic; store.modelID = "changed/model"; store.selectedProjectID = UUID()
        await store.waitForResponse()
        let requests = CaptureHTTPProtocol.state.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0["model"] as? String == "fixture/model" })
        XCTAssertEqual(requests.last?["max_tokens"] as? Int, AccountMemoryCapture.maxOutputTokens)
        XCTAssertNil(requests.last?["plugins"]); XCTAssertNil(requests.last?["tools"])
        let entry = try XCTUnwrap(store.memory.entries.first)
        XCTAssertEqual(entry.projectID, project); XCTAssertFalse(entry.reviewed); XCTAssertEqual(entry.reviewStatus, "provisional")
        XCTAssertEqual(entry.sourceID, store.conversations.first?.messages.first?.id.uuidString)
        let memory = try XCTUnwrap(store.activityRecords.first { $0.mode == "memory" })
        XCTAssertEqual(memory.provider, ChatProvider.openRouter.rawValue); XCTAssertEqual(memory.totalTokens, 50)
        XCTAssertEqual(memory.costState, .estimated); XCTAssertNotNil(memory.parentTaskID)
        XCTAssertEqual(store.summary.tokens, 170)
        XCTAssertNil(store.errorMessage)
    }
    func testFailedChatNeverStartsCapture() async throws {
        let store = try await fixture(); defer { clean(store) }; CaptureHTTPProtocol.state.reset(.primaryFailure)
        _ = await store.send(source); await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 1)
        XCTAssertTrue(store.memory.entries.isEmpty); XCTAssertFalse(store.activityRecords.contains { $0.mode == "memory" })
        XCTAssertNotNil(store.errorMessage)
    }
    func testUnknownCapturePriceDoesNotBlockAnAdditionalRequestWhenBudgetIsOff() async throws {
        let store = try await fixture(priced: false); defer { clean(store) }
        _ = await store.send(source); await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 2)
        XCTAssertEqual(store.memory.entries.count, 1)
        XCTAssertEqual(store.activityRecords.first { $0.mode == "memory" }?.costState, .unknown)
        XCTAssertNil(store.errorMessage); XCTAssertEqual(store.conversations.first?.messages.last?.text, "Fixture response")
    }
    func testBudgetCannotBeExceededByTheAdditionalCaptureRequest() async throws {
        let store = try await fixture(); defer { clean(store) }; CaptureHTTPProtocol.state.reset(.expensivePrimary)
        let maximum = try XCTUnwrap(DeviceBudgetRules.upperBound(inputBytes: 256 + source.utf8.count, maxOutputTokens: 8192, pricing: store.models[0].pricing))
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled"); UserDefaults.standard.set(maximum, forKey: "aim.budget.limit")
        let admitted = await store.send(source); XCTAssertTrue(admitted); await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 1)
        XCTAssertTrue(store.memoryCaptureMessage?.contains("budget") == true); XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.activityRecords.contains { $0.mode == "memory" })
    }
    func testStoppingTheParentTaskCancelsCaptureWithoutSavingProposals() async throws {
        let store = try await fixture(); defer { clean(store) }; CaptureHTTPProtocol.state.reset(.holdCapture)
        _ = await store.send(source)
        let deadline = Date().addingTimeInterval(3)
        while CaptureHTTPProtocol.state.requests().count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 2)
        await store.stopAndWait()
        XCTAssertTrue(store.memory.entries.isEmpty); XCTAssertFalse(store.isSending); XCTAssertFalse(store.isCapturingMemory)
        let memory = try XCTUnwrap(store.activityRecords.first { $0.mode == "memory" })
        XCTAssertEqual(memory.costState, .reserved, "A canceled inference with no receipt must not pretend the cost is zero")
        XCTAssertNotNil(memory.completedAt)
    }
    private func waitForRequests(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while CaptureHTTPProtocol.state.requests().count < count && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, count)
    }
    func testIndependentConversationsCaptureModelsAndCancelOnlyTheirOwnResponse() async throws {
        let store = try await fixture(); defer { clean(store) }
        store.memory.enabled = false; CaptureHTTPProtocol.state.reset(.holdPrimary)
        let firstAdmitted = await store.send("first"); XCTAssertTrue(firstAdmitted)
        let firstID = try XCTUnwrap(store.selectedID)
        store.newConversation(); store.draftText = "second draft"
        let secondModel = ChatModel(id: "fixture/second", name: "Second")
        store.modelID = secondModel.id; store.models = [secondModel]
        let secondAdmitted = await store.send("second"); XCTAssertTrue(secondAdmitted)
        let secondID = try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(store.isSending(conversationID: firstID)); XCTAssertTrue(store.isSending(conversationID: secondID))
        let duplicate = await store.send("duplicate"); XCTAssertFalse(duplicate)
        try await waitForRequests(2)
        XCTAssertEqual(Set(CaptureHTTPProtocol.state.requests().compactMap { $0["model"] as? String }), ["fixture/model", "fixture/second"])
        store.cancel(conversationID: firstID); await store.waitForResponse(conversationID: firstID)
        XCTAssertFalse(store.isSending(conversationID: firstID)); XCTAssertTrue(store.isSending(conversationID: secondID))
        CaptureHTTPProtocol.state.complete("second"); await store.waitForResponse(conversationID: secondID)
        XCTAssertFalse(store.isAnySending)
        XCTAssertEqual(store.conversations.first { $0.id == secondID }?.messages.last?.text, "Response for second")
        XCTAssertEqual(store.conversations.first { $0.id == firstID }?.messages.count, 2)
        XCTAssertEqual(store.activityRecords.filter { $0.kind == .response }.count, 2)
        XCTAssertEqual(Set(store.activityRecords.map(\.id)).count, store.activityRecords.count)
        XCTAssertNil(store.errorMessage, "Stopping an earlier conversation must not replace the current conversation's state")
    }
    func testExplicitOutputBudgetReservesBeforeAnotherConversationCanSpendIt() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        CaptureHTTPProtocol.state.reset(.holdPrimary)
        store.customOutputTokenLimit = 8192
        let bound = try XCTUnwrap(DeviceBudgetRules.upperBound(inputBytes: 256 + "first".utf8.count, maxOutputTokens: 8192, pricing: store.models[0].pricing))
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled"); UserDefaults.standard.set(bound * 1.5, forKey: "aim.budget.limit")
        let first = await store.send("first"); XCTAssertTrue(first)
        store.newConversation()
        let second = await store.send("second"); XCTAssertFalse(second)
        try await waitForRequests(1)
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().first?["max_tokens"] as? Int, 8192)
        XCTAssertEqual(store.activityRecords.filter { $0.costState == .reserved }.count, 1)
        XCTAssertTrue(store.errorMessage?.contains("budget") == true)
        await store.stopAndWait(); XCTAssertFalse(store.isAnySending)
    }
    func testExecutionTargetPersistsPerProfileWithoutSelectingAnotherMac() async throws {
        let store = try await fixture(); defer { clean(store) }
        store.executionTarget = .computer(machineID: "qa-mac-exact")
        let restored = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(restored.executionTarget, .computer(machineID: "qa-mac-exact"))
        let other = NativeChatStore(accountID: UUID(), credentials: CaptureTestSecrets())
        XCTAssertEqual(other.executionTarget, .thisDevice)
        store.executionTarget = .thisDevice
        let phone = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(phone.executionTarget, .thisDevice)
        clean(other)
    }
    func testLegacySnapshotDefaultsToIPhoneAndPreservesConversation() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        let admitted = await store.send("legacy witness"); XCTAssertTrue(admitted); await store.waitForResponse()
        let snapshot = URL.applicationSupportDirectory.appending(path: "Chat/\(store.accountID.uuidString)/conversations.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)) as? [String: Any])
        object.removeValue(forKey: "executionTarget")
        try JSONSerialization.data(withJSONObject: object).write(to: snapshot, options: .atomic)
        let restored = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(restored.executionTarget, .thisDevice)
        XCTAssertEqual(restored.conversations.map(\.id), store.conversations.map(\.id))
        XCTAssertEqual(restored.conversations.first?.messages.last?.text, "Fixture response")
    }
    func testMissingProjectIsRefusedBeforeHTTPOrMemoryCapture() async throws {
        let store = try await fixture(); defer { clean(store) }
        store.selectedProjectID = UUID()
        let admitted = await store.send(source)
        XCTAssertFalse(admitted); XCTAssertTrue(CaptureHTTPProtocol.state.requests().isEmpty)
        XCTAssertTrue(store.memory.entries.isEmpty)
    }
    func testAutomaticOutputFitsConcurrentEffectiveReservations() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        CaptureHTTPProtocol.state.reset(.holdPrimary)
        XCTAssertNil(store.customOutputTokenLimit)
        let bound = try XCTUnwrap(DeviceBudgetRules.upperBound(inputBytes: 261, maxOutputTokens: 8192, pricing: store.models[0].pricing))
        let budget = bound * 1.5
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled"); UserDefaults.standard.set(budget, forKey: "aim.budget.limit")
        let first = await store.send("first"); XCTAssertTrue(first)
        store.newConversation()
        let second = await store.send("second"); XCTAssertTrue(second)
        try await waitForRequests(2)
        let requests = CaptureHTTPProtocol.state.requests()
        func output(for query: String) -> Int? {
            requests.first { ($0["messages"] as? [[String: String]])?.last?["content"] == query }?["max_tokens"] as? Int
        }
        let outputs = requests.compactMap { $0["max_tokens"] as? Int }
        XCTAssertEqual(outputs.count, 2); XCTAssertEqual(output(for: "first"), 8192)
        XCTAssertGreaterThan(try XCTUnwrap(output(for: "second")), 0)
        XCTAssertLessThan(try XCTUnwrap(output(for: "second")), 8192)
        let reservations = store.activityRecords.filter { $0.costState == .reserved }
        XCTAssertEqual(reservations.count, 2)
        XCTAssertEqual(reservations.compactMap(\.costUSD).count, 2)
        let reserved = reservations.compactMap(\.costUSD).reduce(0, +)
        XCTAssertGreaterThan(reserved, bound); XCTAssertLessThanOrEqual(reserved, budget + 1e-12)
        print("QA11 effective max_tokens=\(outputs), reservedUSD=\(reserved), budgetUSD=\(budget)")
        await store.stopAndWait(); XCTAssertFalse(store.isAnySending)
    }
    func testUnknownPriceBlocksOnlyAChosenBudgetAndAutomaticOutputHasNoAIMCap() async throws {
        let store = try await fixture(priced: false); defer { clean(store) }; store.memory.enabled = false
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled")
        let refused = await store.send("budget on"); XCTAssertFalse(refused)
        XCTAssertTrue(CaptureHTTPProtocol.state.requests().isEmpty)
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        let admitted = await store.send("budget off"); XCTAssertTrue(admitted); await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().count, 1)
        XCTAssertNil(CaptureHTTPProtocol.state.requests()[0]["max_tokens"])
        XCTAssertEqual(store.activityRecords.first { $0.kind == .response }?.costState, .unknown)
    }
    func testAbsentWebPreferenceEnablesSearchAndExplicitFalseRemainsOff() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        store.preferences.automaticWebSearch = nil
        let automatic = await store.send("automatic search"); XCTAssertTrue(automatic); await store.waitForResponse()
        XCTAssertNotNil(CaptureHTTPProtocol.state.requests().first?["tools"])
        store.newConversation(); store.preferences.automaticWebSearch = false
        let off = await store.send("explicit off"); XCTAssertTrue(off); await store.waitForResponse()
        XCTAssertNil(CaptureHTTPProtocol.state.requests().last?["tools"])
    }
    func testOpeningHistoryPreservesLastTargetModelAndSeparatePersistentDrafts() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        let first = NativeChatConversation(title: "Old", provider: .anthropic, modelID: "old")
        let second = NativeChatConversation(title: "Other", provider: .openAI, modelID: "other")
        store.conversations = [first, second]
        store.provider = .openRouter; store.modelID = "last-picked"; store.executionTarget = .computer(machineID: "selected-mac")
        await store.open(first); store.draftText = "draft first"
        await store.open(second); store.draftText = "draft second"
        XCTAssertEqual(store.provider, .openRouter); XCTAssertEqual(store.modelID, "last-picked")
        XCTAssertEqual(store.executionTarget, .computer(machineID: "selected-mac"))
        XCTAssertEqual(store.draftText(conversationID: first.id), "draft first")
        let restored = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(restored.draftText(conversationID: first.id), "draft first")
        XCTAssertEqual(restored.draftText(conversationID: second.id), "draft second")
        let stableDraftID = store.draftIdentifier(conversationID: nil)
        store.setDraftText("unfinished new", conversationID: stableDraftID)
        store.newConversation(); XCTAssertEqual(store.draftText, "unfinished new")
        await store.open(first); store.setDraftText("", conversationID: stableDraftID)
        XCTAssertEqual(store.draftText, "draft first", "Delayed clearing of a captured new draft must not erase another conversation")
    }

    func testExplicitOutputLimitCanExceedOldAIMCapAndIsPreservedOnThisDevice() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        var model = ChatModel(id: "fixture/model", name: "Large output", maxOutputTokens: 262144)
        model.pricing = .init(prompt: "0.000001", completion: "0.000001"); store.models = [model]
        store.customOutputTokenLimit = 100000
        let admitted = await store.send("Long answer requested"); XCTAssertTrue(admitted); await store.waitForResponse()
        XCTAssertEqual(CaptureHTTPProtocol.state.requests().first?["max_tokens"] as? Int, 100000)
        let restored = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(restored.customOutputTokenLimit, 100000)
        store.customOutputTokenLimit = nil; XCTAssertNil(restored.customOutputTokenLimit)
    }
    func testPinsAreDistinctFromFavoritesAndPersistWithoutChangingLegacyFavorites() async throws {
        let store = try await fixture(); defer { clean(store) }
        store.favorites = ["openrouter:fixture/model"]
        store.togglePinned(modelID: "fixture/second", provider: .openRouter)
        XCTAssertEqual(store.favorites, ["openrouter:fixture/model"])
        XCTAssertEqual(store.pinnedModels, ["openrouter:fixture/second"])
        await store.synchronize()
        let restored = NativeChatStore(accountID: store.accountID, credentials: CaptureTestSecrets())
        XCTAssertEqual(restored.pinnedModels, ["openrouter:fixture/second"])
        XCTAssertEqual(restored.favorites, ["openrouter:fixture/model"])
    }

    func testStructuredWebSearchActivitiesDeduplicateAndOnlyRunningToolsFailOnInterruption() throws {
        let merged = NativeChatStore.mergingWebSearchActivities([.init(id: "search-1", status: .running)], with: [
            .init(id: "search-1", status: .completed), .init(id: "search-2", status: .running), .init(id: "search-1", status: .running)])
        XCTAssertEqual(merged, [.init(id: "search-1", status: .completed), .init(id: "search-2", status: .running)])
        let interrupted = NativeChatStore.interruptedWebSearchActivities(merged)
        XCTAssertEqual(interrupted, [.init(id: "search-1", status: .completed), .init(id: "search-2", status: .failed)])
        let message = NativeChatMessage(role: .assistant, text: "The model says it searched", webSearchActivities: interrupted)
        let restored = try JSONDecoder().decode(NativeChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.webSearchActivities, interrupted)
        XCTAssertTrue(NativeChatStore.mergingWebSearchActivities([], with: []).isEmpty, "Prose does not manufacture a web tool event")
    }

    func testFinishedConversationSynchronizesWhileAnotherConversationStillRuns() async throws {
        let store = try await fixture(); defer { clean(store) }; store.memory.enabled = false
        CaptureHTTPProtocol.state.reset(.holdPrimary)
        let first = await store.send("first"); XCTAssertTrue(first)
        let firstID = try XCTUnwrap(store.selectedID)
        store.newConversation()
        let second = await store.send("second"); XCTAssertTrue(second)
        let secondID = try XCTUnwrap(store.selectedID)
        try await waitForRequests(2)
        CaptureHTTPProtocol.state.complete("first"); await store.waitForResponse(conversationID: firstID)
        let document = await fixtureService?.document(firstID)
        XCTAssertEqual(document?.kind, "chat")
        XCTAssertTrue(store.isSending(conversationID: secondID))
        let saved = try JSONDecoder().decode(NativeChatConversation.self, from: Data(try XCTUnwrap(document?.payload).utf8))
        XCTAssertEqual(saved.messages.last?.text, "Response for first")
        let activeDocument = await fixtureService?.document(secondID)
        XCTAssertNil(activeDocument, "An in-progress conversation must not publish a stale partial snapshot")
        await store.stopAndWait()
    }

}


/// Test-only ownership fence shared by account, project and budget fixtures.
/// A teardown never unlinks SQLite while any restored store is still alive.
@MainActor private enum NativeChatFixtureLifetimes {
    struct WeakStore { weak var value: NativeChatStore? }
    final class Bucket { var owners: [UUID: [WeakStore]] = [:] }
    static var buckets: [ObjectIdentifier: Bucket] = [:]
}
extension XCTestCase {
    @MainActor func trackNativeChatFixture(_ store: NativeChatStore) -> NativeChatStore {
        let testID = ObjectIdentifier(self)
        let bucket: NativeChatFixtureLifetimes.Bucket
        if let existing = NativeChatFixtureLifetimes.buckets[testID] { bucket = existing }
        else {
            bucket = .init(); NativeChatFixtureLifetimes.buckets[testID] = bucket
            addTeardownBlock { @MainActor in
                defer { NativeChatFixtureLifetimes.buckets[testID] = nil }
                for stores in bucket.owners.values {
                    for reference in stores { if let store = reference.value { await store.stopAndWait() } }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while bucket.owners.values.joined().contains(where: { $0.value != nil }) && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard bucket.owners.values.joined().allSatisfy({ $0.value == nil }) else {
                    return XCTFail("Fixture retained a source library; directory preserved instead of unlinking live SQLite")
                }
                for owner in bucket.owners.keys {
                    let directory = URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)", directoryHint: .isDirectory)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
            }
        }
        bucket.owners[store.accountID, default: []].append(.init(value: store))
        return store
    }
}
