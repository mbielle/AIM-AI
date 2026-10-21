import AIMApplication
import XCTest

private final class MeteredChatFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/api/v1/models" { sendMeteredCatalog(self, request: request, client: client, priced: false); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MeteredChatReceiptFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/api/v1/models" { sendMeteredCatalog(self, request: request, client: client); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"cost\":0.00000017}}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func sendMeteredCatalog(_ fixture: URLProtocol, request: URLRequest, client: (any URLProtocolClient)?, priced: Bool = true) {
    // This fixture intentionally covers an unbounded attempt with no receipt;
    // bounded unknown exposure is reservedUSD rather than unknownAttempts.
    let data = priced ? Data(#"{"data":[{"id":"fixture","context_length":4096,"supported_parameters":["max_tokens"],"pricing":{"prompt":"0.000001","completion":"0.000002","request":"0"},"top_provider":{"max_completion_tokens":128}}]}"#.utf8) : Data(#"{"data":[]}"#.utf8)
    client?.urlProtocol(fixture, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(fixture, didLoad: data)
    client?.urlProtocolDidFinishLoading(fixture)
}

final class BillableRequestMeterTests: XCTestCase {
    func testOpenRouterUsageCostIsRecordedAsDecimalReceipt() async throws {
        XCTAssertEqual(OpenRouterUsageReceipt.costUSD(in: #"{"usage":{"cost":0.00000017}}"#), "0.00000017")
        XCTAssertNil(OpenRouterUsageReceipt.costUSD(in: #"{"usage":{"cost":-1}}"#))
        XCTAssertNil(OpenRouterUsageReceipt.costUSD(in: #"{"usage":{"cost":0.0000000000000000001}}"#))
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeteredChatReceiptFixture.self]
        let service = ProviderChatService(session: URLSession(configuration: config),
            meter: BillableRequestMeter(ledger: ledger))
        var response = ""
        for try await part in service.stream(provider: .openRouter, modelID: "fixture",
                                             messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Hello", sequence: 0)], apiKey: "fake", mode: .chat) { response += part }
        XCTAssertEqual(response, "Hello")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.confirmedUSD, "0.00000017")
        XCTAssertEqual(snapshot.unknownAttempts, 0)
    }

    func testExceptionAuthorizesOnlyTheExactAttemptAndDenialSendsNothing() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00",
            period: .envelope, timeZoneID: "Europe/Paris"))
        let broker = SpendExceptionBroker()
        let meter = BillableRequestMeter(ledger: ledger, exceptions: broker)
        let counter = BillableOperationCounter()
        let first = Task {
            try await meter.perform(provider: "fixture", modelID: "unknown", feature: "agent") {
                await counter.increment()
                return "done"
            }
        }
        let request = try await nextException(broker)
        XCTAssertEqual(request.provider, "fixture")
        XCTAssertEqual(request.modelID, "unknown")
        XCTAssertEqual(request.snapshot.policy.limitUSD, "1.00")
        let before = await counter.count
        XCTAssertEqual(before, 0)
        let approved = await broker.decide(id: request.id, allow: true)
        XCTAssertTrue(approved)
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, "done")
        let attempts = try await ledger.recentAttempts()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.id, request.id)
        XCTAssertEqual(attempts.first?.isException, true)
        XCTAssertEqual(attempts.first?.state, .unknown)

        let retry = Task {
            try await meter.perform(provider: "fixture", modelID: "unknown", feature: "agent") {
                await counter.increment()
                return "unexpected"
            }
        }
        let second = try await nextException(broker)
        XCTAssertNotEqual(second.id, request.id)
        let denied = await broker.decide(id: second.id, allow: false)
        XCTAssertTrue(denied)
        do { _ = try await retry.value; XCTFail("Denied attempt must not be sent") }
        catch SpendAdmissionError.exceptionDeclined {}
        let after = await counter.count
        XCTAssertEqual(after, 1)
        let afterAttempts = try await ledger.recentAttempts()
        XCTAssertEqual(afterAttempts.count, 1)
    }

    func testCancellingAWaitingExceptionDoesNotSendOrLeaveAnApproval() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00",
            period: .calendarMonth, timeZoneID: "Europe/Paris"))
        let broker = SpendExceptionBroker()
        let meter = BillableRequestMeter(ledger: ledger, exceptions: broker)
        let counter = BillableOperationCounter()
        let waiting = Task {
            try await meter.perform(provider: "fixture", modelID: "unknown", feature: "voice") {
                await counter.increment()
                return "unexpected"
            }
        }
        _ = try await nextException(broker)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled attempt must not be sent") }
        catch SpendAdmissionError.exceptionDeclined {}
        let pending = await broker.snapshot()
        let calls = await counter.count
        let attempts = try await ledger.recentAttempts()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testConcurrentExceptionsCannotAuthorizeAnotherProviderAttempt() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00",
            period: .day, timeZoneID: "Europe/Paris"))
        let broker = SpendExceptionBroker()
        let meter = BillableRequestMeter(ledger: ledger, exceptions: broker)
        let a = Task {
            try await meter.perform(provider: "alpha", modelID: "a", feature: "chat") { "alpha sent" }
        }
        let b = Task {
            try await meter.perform(provider: "beta", modelID: "b", feature: "voice") { "beta sent" }
        }
        var pending: [PendingSpendException] = []
        for _ in 0..<200 {
            pending = await broker.snapshot()
            if pending.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(pending.count, 2)
        let alpha = try XCTUnwrap(pending.first { $0.provider == "alpha" })
        let beta = try XCTUnwrap(pending.first { $0.provider == "beta" })
        XCTAssertNotEqual(alpha.id, beta.id)
        let wrong = await broker.decide(id: UUID(), allow: true)
        XCTAssertFalse(wrong)
        _ = await broker.decide(id: alpha.id, allow: true)
        _ = await broker.decide(id: beta.id, allow: false)
        let value = try await a.value
        XCTAssertEqual(value, "alpha sent")
        do { _ = try await b.value; XCTFail("Beta must remain denied") }
        catch SpendAdmissionError.exceptionDeclined {}
        let attempts = try await ledger.recentAttempts()
        XCTAssertEqual(attempts.map(\.provider), ["alpha"])
        XCTAssertEqual(attempts.first?.id, alpha.id)
    }

    private func nextException(_ broker: SpendExceptionBroker) async throws -> PendingSpendException {
        for _ in 0..<200 {
            if let request = await broker.snapshot().first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Spend exception did not appear", code: 1)
    }

    func testChatRequestIsRecordedOnceWithUnknownCostWhenNoCapIsEnabled() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeteredChatFixture.self]
        let service = ProviderChatService(session: URLSession(configuration: config),
            meter: BillableRequestMeter(ledger: ledger))
        var response = ""
        for try await part in service.stream(provider: .openRouter, modelID: "fixture",
                                             messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Hello", sequence: 0)], apiKey: "fake", mode: .chat) {
            response += part
        }
        XCTAssertEqual(response, "Hello")
        let usage = try await ledger.snapshot()
        XCTAssertEqual(usage.unknownAttempts, 1)
    }

    func testActiveCapRefusesUnboundedChatBeforeNetwork() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .envelope,
                                                     timeZoneID: "Europe/Paris"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeteredChatFixture.self]
        let service = ProviderChatService(session: URLSession(configuration: config),
            meter: BillableRequestMeter(ledger: ledger))
        do {
            for try await _ in service.stream(provider: .openRouter, modelID: "unpriced",
                                               messages: [], apiKey: "fake", mode: .chat, useWebSearch: false) {}
            XCTFail("A cap with no verified price bound must refuse this attempt")
        } catch SpendAdmissionError.unknownBound {}
        let usage = try await ledger.snapshot()
        XCTAssertEqual(usage.unknownAttempts, 0)
    }

    func testMeterKeepsTimeoutExposureAndCanReconcileReceipt() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let meter = BillableRequestMeter(ledger: ledger)
        do {
            let _: String = try await meter.perform(provider: "fixture", modelID: "model", feature: "agent") {
                throw URLError(.timedOut)
            }
            XCTFail("Timeout expected")
        } catch is URLError {}
        let afterTimeout = try await ledger.snapshot()
        XCTAssertEqual(afterTimeout.unknownAttempts, 1)
        let value: String = try await meter.perform(provider: "fixture", modelID: "model", feature: "agent",
                                                    receiptUSD: { _ in "0.10" }) { "ok" }
        XCTAssertEqual(value, "ok")
        let usage = try await ledger.snapshot()
        XCTAssertEqual(usage.countedUSD, "0.1")
        XCTAssertEqual(usage.unknownAttempts, 1)
    }

    func testParallelRequestWaitsForInFlightReservationsInsteadOfFailing() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .envelope))
        let meter = BillableRequestMeter(ledger: ledger)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await meter.perform(provider: "fixture", modelID: "model", feature: "agent", maximumUSD: "0.60",
                                    receiptUSD: { (_: String) in "0.05" }) {
                for await _ in gate { break }
                return "first"
            }
        }
        while try await ledger.snapshot().reservedUSD == "0" { try await Task.sleep(for: .milliseconds(10)) }
        let second = Task {
            try await meter.perform(provider: "fixture", modelID: "model", feature: "agent", maximumUSD: "0.60",
                                    receiptUSD: { (_: String) in "0.05" }) { "second" }
        }
        try await Task.sleep(for: .milliseconds(300))
        open.yield(); open.finish()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual([firstValue, secondValue], ["first", "second"])
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.confirmedUSD, "0.1")
        // With no request in flight there is nothing to wait for: the refusal stays immediate.
        do {
            let _: String = try await meter.perform(provider: "fixture", modelID: "model", feature: "agent",
                                                    maximumUSD: "0.95") { "never" }
            XCTFail("Limit expected")
        } catch SpendAdmissionError.limitReached {}
    }
}

private actor BillableOperationCounter {
    var count = 0
    func increment() { count += 1 }
}
