import XCTest
import AIMCore
@testable import AIMApplication

private final class LongCompactionFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: bytes, as: UTF8.self)
            let expression = try NSRegularExpression(pattern: "round:([0-9]+)")
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            let previous = expression.matches(in: body, range: range).last.flatMap { Range($0.range(at: 1), in: body) }.flatMap { Int(body[$0]) } ?? 0
            let round = previous + 1
            let root = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let value: [String: Any]
            if request.url?.host == "generativelanguage.googleapis.com" {
                value = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["functionCall": ["id": "call_\(round)", "name": "fixture_read", "args": [:]]]]]]]]
            } else if request.url?.host == "api.anthropic.com" {
                value = ["type": "message", "role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": "call_\(round)", "name": "fixture_read", "input": [:]]]]
            } else if request.url?.host == "api.openai.com" {
                value = ["id": "response_\(round)", "object": "response", "status": "completed", "output": [["type": "function_call", "id": "item_\(round)", "call_id": "call_\(round)", "name": "fixture_read", "arguments": "{}"]]]
            } else if root["tools"] == nil {
                value = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "{\"type\":\"tool_call\",\"name\":\"fixture_read\",\"arguments\":{}}"]]]]
            } else {
                value = ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_\(round)", "type": "function", "function": ["name": "fixture_read", "arguments": "{}"]]]]]]]
            }
            let response = try JSONSerialization.data(withJSONObject: value)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor LongCompactionArchive {
    var archives: [Data] = []
    func save(_ data: Data) { archives.append(data) }
}
private actor InterruptedCompactionSummary {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var interruptNext = true
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func summarize() async throws -> String {
        if interruptNext {
            interruptNext = false; entered = true
            observers.forEach { $0.resume() }; observers.removeAll()
            // The test cancels the caller here, before a summary can replace history.
            try await Task.sleep(for: .seconds(30))
        }
        return "{\"objective\":\"Investigate\",\"decisions\":[],\"completed\":[],\"pending\":[],\"references\":[\"original-evidence\"],\"errors\":[],\"next_step\":\"Continue\"}"
    }
}
final class LongProviderCompactionTests: XCTestCase {
    private var originalArguments: [String: Any] = [:]
    override func setUp() {
        let defaults = AIMInstallationContext.sharedPreferences
        originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments[RuntimePrivacyPolicy.defaultsKey] = false
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    override func tearDown() {
        AIMInstallationContext.sharedPreferences.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongCompactionFixture.self]
        return URLSession(configuration: configuration)
    }
    func testCancellationDuringSummaryRestoresLastCheckpointAcrossFiveProtocols() async throws {
        for (provider, textProtocol) in [(ChatProvider.openRouter, false), (.anthropic, false),
                                         (.google, false), (.openAI, false), (.openRouter, true)] {
            let summaries = InterruptedCompactionSummary()
            let archives = LongCompactionArchive()
            let compaction = ActiveRunCompaction(contextLength: 4096,
                summarize: { _ in try await summaries.summarize() },
                archive: { await archives.save($0) })
            let messages = [ConversationMessage(conversationID: UUID(), role: .user,
                content: "original-evidence: ABC123", sequence: 0)]
            let tool = ModelToolDefinition(name: "fixture_read", description: "Read fixture data")
            func make() throws -> any DurableModelConversation {
                if textProtocol {
                    return try TextProtocolToolConversation(modelID: "fake", messages: messages,
                        apiKey: "fixture", tools: [tool], session: session(), activeCompaction: compaction)
                }
                return try ProviderToolConversation(provider: provider, modelID: "fake", messages: messages,
                    apiKey: "fixture", tools: [tool], session: session(), anthropicOutputTokens: provider == .anthropic ? 512 : nil, activeCompaction: compaction)
            }
            let conversation = try make()
            var outputs: [ModelToolOutput] = []
            // Compaction requires three completed groups. These fit below its threshold.
            for round in 1...3 {
                let turn = try await conversation.next(outputs: outputs)
                let call = try XCTUnwrap(turn.calls.first)
                outputs = [ModelToolOutput(id: call.id,
                    content: "round:\(round) " + String(repeating: "e", count: 100), isError: false)]
            }
            let checkpoint = try await conversation.exportCheckpoint()
            let last = try XCTUnwrap(outputs.first)
            let marker = "round:3 recovery-output-unique"
            outputs = [ModelToolOutput(id: last.id, content: marker + String(repeating: "e", count: 6000), isError: false)]
            let settledOutputs = outputs
            let interrupted = Task { try await conversation.next(outputs: settledOutputs) }
            await summaries.waitUntilEntered()
            interrupted.cancel()
            do {
                _ = try await interrupted.value
                XCTFail("Cancelled summary continued: \(provider), text=\(textProtocol)")
            } catch { XCTAssertTrue(error is CancellationError) }
            let afterFailure = try await conversation.exportCheckpoint()
            XCTAssertEqual(afterFailure.transcript, checkpoint.transcript)
            XCTAssertEqual(afterFailure.pendingIDs, checkpoint.pendingIDs)
            let replacement = try make()
            try await replacement.restoreCheckpoint(checkpoint)
            let next = try await replacement.next(outputs: settledOutputs)
            XCTAssertEqual(next.calls.count, 1)
            let resumed = try await replacement.exportCheckpoint()
            let text = String(decoding: resumed.transcript, as: UTF8.self)
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1,
                           "A saved tool result must be delivered exactly once after restore")
            let saved = await archives.archives
            XCTAssertTrue(saved.contains { String(decoding: $0, as: UTF8.self).contains("ABC123") })
        }
    }
    func testTwoHundredStepsEachAcrossNativeProvidersAndTextProtocolWithRestore() async throws {
        for provider in [ChatProvider.openRouter, .anthropic, .google, .openAI, .openRouter] {
            let textProtocol = provider == .openRouter && lastWasOpenRouter
            if provider == .openRouter { lastWasOpenRouter = true }
            let archives = LongCompactionArchive()
            let compaction = ActiveRunCompaction(contextLength: 4096, summarize: { _ in
                "{\"objective\":\"Investigate\",\"decisions\":[],\"completed\":[],\"pending\":[],\"references\":[\"original-evidence\"],\"errors\":[],\"next_step\":\"Continue investigation\"}"
            }, archive: { await archives.save($0) })
            let tool = ModelToolDefinition(name: "fixture_read", description: "Read fixture data")
            let messages = [ConversationMessage(conversationID: UUID(), role: .user, content: "original-evidence: ABC123", sequence: 0)]
            func make() throws -> any DurableModelConversation {
                if textProtocol { return try TextProtocolToolConversation(modelID: "fake", messages: messages, apiKey: "fixture", tools: [tool], session: session(), activeCompaction: compaction) }
                return try ProviderToolConversation(provider: provider, modelID: "fake", messages: messages, apiKey: "fixture", tools: [tool], session: session(), anthropicOutputTokens: provider == .anthropic ? 512 : nil, activeCompaction: compaction)
            }
            var conversation = try make()
            var outputs: [ModelToolOutput] = []
            for round in 1...200 {
                let turn: ModelToolTurn
                do { turn = try await conversation.next(outputs: outputs) }
                catch {
                    let cause = await (conversation as? ProviderToolConversation)?.lastInvalidCause
                    XCTFail("\(provider) text=\(textProtocol) round=\(round): \(error) cause=\(cause ?? "none")")
                    throw error
                }
                XCTAssertEqual(turn.calls.count, 1, "\(provider) round \(round)")
                let call = try XCTUnwrap(turn.calls.first)
                outputs = [ModelToolOutput(id: call.id, content: "round:\(round) " + String(repeating: "fixture evidence ", count: 60), isError: false)]
                if round == 100 {
                    let saved = try await conversation.exportCheckpoint()
                    conversation = try make(); try await conversation.restoreCheckpoint(saved)
                }
            }
            let saved = await archives.archives
            XCTAssertGreaterThan(saved.count, 10, "\(provider) did not compact repeatedly")
            XCTAssertTrue(saved.contains { String(decoding: $0, as: UTF8.self).contains("ABC123") }, "Original information must remain retrievable")
        }
    }
    private var lastWasOpenRouter = false
}
