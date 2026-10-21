import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class HybridStoreSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func readData(forKey key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}

private final class HybridStoreRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ value: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func reset() { lock.lock(); defer { lock.unlock() }; values = [] }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

/// All model traffic is intercepted; no catalog, credentials or paid endpoint is consulted.
private final class HybridStoreHTTP: URLProtocol, @unchecked Sendable {
    static let captured = HybridStoreRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.captured.append(request)
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, data.isEmpty {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable && data.count < 1_000_000 {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let history = body["messages"] as? [[String: Any]] ?? []
            let toolCount = history.filter { $0["role"] as? String == "tool" }.count
            let message: [String: Any] = toolCount < 2 ? [
                "role": "assistant", "content": "", "tool_calls": [[
                    "id": "fixture-search-\(toolCount)", "type": "function",
                    "function": ["name": "web_search", "arguments": #"{"query":"Synthetic research question"}"#]
                ]]
            ] : ["role": "assistant", "content": "Synthetic researched answer."]
            let payload = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": message, "finish_reason": toolCount < 2 ? "tool_calls" : "stop"]],
                "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.01]
            ])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor final class HybridResearchStoreTests: XCTestCase {
    private struct Settings {
        let keys = ["aim.budget.enabled", "aim.budget.limit", "aim.budget.strict-web-search", "aim.chat.output-tokens"]
        let values: [Any?]
        init() { values = keys.map { UserDefaults.standard.object(forKey: $0) } }
        func restore() { for (key, value) in zip(keys, values) { UserDefaults.standard.set(value, forKey: key) } }
    }
    private func configure(limit: Double = 50, strict: Bool = false) {
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled")
        UserDefaults.standard.set(limit, forKey: "aim.budget.limit")
        UserDefaults.standard.set(strict, forKey: "aim.budget.strict-web-search")
        UserDefaults.standard.removeObject(forKey: "aim.chat.output-tokens")
        HybridStoreHTTP.captured.reset()
    }
    private func clean(_ owner: UUID) {
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)"))
        UserDefaults.standard.removeObject(forKey: "aim.research.credentials.revision." + owner.uuidString.lowercased())
    }
    private func store(_ owner: UUID, secrets: HybridStoreSecrets, searches: HybridStoreRequests,
                       mode: AIMResearchMode = .exa) throws -> NativeChatStore {
        try secrets.store(Data("fixture-model-key".utf8), forKey: owner.uuidString + ".openrouter")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HybridStoreHTTP.self]
        let session = URLSession(configuration: config)
        let chat = NativeChatStore(accountID: owner, credentials: secrets,
            transport: NativeChatTransport(session: session, networkReadiness: { _ in }),
            skillTransport: NativeSkillChatTransport(session: session, networkAdmission: {}),
            researchPerform: { operation in
                searches.append(operation.request)
                XCTAssertEqual(operation.kind, .search)
                let payload = operation.mode == .exa
                    ? #"{"results":[{"url":"https://example.com/research","title":"Synthetic source","highlights":["Synthetic excerpt"]}]}"#
                    : #"{"web":{"results":[{"url":"https://example.com/research","title":"Synthetic source","description":"Synthetic excerpt"}]}}"#
                return .init(data: Data(payload.utf8), externalAPICostUSD: operation.mode == .exa ? 0.007 : nil)
            }, researchEstimateDate: { AIMResearchPricing.reviewedAt })
        chat.provider = .openRouter
        // Deliberately synthetic capacity and prices; not a claim about the current GLM catalog.
        let model = try JSONDecoder().decode(ChatModel.self, from: Data(#"{"id":"z-ai/glm-5.3","name":"Synthetic GLM 5.3","max_tokens":4096,"pricing":{"prompt":"0.00000001","completion":"0.00000002"},"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["tools"]}"#.utf8))
        chat.modelID = model.id; chat.models = [model]; chat.memory.enabled = false
        chat.preferences.automaticWebSearch = true; chat.preferences.researchMode = mode
        return chat
    }

    func testExaReceiptSettlesSeparatelyOnceAndRepeatedSearchUsesCache() async throws {
        let settings = Settings(); defer { settings.restore() }; configure()
        let owner = UUID(); defer { clean(owner) }
        let secrets = HybridStoreSecrets(), searches = HybridStoreRequests()
        let chat = try store(owner, secrets: secrets, searches: searches)
        try chat.saveResearchKey("fixture-search-key", mode: .exa)
        let sent = await chat.send("Synthetic research question"); XCTAssertTrue(sent)
        await chat.waitForResponse()
        XCTAssertEqual(HybridStoreHTTP.captured.requests.count, 3)
        XCTAssertEqual(searches.requests.count, 1)
        XCTAssertEqual(searches.requests.first?.value(forHTTPHeaderField: "x-api-key"), "fixture-search-key")
        let response = try XCTUnwrap(chat.activityRecords.first { $0.kind == .response })
        let fee = try XCTUnwrap(chat.activityRecords.first { $0.kind == .cost })
        XCTAssertEqual(response.provider, "openrouter"); XCTAssertEqual(response.costState, .confirmed)
        XCTAssertEqual(response.costUSD ?? -1, 0.03, accuracy: 0.0000001)
        XCTAssertEqual(fee.provider, "research.exa"); XCTAssertEqual(fee.costState, .confirmed)
        XCTAssertEqual(fee.costUSD, 0.007); XCTAssertEqual(fee.accountID, owner)
        XCTAssertEqual(fee.deviceID, chat.deviceID); XCTAssertEqual(fee.conversationID, response.conversationID)
        XCTAssertEqual(fee.parentTaskID, response.id); XCTAssertNotNil(fee.completedAt)
        XCTAssertEqual(chat.activityRecords.filter { $0.kind == .cost }.count, 1)
        let metadata = try XCTUnwrap(chat.selected?.messages.last?.webSearchUsage)
        XCTAssertEqual(metadata.providerTotalCostUSD ?? -1, 0.03, accuracy: 0.0000001)
        XCTAssertEqual(metadata.externalSearchCostUSD, 0.007)
        XCTAssertEqual(metadata.externalCostsTrackedSeparately, true)
        XCTAssertEqual(chat.selected?.messages.last?.text, "Synthetic researched answer.")
        let reopened = try store(owner, secrets: secrets, searches: searches)
        XCTAssertEqual(reopened.activityRecords.first { $0.id == fee.id }?.costUSD, 0.007)
        XCTAssertTrue(chat.activityRecords.allSatisfy { $0.completedAt != nil })
    }

    func testBraveAbsentReceiptIsExplicitEstimateNotAForeignModelInvoiceOrReservation() async throws {
        let settings = Settings(); defer { settings.restore() }; configure()
        let owner = UUID(); defer { clean(owner) }
        let secrets = HybridStoreSecrets(), searches = HybridStoreRequests()
        let chat = try store(owner, secrets: secrets, searches: searches, mode: .brave)
        try chat.saveResearchKey("fixture-brave-key", mode: .brave)
        let first = await chat.send("Synthetic research question"); XCTAssertTrue(first); await chat.waitForResponse()
        let fee = try XCTUnwrap(chat.activityRecords.first { $0.kind == .cost })
        XCTAssertEqual(fee.provider, "research.brave"); XCTAssertEqual(fee.costState, .estimated)
        XCTAssertEqual(fee.costUSD, 0.005); XCTAssertNotNil(fee.costEstimateBasis); XCTAssertNotNil(fee.completedAt)
        XCTAssertNil(chat.selected?.messages.last?.webSearchUsage?.externalSearchCostUSD)
        XCTAssertEqual(chat.selected?.messages.last?.webSearchUsage?.providerTotalCostUSD ?? -1, 0.03, accuracy: 0.0000001)
        XCTAssertFalse(chat.activityRecords.contains { $0.costState == .reserved })
        // Completed external estimates do not leave a permanent unresolved admission reservation.
        chat.newConversation()
        let next = await chat.send("Synthetic research question"); XCTAssertTrue(next); await chat.waitForResponse()
        XCTAssertEqual(searches.requests.count, 2)
    }

    func testStrictBudgetAndMissingSearchKeyRefuseBeforeAnyModelOrSearchAndPreserveDraft() async throws {
        let settings = Settings(); defer { settings.restore() }
        for strict in [false, true] {
            configure(strict: strict)
            let owner = UUID(); defer { clean(owner) }
            let secrets = HybridStoreSecrets(), searches = HybridStoreRequests()
            let chat = try store(owner, secrets: secrets, searches: searches)
            if strict { try chat.saveResearchKey("fixture-search-key", mode: .exa) }
            chat.draftText = "Synthetic preserved draft"
            let sent = await chat.send(chat.draftText)
            XCTAssertFalse(sent); XCTAssertEqual(chat.draftText, "Synthetic preserved draft")
            XCTAssertTrue(chat.activityRecords.isEmpty); XCTAssertTrue(chat.conversations.isEmpty)
            XCTAssertTrue(HybridStoreHTTP.captured.requests.isEmpty); XCTAssertTrue(searches.requests.isEmpty)
            XCTAssertEqual(chat.preferences.researchMode, .exa); XCTAssertEqual(chat.preferences.automaticWebSearch, true)
        }
    }

    func testExternalFeeAdmissionUsesReceivedModelBillAndStopsWithoutNetworkOrFallback() async throws {
        let settings = Settings(); defer { settings.restore() }; configure(limit: 0.012)
        let owner = UUID(); defer { clean(owner) }
        let secrets = HybridStoreSecrets(), searches = HybridStoreRequests()
        let chat = try store(owner, secrets: secrets, searches: searches)
        try chat.saveResearchKey("fixture-search-key", mode: .exa)
        let sent = await chat.send("Synthetic research question"); XCTAssertTrue(sent); await chat.waitForResponse()
        XCTAssertEqual(HybridStoreHTTP.captured.requests.count, 1)
        XCTAssertTrue(searches.requests.isEmpty); XCTAssertNotNil(chat.errorMessage)
        let response = try XCTUnwrap(chat.activityRecords.first { $0.kind == .response })
        XCTAssertEqual(response.costUSD, 0.01); XCTAssertEqual(response.costState, .confirmed)
        XCTAssertNotNil(response.completedAt)
        XCTAssertFalse(chat.activityRecords.contains { $0.costState == .reserved })
        XCTAssertFalse(chat.activityRecords.contains { $0.kind == .cost })
        XCTAssertEqual(UserDefaults.standard.double(forKey: "aim.budget.limit"), 0.012)
    }

    func testSearchKeysAreProfileScopedAndSavingNeverValidatesThroughNetwork() throws {
        let settings = Settings(); defer { settings.restore() }; configure()
        let owner = UUID(), other = UUID(); defer { clean(owner); clean(other) }
        let secrets = HybridStoreSecrets(), searches = HybridStoreRequests()
        let chat = try store(owner, secrets: secrets, searches: searches)
        let otherChat = try store(other, secrets: secrets, searches: searches)
        try chat.saveResearchKey("fixture-owner-search", mode: .exa)
        try otherChat.saveResearchKey("fixture-other-search", mode: .exa)
        try chat.removeResearchKey(mode: .exa)
        XCTAssertNil(try secrets.readData(forKey: owner.uuidString + ".research.exa"))
        XCTAssertEqual(try secrets.readData(forKey: other.uuidString + ".research.exa"), Data("fixture-other-search".utf8))
        XCTAssertTrue(HybridStoreHTTP.captured.requests.isEmpty); XCTAssertTrue(searches.requests.isEmpty)
        XCTAssertTrue(chat.conversations.isEmpty); XCTAssertTrue(otherChat.activityRecords.isEmpty)
    }
}
