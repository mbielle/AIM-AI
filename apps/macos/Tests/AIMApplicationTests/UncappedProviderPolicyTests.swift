import AIMCore
import XCTest
@testable import AIMApplication

private final class UncappedProviderFixture: URLProtocol, @unchecked Sendable {
    struct Record { let method: String; let path: String; let body: [String: Any] }
    nonisolated(unsafe) static var replies: [Data] = []
    nonisolated(unsafe) static var records: [Record] = []
    static let lock = NSLock()
    static func reset(_ values: [Data]) { lock.withLock { replies = values; records = [] } }
    static func snapshot() -> [Record] { lock.withLock { records } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while input.hasBytesAvailable { let count = input.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        let next: Data? = Self.lock.withLock {
            Self.records.append(.init(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]))
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let next, let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UncappedProviderPolicyTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [UncappedProviderFixture.self]; return URLSession(configuration: c) }
    private func answer(_ text: String, reason: String = "stop", cost: String = "0.01") throws -> Data {
        try json(["choices": [["finish_reason": reason, "message": ["role": "assistant", "content": text]]], "usage": ["cost": Double(cost)!, "prompt_tokens": 10, "completion_tokens": 5]])
    }
    private func toolConversation(meter: BillableRequestMeter = .init()) throws -> ProviderToolConversation {
        try .init(provider: .openRouter, modelID: "fixture/model", messages: [.init(conversationID: UUID(), role: .user, content: "Explain", sequence: 0)], apiKey: "fixture", tools: [], session: session(), meter: meter)
    }
    private func sse(_ text: String, reason: String) throws -> Data {
        let payload = String(decoding: try json(["choices": [["delta": ["content": text], "finish_reason": reason]], "usage": ["cost": 0.01, "prompt_tokens": 10, "completion_tokens": 5]]), as: UTF8.self)
        return Data(("data: " + payload + "\n\ndata: [DONE]\n\n").utf8)
    }

    func testOptionalOutputOmittedAndRequiredAnthropicUsesPublishedCapacity() throws {
        XCTAssertNil(try ModelOutputPolicy.resolve(provider: .openRouter, modelID: "model"))
        XCTAssertEqual(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "model", catalogMaximum: 128_000), 128_000)
        XCTAssertEqual(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "model", catalogMaximum: 128_000, userLimit: 12_345), 12_345)
        XCTAssertThrowsError(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "model"))
        XCTAssertThrowsError(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "model", catalogMaximum: 1_000, userLimit: 2_000))
    }
    func testDisabledBudgetKeepsAccountingWithoutQuoteOrRoutingRestrictions() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        UncappedProviderFixture.reset([try answer("Done")])
        let c = try toolConversation(meter: .init(ledger: ledger)); _ = try await c.next(outputs: [])
        let requests = UncappedProviderFixture.snapshot()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].method, "POST")
        XCTAssertNil(requests[0].body["max_tokens"])
        XCTAssertNil((requests[0].body["provider"] as? [String: Any])?["max_price"])
        XCTAssertNotEqual((requests[0].body["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
        let snapshot = try await ledger.snapshot(at: .now); XCTAssertEqual(snapshot.confirmedUSD, "0.01")
    }
    func testEnabledBudgetQuotesWholeModelOutputCapacity() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(.init(enabled: true, limitUSD: "10"))
        let catalog = try json(["data": [["id": "fixture/model", "pricing": ["prompt": "0.000001", "completion": "0.000002", "request": "0"], "context_length": 32_000, "supported_parameters": ["max_tokens"], "top_provider": ["max_completion_tokens": 16_000]]]])
        UncappedProviderFixture.reset([catalog, try answer("Done")])
        let c = try toolConversation(meter: .init(ledger: ledger)); _ = try await c.next(outputs: [])
        let records = UncappedProviderFixture.snapshot(); XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual((records[1].body["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
    }
    func testMoreThanTwoContinuationRoundsCompleteAndRepeatedTextFails() async throws {
        UncappedProviderFixture.reset([try answer("First ", reason: "length"), try answer("second ", reason: "length"), try answer("third ", reason: "length"), try answer("last")])
        let c = try toolConversation(); let turn = try await c.next(outputs: [])
        XCTAssertEqual(turn.text, "First second third last"); XCTAssertEqual(UncappedProviderFixture.snapshot().count, 4)
        UncappedProviderFixture.reset([try answer("Repeated", reason: "length"), try answer("Repeated", reason: "length")])
        do { _ = try await toolConversation().next(outputs: []); XCTFail("No progress must fail") } catch { }
        XCTAssertEqual(UncappedProviderFixture.snapshot().count, 2)
    }
    func testTruncatedStructuredToolCallCannotBeExecuted() async throws {
        let body = try json(["choices": [["finish_reason": "length", "message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "t", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"a\"}"]]]]]]])
        UncappedProviderFixture.reset([body, try answer("I will write it in smaller pieces.")])
        let c = try ProviderToolConversation(provider: .openRouter, modelID: "fixture/model", messages: [], apiKey: "fixture", tools: [.init(name: "read_file", description: "Read", requiredArguments: ["path"])], session: session())
        // The cut-off call never runs: the model is asked to write smaller pieces instead.
        let turn: ModelToolTurn
        do { turn = try await c.next(outputs: []) } catch { let cause = await c.lastInvalidCause; XCTFail("cause: \(cause ?? "none")"); return }
        XCTAssertTrue(turn.calls.isEmpty)
        XCTAssertEqual(UncappedProviderFixture.snapshot().count, 2)
    }
    func testMainChatContinuationsAggregateReceiptsWithoutQuota() async throws {
        UncappedProviderFixture.reset([try sse("First ", reason: "length"), try sse("second ", reason: "length"), try sse("third ", reason: "length"), try sse("last", reason: "stop")])
        var text = "", final: TurnMetrics?
        for try await event in ProviderChatService(session: session()).events(provider: .openRouter, modelID: "fixture/model", messages: [], apiKey: "fixture", mode: .chat, useWebSearch: false) {
            switch event { case .text(let part): text += part; case .metrics(let m): final = m; default: break }
        }
        XCTAssertEqual(text, "First second third last"); XCTAssertEqual(UncappedProviderFixture.snapshot().count, 4)
        XCTAssertEqual(final?.usage.outputTokens, 20); XCTAssertEqual(final?.costUSD ?? -1, 0.04, accuracy: 0.00001)
    }
    func testWebDefaultUsesExplicitExaWithoutSearchCapsAndOffRemainsOff() throws {
        for enabled in [true, false] {
            let request = try ProviderChatService.request(provider: .openRouter, modelID: "fixture/model", messages: [], apiKey: "fixture", mode: .chat, useWebSearch: enabled)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let tool = (body["tools"] as? [[String: Any]])?.first
            let parameters = tool?["parameters"] as? [String: Any]
            XCTAssertEqual(tool != nil, enabled); XCTAssertNil(parameters?["max_results"]); XCTAssertNil(body["max_tokens"])
            if enabled { XCTAssertEqual(parameters?["engine"] as? String, "exa"); XCTAssertEqual(tool?["type"] as? String, "openrouter:web_search") }
        }
    }
    func testMainChatPersistsOnlyObservedSearchActivityAndProviderReportedUsage() async throws {
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["usage": ["input_tokens": 10]]],
            ["type": "content_block_start", "content_block": ["type": "server_tool_use", "name": "web_search", "id": "search-1"]],
            ["type": "content_block_start", "content_block": ["type": "web_search_tool_result", "tool_use_id": "search-1", "content": []]],
            ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "A verified answer"]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 5, "server_tool_use": ["web_search_requests": 1]]],
            ["type": "message_stop"]
        ]
        let bytes = try events.map { "data: " + String(decoding: try json($0), as: UTF8.self) + "\n\n" }.joined()
        UncappedProviderFixture.reset([Data(bytes.utf8)])
        var observed: [NativeWebSearchActivity] = [], final: TurnMetrics?
        for try await event in ProviderChatService(session: session()).events(provider: .anthropic, modelID: "claude-sonnet-4-5", messages: [], apiKey: "fixture", mode: .chat, anthropicOutputTokens: 100, useWebSearch: true) {
            switch event { case .webSearch(let updates): observed += updates; case .metrics(let metrics): final = metrics; default: break }
        }
        XCTAssertEqual(observed.map(\.status), [.running, .completed])
        XCTAssertEqual(final?.webSearchActivities, [.init(id: "search-1", status: .completed, output: "[]")])
        XCTAssertEqual(final?.webSearchUsage?.requests, 1)
        XCTAssertEqual(final?.webSearchUsage?.additionalCostUSD, 0.01)
        XCTAssertNil(final?.costUSD, "A search fee alone does not prove the complete provider bill")
        XCTAssertEqual(UncappedProviderFixture.snapshot().count, 1)
    }
    func testAnthropicDescriptorMaxTokensFetchedAndCachedWithoutDefault() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ModelCatalogCache(directory: dir)
        UncappedProviderFixture.reset([try json(["id": "claude-fixture", "max_tokens": 128_000, "max_input_tokens": 200_000])])
        let output = try await ProviderModelOutput.resolve(provider: .anthropic, modelID: "claude-fixture", userLimit: nil, thinkingBudget: nil, apiKey: "fixture", session: session(), cache: cache)
        XCTAssertEqual(output, 128_000); XCTAssertEqual(UncappedProviderFixture.snapshot().first?.method, "GET")
        let cached = try await ProviderModelOutput.resolve(provider: .anthropic, modelID: "claude-fixture", userLimit: nil, thinkingBudget: nil, apiKey: "fixture", session: session(), cache: cache)
        XCTAssertEqual(cached, output); XCTAssertEqual(UncappedProviderFixture.snapshot().count, 1)
    }
    func testEntireRemoteCatalogAndAddedStateAreIndependentFromPins() throws {
        let name = "aim-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let models = (0..<130).map { ChatModel(id: "fixture/m\($0)", name: "Model \($0)") }
        try RemoteModelCatalogMetadata.setAdded(modelID: models[129].id, provider: .openRouter, added: true, defaults: defaults)
        let pin = try FavoriteModel(provider: .openRouter, modelID: models[0].id, name: models[0].name)
        let list = RemoteModelCatalogMetadata.announcements(models, provider: .openRouter, favorites: [pin], additions: RemoteModelCatalogMetadata.additions(defaults: defaults))
        XCTAssertEqual(list.count, 130); XCTAssertEqual(list[129].isAdded, true); XCTAssertEqual(list[129].isPinned, false)
        XCTAssertEqual(list[0].isAdded, false); XCTAssertEqual(list[0].isPinned, true)
    }
    func testScheduledRunCapReservesBeforeSendAndNoCapAllowsUnknownAttempts() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let capped = RunBudgetLedger(inner: ledger, capUSD: 1)
        let first = UUID()
        _ = try await capped.admit(id: first, provider: "fixture", modelID: "model", feature: "scheduled", conversationID: nil, maximumUSD: "0.6", exception: false, at: .now)
        do { _ = try await capped.admit(id: UUID(), provider: "fixture", modelID: "model", feature: "scheduled", conversationID: nil, maximumUSD: "0.6", exception: false, at: .now); XCTFail() }
        catch { XCTAssertEqual(error as? SpendAdmissionError, .limitReached) }
        try await capped.markNotSent(id: first, at: .now)
        for exception in [false, true] {
            do { _ = try await capped.admit(id: UUID(), provider: "fixture", modelID: "model", feature: "scheduled", conversationID: nil, maximumUSD: nil, exception: exception, at: .now); XCTFail() }
            catch { XCTAssertEqual(error as? SpendAdmissionError, .unknownBound) }
        }
        let uncapped = RunBudgetLedger(inner: ledger, capUSD: nil)
        for _ in 0..<8 {
            let id = UUID(); _ = try await uncapped.admit(id: id, provider: "fixture", modelID: "model", feature: "scheduled", conversationID: nil, maximumUSD: nil, exception: false, at: .now)
            try await uncapped.markSent(id: id, at: .now); try await uncapped.markUnknown(id: id)
        }
        let exhausted = await uncapped.exhausted; XCTAssertFalse(exhausted)
        let requires = try await capped.requiresVerifiedBound(at: .now); XCTAssertTrue(requires)
    }
}
