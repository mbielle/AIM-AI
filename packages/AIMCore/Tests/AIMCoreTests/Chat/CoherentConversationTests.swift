import Foundation
import XCTest
@testable import AIMCore

final class CoherentConversationTests: XCTestCase {
    func testLegacySourcesOnlyProjectAnUnambiguousTerminalBibliography() throws {
        let original = "Answer [1]\n\nSources\n[1] [Example](https://example.com/page)"
        let value = ConversationSourceProjection(text: original)
        XCTAssertEqual(value.text, "Answer [1]")
        XCTAssertEqual(value.sources.first?.domain, "example.com")
        XCTAssertTrue(value.linkedText.contains("aim-source://1"))
        for ambiguous in [original + "\nKeep this paragraph.", "Sources\nAn ordinary explanation", "[Example](https://example.com)"] {
            XCTAssertEqual(ConversationSourceProjection(text: ambiguous).text, ambiguous)
        }
        let source = try XCTUnwrap(ConversationSource(url: "https://example.com", references: [1]))
        let code = "[1](https://other.com) `[1]`\n```\n[1]\n```\n[1]"
        let linked = ConversationSourceProjection(text: code, sources: [source]).linkedText
        XCTAssertTrue(linked.contains("[1](https://other.com) `[1]`"))
        XCTAssertEqual(linked.components(separatedBy: "aim-source://1").count, 2)
        XCTAssertNil(ConversationSource(url: "https://user:secret@example.com"))
        XCTAssertNil(ConversationSource(url: "javascript:alert(1)"))
    }
    func testAttentionCountsDistinctConversationsAndConsultDoesNotResolveApproval() throws {
        let a = UUID(), b = UUID()
        var ledger = ConversationAttention()
        ledger.record(.init(conversation: a, version: "a1", kind: .response))
        ledger.record(.init(conversation: a, version: "a2", kind: .approval))
        ledger.record(.init(conversation: b, version: "b1", kind: .failure))
        XCTAssertEqual(ledger.count, 2); XCTAssertEqual(ledger.priority, .failure)
        ledger.consult(b); ledger.consult(a)
        XCTAssertEqual(ledger.count, 1); XCTAssertEqual(ledger.priority, .approval)
        ledger.record(.init(conversation: b, version: "b1", kind: .failure))
        XCTAssertEqual(ledger.count, 1)
        ledger.resolveApproval(a); XCTAssertEqual(ledger.count, 0)
        ledger = try JSONDecoder().decode(ConversationAttention.self, from: JSONEncoder().encode(ledger))
        ledger.record(.init(conversation: a, version: "a2", kind: .approval)); XCTAssertEqual(ledger.count, 0)
    }
    func testExactAliasesVariantsAndRoutePreferenceScope() {
        XCTAssertEqual(CanonicalModelRouting.identity("black-forest-labs/flux.2-flex", provider: "openrouter"), CanonicalModelRouting.identity("black-forest-labs/flux-2-flex", provider: "openrouter"))
        XCTAssertEqual(CanonicalModelRouting.publisher("Black-Forest-Labs"), "Black Forest Labs")
        XCTAssertNotEqual(CanonicalModelRouting.identity("model-20261008", provider: "openai"), CanonicalModelRouting.identity("model", provider: "openai"))
        XCTAssertNotEqual(CanonicalModelRouting.identity("vendor/model:free", provider: "openrouter"), CanonicalModelRouting.identity("vendor/model", provider: "openrouter"))
        XCTAssertEqual(CanonicalModelRouting.identity("grok-4", provider: "xai"), CanonicalModelRouting.identity("x-ai/grok-4", provider: "openrouter"))
        XCTAssertEqual(CanonicalModelRouting.identity("mistral-large", provider: "mistral"), CanonicalModelRouting.identity("mistralai/mistral-large", provider: "openrouter"))
        let account = UUID()
        XCTAssertNotEqual(CanonicalModelRouting.preferenceKey(account: account, target: "phone", model: "model"), CanonicalModelRouting.preferenceKey(account: account, target: "mac", model: "model"))
        XCTAssertLessThan(CanonicalModelRouting.rank("chatgpt"), CanonicalModelRouting.rank("openai"))
        XCTAssertLessThan(CanonicalModelRouting.rank("openai"), CanonicalModelRouting.rank("openrouter"))
    }
    func testSourcesAndActionDetailsSurviveRepeatedAccountMerge() throws {
        let conversation = UUID(), turn = UUID(), started = Date(timeIntervalSince1970: 100)
        let source = try XCTUnwrap(ConversationSource(url: "https://example.com", references: [1]))
        let old = NativeChatMessage(id: turn, role: .assistant, text: "Answer [1]", createdAt: started)
        var updated = old
        updated.sources = [source]
        updated.actions = [.init(id: "web:1", conversationID: conversation, turnID: turn, ordinal: 0, name: "web_search", state: .completed, startedAt: started, finishedAt: started.addingTimeInterval(2), input: "query", output: "result")]
        updated.routeAttempts = [.init(provider: .openAI, modelID: "model", ordinal: 0, state: .accepted)]
        let a = NativeChatConversation(id: conversation, title: "A", provider: .openAI, modelID: "model", messages: [old])
        let b = NativeChatConversation(id: conversation, title: "A", provider: .openAI, modelID: "model", messages: [updated])
        let merged = a.merging(b).merging(a)
        XCTAssertEqual(merged.messages.count, 1)
        XCTAssertEqual(merged.messages.first?.sources, [source])
        XCTAssertEqual(merged.messages.first?.actions?.first?.input, "query")
        XCTAssertEqual(merged.messages.first?.actions?.first?.output, "result")
        XCTAssertEqual(merged.messages.first?.routeAttempts?.first?.state, .accepted)
        XCTAssertEqual(try JSONDecoder().decode(NativeChatConversation.self, from: JSONEncoder().encode(merged)), merged)
        let timeline = ConversationAction.remoteTimeline(updated.actions, content: "Answer", sources: updated.sources)
        let segments = RemoteTimelineRules.displayTimeline(for: .init(id: turn.uuidString, role: .assistant, content: "Answer", timeline: timeline?.arrayValue))
        guard case .tool(_, let tool) = segments.first else { return XCTFail("Missing tool") }
        XCTAssertEqual(tool.input, "query"); XCTAssertEqual(tool.output, "result"); XCTAssertEqual(tool.duration, 2)

    }
    func testSplitSearchInputAndTerminalUpdateKeepOneInvocation() throws {
        var tracker = NativeWebSearchTracker()
        func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        _ = tracker.consume(try json(["type": "content_block_start", "index": 0, "content_block": ["type": "server_tool_use", "name": "web_search", "id": "search1", "input": [:]]]), provider: .anthropic)
        _ = tracker.consume(try json(["index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"query\":"]]), provider: .anthropic)
        let input = tracker.consume(try json(["index": 0, "delta": ["type": "input_json_delta", "partial_json": "\"example\"}"]]), provider: .anthropic)
        XCTAssertEqual(input.first?.input, "example")
        let finished = tracker.consume(try json(["content_block": ["type": "web_search_tool_result", "tool_use_id": "search1", "content": [["url": "https://example.com"]]]]), provider: .anthropic)
        XCTAssertEqual(finished.first?.id, "search1"); XCTAssertEqual(finished.first?.status, .completed)
        XCTAssertEqual(finished.first?.input, "example"); XCTAssertTrue(finished.first?.output?.contains("example.com") == true)
        XCTAssertTrue(CanonicalModelRouting.permitsFallback(ChatServiceError.planLimitReached, admitted: false, emittedOutput: false))
        XCTAssertFalse(CanonicalModelRouting.permitsFallback(ChatServiceError.planLimitReached, admitted: true, emittedOutput: false))
    }
    func testFallbackPolicyRejectsAllAmbiguousOrAcceptedResults() {
        for status in [401, 402, 404, 429] {
            XCTAssertTrue(CanonicalModelRouting.permitsFallback(ChatServiceError.http(status), admitted: false, emittedOutput: false))
            XCTAssertFalse(CanonicalModelRouting.permitsFallback(ChatServiceError.http(status), admitted: true, emittedOutput: false))
            XCTAssertFalse(CanonicalModelRouting.permitsFallback(ChatServiceError.http(status), admitted: false, emittedOutput: true))
        }
        for error in [ChatServiceError.http(403), ChatServiceError.http(500), ChatServiceError.http(529), URLError(.timedOut), CancellationError()] as [Error] {
            XCTAssertFalse(CanonicalModelRouting.permitsFallback(error, admitted: false, emittedOutput: false))
        }
    }
    func testRoutedStreamUsesEachEquivalentRouteOnceAndNeverRepeatsAfterAcceptance() async throws {
        let routes: [NativeChatRoute] = [.init(provider: .openAI, model: .init(id: "model", name: "Model"), key: "fixture"), .init(provider: .openRouter, model: .init(id: "openai/model", name: "Model"), key: "fixture")]
        let log = RouteLog()
        var events: [NativeChatEvent] = []
        for try await event in RoutedChatTransport.stream(routes: routes + routes) { route in
            AsyncThrowingStream { continuation in
                Task {
                    await log.add(route.provider)
                    if route.provider == .openAI { continuation.finish(throwing: ChatServiceError.http(429)) }
                    else { continuation.yield(.init(requestAccepted: true)); continuation.yield(.init(text: "answer", isComplete: true)); continuation.finish() }
                }
            }
        } { events.append(event) }
        let seen = await log.values
        XCTAssertEqual(seen, [.openAI, .openRouter]); XCTAssertEqual(events.last?.text, "answer")
        let admittedLog = RouteLog()
        do {
            for try await _ in RoutedChatTransport.stream(routes: routes) { route in
                AsyncThrowingStream { continuation in Task { await admittedLog.add(route.provider); continuation.yield(.init(requestAccepted: true)); continuation.finish(throwing: ChatServiceError.http(429)) } }
            } { }
            XCTFail("Expected uncertain result")
        } catch { }
        let admittedSeen = await admittedLog.values
        XCTAssertEqual(admittedSeen, [.openAI])
    }
}
private actor RouteLog {
    var values: [ChatProvider] = []
    func add(_ value: ChatProvider) { values.append(value) }
}
