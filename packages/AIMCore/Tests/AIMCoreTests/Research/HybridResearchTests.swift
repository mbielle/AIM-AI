import Foundation
import XCTest
@testable import AIMCore

private final class ResearchFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    func record(_ request: URLRequest) { lock.lock(); captured.append(request); lock.unlock() }
    func reset() { lock.lock(); captured = []; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
}

private final class ResearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = ResearchFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    private func body() throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] } ?? [:]
    }
    override func startLoading() {
        Self.state.record(request)
        do {
            let url = try XCTUnwrap(request.url), host = url.host ?? "", body = try body()
            let payload: Data, contentType: String, status: Int
            if host == "api.exa.ai", body["query"] as? String == "fixture oversized" {
                status = 200; contentType = "application/json"
                payload = Data(repeating: 32, count: AIMResearchHTTPClient.maximumResponseBytes + 1)
            } else if host == "api.exa.ai" {
                if body["query"] as? String == "fixture quota" { status = 402; payload = Data(#"{"error":"fixture quota"}"#.utf8) }
                else {
                    status = 200
                    payload = Data(#"{"results":[{"url":"https://docs.example.com/page","title":"Fixture documentation","highlights":["Search fixture excerpt"]},{"url":"https://docs.example.com/page#duplicate","title":"Duplicate","highlights":["Repeated"]},{"url":"https://127.0.0.1/private","title":"Unsafe"}],"costDollars":{"total":0.007}}"#.utf8)
                }
                contentType = "application/json"
            } else if host == "api.search.brave.com" {
                status = 200; contentType = "application/json"
                payload = Data(#"{"web":{"results":[{"url":"https://docs.example.com/page","title":"Fixture documentation","description":"Brave fixture excerpt","extra_snippets":["Additional fixture"]}]}}"#.utf8)
            } else if host == "docs.example.com" {
                status = 200; contentType = "text/html"
                payload = Data("<html><script>doNotExposeScript()</script><style>.hidden{}</style><main>Verified page fixture &amp; useful content.</main></html>".utf8)
            } else {
                status = 200; contentType = "application/json"
                let names = (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String ?? $0["name"] as? String }
                guard names.contains("web_search"), names.contains("web_read"),
                      !(body["tools"] as? [[String: Any]] ?? []).contains(where: { $0["type"] as? String == "openrouter:web_search" }) else { throw AIMResearchError.invalidArguments }
                if body["model"] as? String == "fixture/malformed-paid-research" {
                    let response: [String: Any] = ["choices": [["message": ["role": "assistant", "tool_calls": [["id": "invalid", "function": ["name": "web_search", "arguments": "{invalid"]]]], "finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.01]]
                    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
                    client?.urlProtocolDidFinishLoading(self); return
                }
                let history = body["messages"] as? [[String: Any]] ?? []
                let count = history.filter { $0["role"] as? String == "tool" }.count + history.reduce(0) { partial, item in
                    partial + ((item["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "tool_result" }.count ?? 0)
                }
                let name = count == 0 ? "web_search" : "web_read"
                let args = count == 0 ? ["query": "fixture topic"] : ["resultID": "web-1"]
                let anthropic = (body["model"] as? String ?? "").contains("anthropic")
                let response: [String: Any]
                if anthropic {
                    let content: [[String: Any]] = count < 2 ? [["type": "tool_use", "id": "research-\(count)", "name": name, "input": args]] : [["type": "text", "text": "Fixture answer [source](https://docs.example.com/page)."]]
                    response = ["type": "message", "content": content, "stop_reason": count < 2 ? "tool_use" : "end_turn", "usage": ["input_tokens": 10, "output_tokens": 5]]
                } else {
                    let message: [String: Any] = count < 2 ? ["role": "assistant", "content": "", "tool_calls": [["id": "research-\(count)", "type": "function", "function": ["name": name, "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]]] : ["role": "assistant", "content": "Fixture answer [source](https://docs.example.com/page)."]
                    response = ["choices": [["message": message, "finish_reason": count < 2 ? "tool_calls" : "stop"]], "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.01]]
                }
                payload = try JSONSerialization.data(withJSONObject: response)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": contentType])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class HybridResearchTests: XCTestCase {
    private func session() -> URLSession {
        ResearchFixtureProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func runtime(_ session: URLSession, mode: AIMResearchMode = .exa) -> AIMResearchSession {
        AIMResearchSession(mode: mode, credential: { "fixture-search-key" }, client: .init(session: session), resolvesPublicly: { _ in true })
    }
    func testExaSearchAndReadAreRealBoundedRequestsCachedAndDeduplicatedWithoutLeakingKey() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        let first = try await runtime.execute(name: "web_search", arguments: ["query": "fixture topic"])
        let cached = try await runtime.execute(name: "web_search", arguments: ["query": "fixture topic"])
        XCTAssertEqual(first.sources.count, 1); XCTAssertTrue(cached.text.contains("\"cached\":true"))
        XCTAssertFalse(first.text.contains("127.0.0.1"))
        let page = try await runtime.execute(name: "web_read", arguments: ["resultID": "web-1"])
        XCTAssertTrue(page.text.contains("Verified page fixture & useful content")); XCTAssertFalse(page.text.contains("doNotExposeScript"))
        _ = try await runtime.execute(name: "web_read", arguments: ["resultID": "web-1"])
        let requests = ResearchFixtureProtocol.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "api.exa.ai")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "fixture-search-key")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "x-api-key")); XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie")); XCTAssertNil(requests[1].value(forHTTPHeaderField: "Referer"))
        let usage = await runtime.usage()
        XCTAssertEqual(usage.requests, 1); XCTAssertEqual(usage.additionalCostUSD, 0.007)
    }
    func testBraveOwnHeaderAndResponseRemainUnknownWithoutAReceipt() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session, mode: .brave)
        let result = try await runtime.execute(name: "web_search", arguments: ["query": "fixture topic"])
        XCTAssertTrue(result.text.contains("Additional fixture"))
        let request = try XCTUnwrap(ResearchFixtureProtocol.state.requests.first)
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "fixture-search-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let usage = await runtime.usage(); XCTAssertNil(usage.additionalCostUSD)
        let combined = AIMResearchAccounting.combined(modelTotalUSD: 0.02, research: usage)
        XCTAssertEqual(combined.providerTotalCostUSD, 0.02, "Only the model invoice is attributed to the model provider")
        XCTAssertNil(combined.externalSearchCostUSD); XCTAssertEqual(combined.externalCostsTrackedSeparately, true)
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: .init(), pricing: nil, webSearch: combined), 0.02)
    }
    func testDistinctAPIInvoicesNeverCreateAForeignCombinedProviderReceipt() {
        let combined = AIMResearchAccounting.combined(modelTotalUSD: 0.02, research: .init(requests: 1, additionalCostUSD: 0.007))
        XCTAssertEqual(combined.providerTotalCostUSD, 0.02)
        XCTAssertEqual(combined.externalSearchCostUSD, 0.007)
        XCTAssertEqual(combined.additionalCostUSD, 0)
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: .init(), pricing: nil, webSearch: combined), 0.02)
        XCTAssertNil(AIMResearchAccounting.combined(modelTotalUSD: nil, research: .init(additionalCostUSD: 0.007)).providerTotalCostUSD)
    }
    func testInvalidReadIDsURLsAndArgumentsNeverFetchAPage() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        for arguments in [["resultID": "https://127.0.0.1/private"], ["resultID": "missing"], ["url": "https://docs.example.com/page"]] {
            do { _ = try await runtime.execute(name: "web_read", arguments: arguments); XCTFail("Arbitrary URL read was allowed") }
            catch { XCTAssertEqual(error as? AIMResearchError, .invalidArguments) }
        }
        XCTAssertTrue(ResearchFixtureProtocol.state.requests.isEmpty)
    }
    func testNoPaidFallbackOrFurtherRequestAfterQuotaFailure() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        do { _ = try await runtime.execute(name: "web_search", arguments: ["query": "fixture quota"]); XCTFail("Quota failure was hidden") }
        catch { XCTAssertEqual(error as? AIMResearchError, .http(402)) }
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 1)
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.first?.url?.host, "api.exa.ai")
        let usage = await runtime.usage(); XCTAssertNil(usage.additionalCostUSD)
    }
    func testSearchRequestAndToolResultCeilingsAreFinite() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        for index in 0..<4 { _ = try await runtime.execute(name: "web_search", arguments: ["query": "fixture query \(index)"]) }
        do { _ = try await runtime.execute(name: "web_search", arguments: ["query": "fifth query"]); XCTFail("Network cap was ignored") }
        catch { XCTAssertEqual(error as? AIMResearchError, .limitReached) }
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 4)
        _ = try await runtime.execute(name: "web_search", arguments: ["query": "fixture query 0"])
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 4)
    }
    func testRealModelToolLoopSupportsBothWireFormatsWithoutHostedTools() async throws {
        for provider in [ChatProvider.openRouter, .anthropic] {
            let session = session(); defer { session.invalidateAndCancel() }
            let runtime = runtime(session)
            var events: [NativeChatEvent] = []
            for try await event in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: provider,
                modelID: provider == .anthropic ? "fixture/anthropic-research" : "fixture/research", messages: [.init(role: .user, text: "Research the fixture")],
                key: "fixture-model-key", maxOutputTokens: 128, research: runtime) { events.append(event) }
            XCTAssertTrue(events.last?.isComplete == true)
            XCTAssertTrue(events.map(\.text).joined().contains("Fixture answer"))
            let activities = events.compactMap(\.webSearchActivities).flatMap { $0 }
            XCTAssertEqual(activities.map(\.status), [.running, .completed, .running, .completed])
            XCTAssertTrue(activities[2].input?.contains("open_page") == true)
            XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 5)
            let metadata = try XCTUnwrap(events.compactMap(\.webSearchUsage).last)
            XCTAssertEqual(metadata.externalSearchCostUSD, 0.007)
            if provider == .openRouter { XCTAssertEqual(metadata.providerTotalCostUSD ?? -1, 0.03, accuracy: 0.0000001) }
            else { XCTAssertNil(metadata.providerTotalCostUSD) }
        }
    }
    func testHostedAndAIMSearchCannotRunInParallelAndAdmissionCanRejectBeforeAnyRequest() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        do {
            for try await _ in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter,
                modelID: "fixture/research", messages: [.init(role: .user, text: "Fixture")], key: "fixture-model-key", webSearch: true, research: runtime) {}
            XCTFail("Hosted and orchestrated were enabled together")
        } catch { XCTAssertEqual(error as? AIMResearchError, .invalidArguments) }
        do {
            for try await _ in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter,
                modelID: "fixture/research", messages: [.init(role: .user, text: "Fixture")], key: "fixture-model-key", research: runtime,
                researchAdmission: { _, _, _ in throw AIMResearchError.strictBudget }) {}
            XCTFail("Admission denial made a request")
        } catch { XCTAssertEqual(error as? AIMResearchError, .strictBudget) }
        XCTAssertTrue(ResearchFixtureProtocol.state.requests.isEmpty)
    }
    func testMalformedModelToolArgumentsKeepValidProviderReceiptWithoutAnAPICallOrRetry() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        var events: [NativeChatEvent] = []
        do {
            for try await event in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter,
                modelID: "fixture/malformed-paid-research", messages: [.init(role: .user, text: "Fixture")], key: "fixture-model-key", research: runtime) {
                events.append(event)
            }
            XCTFail("Malformed paid tool arguments were accepted")
        } catch ChatServiceError.invalidResponse {}
        catch { XCTFail("Unexpected model response error") }
        XCTAssertEqual(events.compactMap(\.usage).last?.inputTokens, 10)
        XCTAssertEqual(events.compactMap(\.webSearchUsage).last?.providerTotalCostUSD, 0.01)
        XCTAssertTrue(events.compactMap(\.webSearchActivities).isEmpty)
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 1)
        XCTAssertFalse(events.contains { $0.isComplete })
    }
    func testReceivedModelReceiptCanStopResearchBeforeAnyExternalAPICall() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        do {
            for try await _ in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter,
                modelID: "fixture/research", messages: [.init(role: .user, text: "Fixture")], key: "fixture-model-key", research: runtime,
                researchWillExecute: { usage, metadata in
                    XCTAssertEqual(usage.inputTokens, 10)
                    XCTAssertEqual(metadata.providerTotalCostUSD, 0.01)
                    XCTAssertEqual(metadata.externalSearchCostUSD, 0)
                    throw AIMResearchError.strictBudget
                }) {}
            XCTFail("Research continued after its received model bill exhausted admission")
        } catch { XCTAssertEqual(error as? AIMResearchError, .strictBudget) }
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 1)
        XCTAssertFalse(ResearchFixtureProtocol.state.requests.contains { $0.url?.host == "api.exa.ai" })
    }
    func testOversizedSearchResponseFailsAtTheDownloadBoundWithoutFallback() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = runtime(session)
        do { _ = try await runtime.execute(name: "web_search", arguments: ["query": "fixture oversized"]); XCTFail("Oversized response was accepted") }
        catch { XCTAssertEqual(error as? AIMResearchError, .responseTooLarge) }
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 1)
    }
    func testPrivateDNSResolutionRejectsPageBeforeLoadingIt() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let runtime = AIMResearchSession(mode: .exa, credential: { "fixture-search-key" }, client: .init(session: session), resolvesPublicly: { _ in false })
        _ = try await runtime.execute(name: "web_search", arguments: ["query": "fixture topic"])
        do { _ = try await runtime.execute(name: "web_read", arguments: ["resultID": "web-1"]); XCTFail("Private DNS target was loaded") }
        catch { XCTAssertEqual(error as? AIMResearchError, .unsafeURL) }
        XCTAssertEqual(ResearchFixtureProtocol.state.requests.count, 1)
    }
    func testCancellationStopsResearchWithoutACompletedResultOrKnownCharge() async throws {
        let gate = ResearchCancellationGate()
        let runtime = AIMResearchSession(mode: .exa, credential: { "fixture-search-key" }, perform: { _ in try await gate.perform() })
        let task = Task { try await runtime.execute(name: "web_search", arguments: ["query": "fixture delay"]) }
        for _ in 0..<500 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        let started = await gate.started; XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned a result") } catch { XCTAssertTrue(error is CancellationError) }
        let usage = await runtime.usage(); XCTAssertNil(usage.additionalCostUSD)
    }
    func testPricingIsAnExpiringEstimateAndPreferencesDecodeOldDefault() throws {
        XCTAssertEqual(AIMResearchPricing.searchEstimateUSD(mode: .exa, at: AIMResearchPricing.reviewedAt), 0.007)
        XCTAssertEqual(AIMResearchPricing.searchEstimateUSD(mode: .brave, at: AIMResearchPricing.reviewedAt), 0.005)
        XCTAssertNil(AIMResearchPricing.searchEstimateUSD(mode: .exa, at: AIMResearchPricing.reviewedAt.addingTimeInterval(31 * 86_400)))
        let legacy = try JSONDecoder().decode(AccountChatPreferences.self, from: JSONEncoder().encode(AccountChatPreferences()))
        XCTAssertEqual(legacy.resolvedResearchMode, .hosted)
    }
}

private actor ResearchCancellationGate {
    private(set) var started = false
    func perform() async throws -> AIMResearchHTTPResponse {
        started = true
        try await Task.sleep(for: .seconds(30))
        return .init(data: Data())
    }
}
