import AIMCore
import Foundation
import XCTest
@testable import AIMApplication

private final class MacResearchRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    func reset() { lock.lock(); captured = []; lock.unlock() }
    func record(_ request: URLRequest) { lock.lock(); captured.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
}
private final class MacResearchModelProtocol: URLProtocol, @unchecked Sendable {
    static let state = MacResearchRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.state.record(request)
        do {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
                data = bytes
            }
            let body = try XCTUnwrap(data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            let bad = (body["model"] as? String) == "fixture/invalid-research"
            let history = body["messages"] as? [[String: Any]] ?? []
            let count = history.filter { $0["role"] as? String == "tool" }.count
            let tools = body["tools"] as? [[String: Any]] ?? []
            guard tools.count == 2, tools.allSatisfy({ $0["type"] as? String == "function" }) else { throw AIMResearchError.invalidArguments }
            let name = count == 0 ? "web_search" : "web_read"
            let args = count == 0 ? ["query": "fixture topic"] : ["resultID": "web-1"]
            let message: [String: Any]
            if bad { message = ["role": "assistant", "content": "", "tool_calls": [["id": "bad", "type": "function", "function": ["name": "web_search", "arguments": "{invalid"]]]] }
            else if count < 2 { message = ["role": "assistant", "content": "", "tool_calls": [["id": "research-\(count)", "type": "function", "function": ["name": name, "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]]] }
            else { message = ["role": "assistant", "content": "Verified synthetic answer."] }
            let response: [String: Any] = ["choices": [["message": message, "finish_reason": bad || count < 2 ? "tool_calls" : "stop"]], "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.01]]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class HybridResearchConversationTests: XCTestCase {
    private var originalArguments: [String: Any] = [:]
    override func setUp() {
        let defaults = AIMInstallationContext.sharedPreferences
        originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments[RuntimePrivacyPolicy.defaultsKey] = false
        arguments[AIMNetworkPrivacyPolicy.defaultsKey] = false
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    override func tearDown() {
        AIMInstallationContext.sharedPreferences.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    }
    private func session() -> URLSession {
        MacResearchModelProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MacResearchModelProtocol.self]
        return URLSession(configuration: config)
    }
    private func runtime() -> AIMResearchSession {
        AIMResearchSession(mode: .exa, credential: { "fixture-search-key" }, perform: { operation in
            if operation.kind == .page { return .init(data: Data("Verified page fixture".utf8), contentType: "text/plain", externalAPICostUSD: 0) }
            return .init(data: Data(#"{"results":[{"url":"https://docs.example.com/page","title":"Fixture","highlights":["Indexed fixture"]}]}"#.utf8), externalAPICostUSD: 0.007)
        }, resolvesPublicly: { _ in true })
    }
    func testChatResearchUsesExistingMeteredConversationRealToolsAndSeparateInvoiceMetadata() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let service = ProviderChatService(session: session, meter: .init(ledger: ledger))
        var text = "", actions: [NativeWebSearchActivity] = [], metrics: TurnMetrics?
        for try await event in service.events(provider: .openRouter, modelID: "fixture/research", messages: [
            .init(conversationID: UUID(), role: .user, content: "Research fixture", sequence: 0)
        ], apiKey: "fixture-model-key", mode: .chat, research: runtime()) {
            if case .text(let value) = event { text += value }
            if case .webSearch(let values) = event { actions += values }
            if case .metrics(let value) = event { metrics = value }
        }
        XCTAssertEqual(text, "Verified synthetic answer.")
        XCTAssertEqual(actions.map(\.status), [.running, .completed, .running, .completed])
        XCTAssertEqual(metrics?.webSearchUsage?.providerTotalCostUSD ?? -1, 0.03, accuracy: 0.000001)
        XCTAssertEqual(metrics?.webSearchUsage?.externalSearchCostUSD, 0.007)
        XCTAssertEqual(metrics?.costUSD ?? -1, 0.03, accuracy: 0.000001)
        XCTAssertEqual(MacResearchModelProtocol.state.requests.count, 3)
        let attempts = try await ledger.recentAttempts()
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0.provider == ChatProvider.openRouter.rawValue && $0.actualUSD == "0.01" })
    }
    func testCompletedSearchWithoutReceiptRetainsUnknownCostWithoutAnEstimatedBudgetReservation() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(.init(enabled: true, limitUSD: "50", period: .envelope))
        let meter = BillableRequestMeter(ledger: ledger)
        let result = try await meter.perform(provider: "research.brave", modelID: "search", feature: "chat-research-search",
            maximumUSD: "0.005", completedWithoutReceipt: true) { "Synthetic search result without receipt" }
        XCTAssertEqual(result, "Synthetic search result without receipt")
        let attempts = try await ledger.recentAttempts()
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt.state, .unknown); XCTAssertNil(attempt.actualUSD)
        XCTAssertEqual(attempt.maximumUSD, "0.005", "Keep admission history without pretending it was a receipt")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.reservedUSD, "0"); XCTAssertEqual(snapshot.confirmedUSD, "0")
        XCTAssertEqual(snapshot.unknownAttempts, 1)
        let breakdown = try await ledger.breakdown()
        XCTAssertEqual(breakdown.providers.first?.unknownAttempts, 1)
        XCTAssertEqual(breakdown.providers.first?.reservedUSD, "0")
        _ = try await ledger.admit(provider: "fixture", modelID: "next", feature: "chat", maximumUSD: "0.01")
        try await ledger.configure(.init(enabled: true, limitUSD: "50", period: .envelope, requiresVerifiedWebSearch: true))
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "strict", feature: "chat", maximumUSD: "0.01")
            XCTFail("A completed unknown invoice widened strict admission")
        } catch SpendAdmissionError.unknownBound {}
    }

    func testCompletedFailedSearchDoesNotInventZeroOrKeepAPersonalReservation() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let meter = BillableRequestMeter(ledger: ledger)
        do {
            let _: String = try await meter.perform(provider: "research.brave", modelID: "search", feature: "chat-research-search",
                maximumUSD: "0.005", completedWithoutReceipt: true) { throw URLError(.cancelled) }
            XCTFail("Cancelled search returned a result")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        let attempts = try await ledger.recentAttempts()
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts[0].state, .unknown)
        XCTAssertNil(attempts[0].actualUSD)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.reservedUSD, "0"); XCTAssertEqual(snapshot.unknownAttempts, 1)
    }

    func testCompletedUnknownSearchCannotReleaseAMissionCeiling() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let run = RunBudgetLedger(inner: ledger, capUSD: 1)
        let meter = BillableRequestMeter(ledger: run)
        let _: String = try await meter.perform(provider: "research.brave", modelID: "search", feature: "chat-research-search",
            maximumUSD: "0.005", completedWithoutReceipt: true) { "Synthetic result" }
        let unknown = await run.unknownAttempts
        XCTAssertEqual(unknown, 1)
        do {
            _ = try await run.admit(id: UUID(), provider: "fixture", modelID: "next", feature: "mission",
                conversationID: nil, maximumUSD: "0.01", exception: false, at: .now)
            XCTFail("Completed unknown API cost widened a mission's spending authorization")
        } catch SpendAdmissionError.unknownBound {}
    }

    func testInvalidPaidModelResponseIsNeverAutomaticallyRetriedOrMovedToAnotherProvider() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            for try await _ in ProviderChatService(session: session).events(provider: .openRouter, modelID: "fixture/invalid-research", messages: [
                .init(conversationID: UUID(), role: .user, content: "Fixture", sequence: 0)
            ], apiKey: "fixture-model-key", mode: .chat, research: runtime()) {}
            XCTFail("Invalid tool response was accepted")
        } catch { }
        XCTAssertEqual(MacResearchModelProtocol.state.requests.count, 1)
        XCTAssertEqual(MacResearchModelProtocol.state.requests.first?.url?.host, "openrouter.ai")
    }
}
