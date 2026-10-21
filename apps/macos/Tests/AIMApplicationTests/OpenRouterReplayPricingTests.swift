import AIMApplication
import XCTest

/// No sockets: both pricing catalog and model responses are URLProtocol fixtures.
private final class ReplayPriceFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            if request.url?.path == "/api/v1/models" {
                let models = ["replay-null", "replay-absent", "replay-unknown", "replay-media"]
                let rows: [[String: Any]] = models.map {
                    ["id": $0, "context_length": 4096, "supported_parameters": ["max_tokens"],
                     "top_provider": ["max_completion_tokens": 128],
                     "pricing": ["prompt": "0.00001", "completion": "0.00002", "request": "0"]]
                }
                respond(try JSONSerialization.data(withJSONObject: ["data": rows]))
                return
            }
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let model = try XCTUnwrap(body["model"] as? String)
            let history = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(body["max_tokens"] as? Int, 128)
            XCTAssertEqual((body["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
            XCTAssertEqual((body["usage"] as? [String: Bool])?["include"], true)
            let followup = history.last?["role"] as? String == "tool"
            var message: [String: Any] = ["role": "assistant", "content": NSNull(), "model": "fixture-engine",
                "refusal": NSNull(), "annotations": [],
                "reasoning": NSNull(), "reasoning_details": [["type": "reasoning.encrypted", "data": "exact-opaque"]],
                "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]]]
            if model == "replay-absent" { message.removeValue(forKey: "content") }
            if model == "replay-unknown" { message["future_paid_input"] = ["rate": "unknown"] }
            if model == "replay-media" { message["audio"] = ["data": "opaque-audio"] }
            if followup {
                XCTAssertFalse(["replay-unknown", "replay-media"].contains(model), "An unbounded replay must never reach the provider")
                let assistant = try XCTUnwrap(history.dropLast().last)
                XCTAssertTrue(assistant["content"] is NSNull)
                XCTAssertTrue(assistant["refusal"] is NSNull)
                XCTAssertEqual(assistant["model"] as? String, "fixture-engine")
                XCTAssertEqual((assistant["annotations"] as? [Any])?.count, 0)
                XCTAssertEqual((assistant["reasoning_details"] as? [[String: String]])?.first?["data"], "exact-opaque")
                XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "call_1")
                XCTAssertEqual(history.last?["tool_call_id"] as? String, "call_1")
                XCTAssertTrue((history.last?["content"] as? String ?? "").contains("Exact fixture result"))
                message = ["role": "assistant", "content": "Done"]
            }
            let response = try JSONSerialization.data(withJSONObject: ["choices": [[
                "finish_reason": followup ? "stop" : "tool_calls", "message": message]]])
            // Avoid Double round-trip altering the provider's monetary JSON token.
            let text = String(decoding: response, as: UTF8.self)
            respond(Data((String(text.dropLast()) + ",\"usage\":{\"cost\":" + (followup ? "0.006" : "0.005") + "}}").utf8))
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func respond(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenRouterReplayPricingTests: XCTestCase {
    private func conversation(_ model: String, ledger: SQLiteGlobalSpendLedger) throws -> ProviderToolConversation {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayPriceFixture.self]
        return try ProviderToolConversation(modelID: model, messages: [], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read fixture", requiredArguments: ["path"])],
            session: URLSession(configuration: configuration), meter: BillableRequestMeter(ledger: ledger))
    }

    func testCappedToolOnlyReplySurvivesCheckpointAndTwoPricedCalls() async throws {
        for model in ["replay-null", "replay-absent"] {
            let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
            try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "2", period: .envelope, timeZoneID: "UTC"))
            let firstService = try conversation(model, ledger: ledger)
            let first = try await firstService.next(outputs: [])
            XCTAssertEqual(first.calls.map(\.id), ["call_1"])
            let checkpoint = try await firstService.exportCheckpoint()
            let restored = try conversation(model, ledger: ledger)
            try await restored.restoreCheckpoint(checkpoint)
            let second = try await restored.next(outputs: [ModelToolOutput(id: "call_1", content: "Exact fixture result", isError: false)])
            XCTAssertEqual(second.text, "Done")
            XCTAssertTrue(second.calls.isEmpty)
            let snapshot = try await ledger.snapshot()
            XCTAssertEqual(snapshot.confirmedUSD, "0.011")
            XCTAssertEqual(snapshot.reservedUSD, "0")
            XCTAssertEqual(snapshot.unknownAttempts, 0)
        }
    }

    func testUnknownOrMediaReplyBlocksSecondSendWithoutStrippingCheckpoint() async throws {
        for model in ["replay-unknown", "replay-media"] {
            let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
            try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "2", period: .envelope, timeZoneID: "UTC"))
            let service = try conversation(model, ledger: ledger)
            _ = try await service.next(outputs: [])
            let checkpoint = try await service.exportCheckpoint()
            let history = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpoint.transcript) as? [[String: Any]])
            XCTAssertNotNil(history.last?[model == "replay-media" ? "audio" : "future_paid_input"])
            do {
                _ = try await service.next(outputs: [ModelToolOutput(id: "call_1", content: "Exact fixture result", isError: false)])
                XCTFail("The second request must not be authorized")
            } catch SpendAdmissionError.unknownBound { }
            let snapshot = try await ledger.snapshot()
            XCTAssertEqual(snapshot.confirmedUSD, "0.005")
            XCTAssertEqual(snapshot.reservedUSD, "0")
            XCTAssertEqual(snapshot.unknownAttempts, 0)
        }
    }
}
