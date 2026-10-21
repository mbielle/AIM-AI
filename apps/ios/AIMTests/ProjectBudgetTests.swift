import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class ProjectBudgetSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { Data("fixture-provider-key".utf8) }
    func removeData(forKey key: String) throws {}
}

private final class ProjectBudgetRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    func reset() { lock.lock(); values = []; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Intercepts every URL. These tests never consult a real catalog or send a paid model request.
private final class ProjectBudgetHTTP: URLProtocol, @unchecked Sendable {
    static let recorded = ProjectBudgetRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.recorded.append(request)
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable && data.count < 1_000_000 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            bytes = data
        }
        let body = String(decoding: bytes ?? Data(), as: UTF8.self)
        let cost = body.contains("Reported total fixture") ? ",\"cost\":0.032" : body.contains("Over limit total fixture") ? ",\"cost\":6.0" : ""
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic answer\"},\"finish_reason\":null}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5" + cost + "}}\n\n" +
            "data: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class ProjectBudgetTests: XCTestCase {
    private struct BudgetSettings {
        let enabled = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        let limit = UserDefaults.standard.object(forKey: "aim.budget.limit")
        let output = UserDefaults.standard.object(forKey: "aim.chat.output-tokens")
        let strictWeb = UserDefaults.standard.object(forKey: "aim.budget.strict-web-search")
        func restore() {
            UserDefaults.standard.set(enabled, forKey: "aim.budget.enabled")
            UserDefaults.standard.set(limit, forKey: "aim.budget.limit")
            UserDefaults.standard.set(output, forKey: "aim.chat.output-tokens")
            UserDefaults.standard.set(strictWeb, forKey: "aim.budget.strict-web-search")
        }
    }
    private func protectBudget() {
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled")
        UserDefaults.standard.set(5.0, forKey: "aim.budget.limit")
        UserDefaults.standard.set(true, forKey: "aim.budget.strict-web-search")
        UserDefaults.standard.removeObject(forKey: "aim.chat.output-tokens")
        ProjectBudgetHTTP.recorded.reset()
    }
    private static func directory(_ owner: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)", directoryHint: .isDirectory)
    }
    private func store(_ owner: UUID) throws -> NativeChatStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProjectBudgetHTTP.self]
        let session = URLSession(configuration: config)
        let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectBudgetSecrets(),
            transport: NativeChatTransport(session: session, networkReadiness: { _ in })))
        chat.provider = .openRouter
        // Synthetic price/capacity facts only; no claim about the live GLM catalog.
        let model = try JSONDecoder().decode(ChatModel.self, from: Data(#"{"id":"z-ai/glm-5.3","name":"Synthetic GLM 5.3","max_tokens":4096,"pricing":{"prompt":"0.000001","completion":"0.000002"},"architecture":{"input_modalities":["text"],"output_modalities":["text"]}}"#.utf8))
        chat.modelID = model.id; chat.models = [model]
        chat.memory.enabled = false
        return chat
    }

    func testLegacyUnpricedCompletedSearchNoLongerBlocksBudgetAndRepairSurvivesReopen() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        UserDefaults.standard.set(false, forKey: "aim.budget.strict-web-search")
        let owner = UUID();
        let chat = try store(owner); chat.preferences.automaticWebSearch = true
        let messageID = UUID(), conversationID = UUID()
        chat.conversations = [.init(id: conversationID, title: "Synthetic legacy answer", provider: .openRouter,
            modelID: chat.modelID, messages: [.init(id: messageID, role: .assistant, text: "Synthetic saved answer", webSearchUsage: .init(),
                skillActivities: [.init(id: "local-source", name: "project_source_search", skill: "validation", running: false)])],
            turns: [.init(id: messageID, usage: .init(inputTokens: 2641, outputTokens: 235), completedAt: .now)])]
        chat.activityRecords = [.init(id: messageID, accountID: owner, deviceID: chat.deviceID, deviceName: "Fixture", conversationID: conversationID,
            provider: "openrouter", modelID: chat.modelID, mode: "chat", startedAt: Date.now.addingTimeInterval(-1), completedAt: .now)]
        XCTAssertTrue(chat.reconcileLegacyBudgetEstimates())
        let repaired = try XCTUnwrap(chat.activityRecords.first)
        XCTAssertEqual(repaired.costState, .estimated); XCTAssertNotNil(repaired.costEstimateBasis)
        XCTAssertEqual(chat.conversations[0].turns[0].estimatedUSD, repaired.costUSD)
        let reopened = try store(owner)
        XCTAssertEqual(reopened.activityRecords.first?.costUSD, repaired.costUSD)
        XCTAssertEqual(reopened.activityRecords.first?.costEstimateBasis, repaired.costEstimateBasis)
        let admitted = await chat.send("Follow-up within five dollars")
        XCTAssertTrue(admitted); await chat.waitForResponse()
        XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
    }

    func testEstimatedBudgetWithUnpricedCompletedHistoryCanSendAndRetainsUnknownRecord() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        UserDefaults.standard.set(false, forKey: "aim.budget.strict-web-search")
        let owner = UUID();
        let chat = try store(owner); chat.preferences.automaticWebSearch = true
        let oldID = UUID()
        chat.activityRecords = [.init(id: oldID, accountID: owner, deviceID: chat.deviceID, deviceName: "Fixture",
            provider: "openrouter", modelID: "old-unavailable-model", mode: "chat", startedAt: .now.addingTimeInterval(-1), completedAt: .now)]
        let admitted = await chat.send("Known-priced follow-up"); XCTAssertTrue(admitted); await chat.waitForResponse()
        XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
        let old = try XCTUnwrap(chat.activityRecords.first { $0.id == oldID })
        XCTAssertNil(old.costUSD); XCTAssertEqual(old.costState, .unknown)
        XCTAssertEqual(chat.completedUnknownBudgetCharges, 1)
        let reopened = try store(owner)
        XCTAssertNil(reopened.activityRecords.first { $0.id == oldID }?.costUSD)
        XCTAssertEqual(reopened.completedUnknownBudgetCharges, 1)
    }

    func testUnsettledUnknownStillBlocksAndStrictModeRequiresCompletedHistory() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID();
        let chat = try store(owner); chat.preferences.automaticWebSearch = false
        UserDefaults.standard.set(false, forKey: "aim.budget.strict-web-search")
        chat.activityRecords = [.init(id: UUID(), accountID: owner, deviceID: chat.deviceID, deviceName: "Fixture",
            provider: "openrouter", modelID: "unknown", mode: "chat", startedAt: .now.addingTimeInterval(-1))]
        let unsettled = await chat.send("Unsettled guard"); XCTAssertFalse(unsettled)
        chat.activityRecords[0].completedAt = .now
        UserDefaults.standard.set(true, forKey: "aim.budget.strict-web-search")
        let strict = await chat.send("Strict historical guard"); XCTAssertFalse(strict)
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }

    func testAutomaticOutputFitsRemainingBudgetForLargeCatalogCapacityAndPersistsSameWireLimit() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        UserDefaults.standard.set(false, forKey: "aim.budget.strict-web-search")
        let owner = UUID();
        let chat = try store(owner); chat.preferences.automaticWebSearch = true
        chat.models[0] = ChatModel(id: chat.modelID, name: "Synthetic large output", maxOutputTokens: 2_000_000)
        chat.models[0].pricing = .init(prompt: "0.000000079", completion: "0.0000048")
        let admitted = await chat.send(String(repeating: "Synthetic text ", count: 5_000))
        XCTAssertTrue(admitted); await chat.waitForResponse()
        XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
        XCTAssertEqual(chat.selected?.messages.last?.text, "Synthetic answer")
        XCTAssertLessThanOrEqual(chat.activityRecords.first(where: { $0.kind == .response })?.costUSD ?? .infinity, 5)
    }

    func testEstimatedWebBudgetAdmitsAndKeepsUnknownSearchCostSeparateFromKnownSubtotal() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        UserDefaults.standard.removeObject(forKey: "aim.budget.strict-web-search")
        let owner = UUID();
        let chat = try store(owner); chat.preferences.automaticWebSearch = true
        XCTAssertFalse(chat.requiresVerifiedWebSearchBudget)
        let admitted = await chat.send("Synthetic web search question")
        XCTAssertTrue(admitted); await chat.waitForResponse()
        XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
        XCTAssertNil(chat.selected?.messages.last?.webSearchUsage?.additionalCostUSD)
        XCTAssertNil(chat.selected?.messages.last?.webSearchUsage?.providerTotalCostUSD)
        XCTAssertEqual(chat.selected?.turns.last?.estimatedUSD, 0.00002)
        XCTAssertEqual(chat.activityRecords.first(where: { $0.kind == .response })?.costState, .estimated)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "aim.budget.limit"), 5)
        UserDefaults.standard.set(0.000001, forKey: "aim.budget.limit")
        let over = await chat.send("Must stay unsent")
        XCTAssertFalse(over); XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
    }

    func testProviderTotalSettlesOnceAsConfirmedAndStopsLaterRequestsAboveBudget() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        UserDefaults.standard.set(false, forKey: "aim.budget.strict-web-search")
        for (text, amount) in [("Reported total fixture", 0.032), ("Over limit total fixture", 6.0)] {
            let owner = UUID();
            let chat = try store(owner); chat.preferences.automaticWebSearch = true
            let admitted = await chat.send(text); XCTAssertTrue(admitted); await chat.waitForResponse()
            XCTAssertEqual(chat.selected?.turns.last?.estimatedUSD, amount)
            let record = try XCTUnwrap(chat.activityRecords.first(where: { $0.kind == .response }))
            XCTAssertEqual(record.costUSD, amount); XCTAssertEqual(record.costState, .confirmed)
            if amount > 5 {
                let count = ProjectBudgetHTTP.recorded.requests.count
                let next = await chat.send("Do not exceed again")
                XCTAssertFalse(next); XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, count)
            }
        }
    }

    func testDefaultAndExplicitWebSearchBothFailClosedWithTypedActionAndKeepDraft() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        for explicit in [Optional<Bool>.none, true] {
            let owner = UUID(), directory = Self.directory(owner)

            let chat = try store(owner)
            chat.preferences.automaticWebSearch = explicit
            chat.draftText = "Synthetic unsent question"
            let draft = chat.draftIdentifier(conversationID: nil)
            let admitted = await chat.send(chat.draftText)
            XCTAssertFalse(admitted)
            XCTAssertEqual(chat.errorNoticeKind, .webSearchBudget)
            XCTAssertNotNil(chat.errorMessage)
            XCTAssertEqual(chat.preferences.automaticWebSearch, explicit)
            XCTAssertEqual(chat.draftText, "Synthetic unsent question")
            XCTAssertEqual(chat.draftIdentifier(conversationID: nil), draft)
            XCTAssertTrue(chat.conversations.isEmpty); XCTAssertTrue(chat.activityRecords.isEmpty)
            XCTAssertFalse(chat.isAnySending)
        }
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }

    func testExplicitRecoveryPersistsOnlyWebPreferenceWithoutSendingOrTouchingAnotherProfile() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID(), otherOwner = UUID()

        let chat = try store(owner), other = try store(otherOwner)
        chat.preferences.automaticWebSearch = true
        chat.preferences.responseStyle = .concise
        chat.preferences.responseLanguage = "French"
        chat.preferences.customInstructions = "Keep this synthetic preference"
        chat.preferences.warmth = "warm"
        chat.draftText = "Keep this draft"
        let file = await chat.prepareInput(Data("Synthetic document".utf8), name: "fixture.txt", mimeType: "text/plain", draftID: chat.draftIdentifier(conversationID: nil))
        XCTAssertNotNil(file)
        let originalInputs = chat.inputReferences(chat.draftIdentifier(conversationID: nil))
        let baseline = chat.preferences
        _ = await chat.send(chat.draftText)
        let saved = await chat.disableAutomaticWebSearch()
        XCTAssertTrue(saved)
        var expected = baseline; expected.automaticWebSearch = false
        XCTAssertEqual(chat.preferences, expected); XCTAssertNil(chat.errorMessage); XCTAssertNil(chat.errorNoticeKind)
        XCTAssertEqual(chat.draftText, "Keep this draft")
        XCTAssertEqual(chat.inputReferences(chat.draftIdentifier(conversationID: nil)), originalInputs)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "aim.budget.enabled"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "aim.budget.limit"), 5)
        XCTAssertTrue(chat.conversations.isEmpty); XCTAssertTrue(chat.activityRecords.isEmpty)
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
        let reopened = try store(owner)
        XCTAssertEqual(reopened.preferences, expected); XCTAssertEqual(reopened.draftText, "Keep this draft")
        XCTAssertNil(other.preferences.automaticWebSearch)
        XCTAssertNil(try store(otherOwner).preferences.automaticWebSearch)
    }

    func testLegacyMismatchedGeneralDraftIDRecoversUnscopedDraftWithoutDeletingSnapshotEntries() throws {
        let owner = UUID(), directory = Self.directory(owner)

        let chat = try store(owner)
        chat.draftText = "Existing draft from an older build"
        let expectedID = chat.draftIdentifier(conversationID: nil), path = directory.appending(path: "conversations.json")
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        snapshot["generalDraftID"] = UUID().uuidString
        let before = try XCTUnwrap(snapshot["drafts"])
        try JSONSerialization.data(withJSONObject: snapshot).write(to: path)
        let reopened = try store(owner)
        XCTAssertEqual(reopened.draftIdentifier(conversationID: nil), expectedID)
        XCTAssertEqual(reopened.draftText, "Existing draft from an older build")
        // Opening a snapshot does not rewrite it or discard any dormant draft entries.
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: before, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: XCTUnwrap(after["drafts"]), options: .sortedKeys))
        // The same occupied ID must not be adopted as general if it belongs to a project.
        snapshot["projectDraftIDs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([UUID(): expectedID]))
        try JSONSerialization.data(withJSONObject: snapshot).write(to: path)
        let scoped = try store(owner)
        XCTAssertNotEqual(scoped.draftIdentifier(conversationID: nil), expectedID)
        XCTAssertTrue(scoped.draftText.isEmpty)
    }

    func testOnlyExplicitResendMakesOneFixtureRequestAfterRecovery() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID();
        let chat = try store(owner); chat.draftText = "Synthetic budgeted question"
        let refused = await chat.send(chat.draftText); XCTAssertFalse(refused)
        let changed = await chat.disableAutomaticWebSearch(); XCTAssertTrue(changed)
        await Task.yield()
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
        let admitted = await chat.send(chat.draftText); XCTAssertTrue(admitted)
        await chat.waitForResponse()
        XCTAssertEqual(ProjectBudgetHTTP.recorded.requests.count, 1)
        XCTAssertEqual(chat.selected?.messages.last?.text, "Synthetic answer")
        XCTAssertEqual(chat.selected?.turns.last?.estimatedUSD, 0.00002)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "aim.budget.enabled"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "aim.budget.limit"), 5)
    }

    func testNewUnrelatedErrorInvalidatesRecoveryAndIsNotClearedByPreferenceChange() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID();
        let chat = try store(owner)
        _ = await chat.send("Synthetic question")
        XCTAssertEqual(chat.errorNoticeKind, .webSearchBudget)
        chat.errorMessage = "Synthetic unrelated failure"
        XCTAssertNil(chat.errorNoticeKind)
        let changed = await chat.disableAutomaticWebSearch(); XCTAssertTrue(changed)
        XCTAssertEqual(chat.errorMessage, "Synthetic unrelated failure")
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }

    func testFailedPersistenceRollsBackPreferenceAndPreservesDraftAndBudget() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID(), directory = Self.directory(owner)

        let chat = try store(owner); chat.preferences.automaticWebSearch = true; chat.draftText = "Preserved draft"
        let baseline = chat.preferences, path = directory.appending(path: "conversations.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let changed = await chat.disableAutomaticWebSearch()
        XCTAssertFalse(changed); XCTAssertEqual(chat.preferences, baseline); XCTAssertEqual(chat.draftText, "Preserved draft")
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "aim.budget.enabled"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "aim.budget.limit"), 5)
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }

    func testUnrecoverableHistoryIsNeverOverwrittenByRecoveryAction() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        let owner = UUID(), directory = Self.directory(owner)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "conversations.json"), original = Data("synthetic unreadable snapshot".utf8)
        try original.write(to: path)
        let chat = try store(owner)
        let changed = await chat.disableAutomaticWebSearch()
        XCTAssertFalse(changed); XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertNil(chat.preferences.automaticWebSearch)
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }

    func testTurningOffWebDoesNotBypassUnknownPriceOrExhaustedBudget() async throws {
        let settings = BudgetSettings(); defer { settings.restore() }; protectBudget()
        for unknown in [true, false] {
            let owner = UUID();
            let chat = try store(owner)
            let changed = await chat.disableAutomaticWebSearch(); XCTAssertTrue(changed)
            if unknown { chat.models[0].pricing = nil }
            else { UserDefaults.standard.set(0.000001, forKey: "aim.budget.limit") }
            let admitted = await chat.send("Synthetic question")
            XCTAssertFalse(admitted); XCTAssertNil(chat.errorNoticeKind)
            XCTAssertTrue(chat.errorMessage?.contains(unknown ? "verified price" : "budget") == true)
            XCTAssertTrue(chat.conversations.isEmpty); XCTAssertTrue(chat.activityRecords.isEmpty)
        }
        XCTAssertTrue(ProjectBudgetHTTP.recorded.requests.isEmpty)
    }
}
