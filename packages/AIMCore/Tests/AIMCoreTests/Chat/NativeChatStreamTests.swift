import Foundation
import XCTest
@testable import AIMCore

private final class StreamFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            body = result
        }
        let model = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["model"] as? String ?? ""
        let text = #"{"choices":[{"delta":{"content":"Bonjour été"},"finish_reason":"stop"}]}"#
        let usage = model == "fixture/web-cost"
            ? #"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3,"cost":0.017,"server_tool_use":{"web_search_requests":2}}}"#
            : #"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#
        let payload: String
        if model == "fixture/fragmented" {
            payload = "\u{FEFF}: heartbeat\r\nevent: message\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Bonjour été\"},\r\ndata: \"finish_reason\":\"stop\"}]}\r\n\r\n: ping\r\n\r\ndata: \(usage)\r\n\r\ndata: [DONE]\r\n\r\n"
        } else { payload = "data: \(text)\n\ndata: \(usage)\n\n" + (model == "fixture/truncated" ? "data: [DONE]" : "data: [DONE]\n\n") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if model == "fixture/fragmented" {
            for byte in payload.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        } else { client?.urlProtocol(self, didLoad: Data(payload.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NativeChatStreamTests: XCTestCase {
    private func events(_ model: String, webSearch: Bool = false) async throws -> [NativeChatEvent] {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StreamFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var events: [NativeChatEvent] = []
        for try await event in NativeChatTransport(session: session).stream(provider: .openRouter,
            modelID: model, messages: [.init(role: .user, text: "Fixture")], key: "fixture-key", webSearch: webSearch) { events.append(event) }
        return events
    }
    func testRealTransportKeepsSeparateEventsDeliveredInOneChunkAndReportsUsage() async throws {
        let received = try await events("fixture/combined")
        XCTAssertEqual(received.map(\.text).joined(), "Bonjour été")
        XCTAssertEqual(received.compactMap(\.usage).last?.inputTokens, 2)
        XCTAssertEqual(received.compactMap(\.usage).last?.outputTokens, 3)
        XCTAssertTrue(received.last?.isComplete == true)
    }
    func testFinalUsageEventAfterTextFinishCarriesProviderTotalBeforeDone() async throws {
        let received = try await events("fixture/web-cost", webSearch: true)
        let charge = try XCTUnwrap(received.compactMap(\.webSearchUsage).last)
        XCTAssertEqual(charge.providerTotalCostUSD, 0.017)
        XCTAssertEqual(charge.requests, 2); XCTAssertNil(charge.additionalCostUSD)
        XCTAssertEqual(received.compactMap(\.usage).last?.inputTokens, 2)
        XCTAssertTrue(received.last?.isComplete == true)
    }
    func testRealTransportFramesByteFragmentedUTF8CRLFMultilineAndHeartbeats() async throws {
        let received = try await events("fixture/fragmented")
        XCTAssertEqual(received.map(\.text).joined(), "Bonjour été")
        XCTAssertTrue(received.last?.isComplete == true)
    }
    func testTruncatedTerminalEventNeverReportsACompletedResponse() async throws {
        do { _ = try await events("fixture/truncated"); XCTFail("A truncated event was accepted") }
        catch ChatServiceError.incompleteResponse {}
    }
    func testFramerSupportsAllLineEndingsAndPreservesOnlyDataFields() throws {
        var framer = ServerSentEventFramer(); var events: [String] = []
        for byte in ": ignored\rid: 7\rdata:first\rdata: second\r\revent: ignored\ndata: third\n\n".utf8 {
            if let event = try framer.append(byte) { events.append(event) }
        }
        XCTAssertEqual(events, ["first\nsecond", "third"])
    }
    func testFramerBoundsLinesAndAccumulatedMultilineDataAndRejectsMalformedUTF8() throws {
        var line = ServerSentEventFramer(maximumBytes: 8)
        XCTAssertThrowsError(try Array("xxxxxxxxx".utf8).forEach { _ = try line.append($0) })
        var event = ServerSentEventFramer(maximumBytes: 12)
        XCTAssertThrowsError(try Array("data: 12345\ndata: 67890\ndata: x\n".utf8).forEach { _ = try event.append($0) })
        var invalid = ServerSentEventFramer()
        _ = try invalid.append(0xFF)
        XCTAssertThrowsError(try invalid.append(10))
    }
}
