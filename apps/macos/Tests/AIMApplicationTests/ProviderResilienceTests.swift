@testable import AIMApplication
import AIMCore
import XCTest

/// Scripted OpenRouter-compatible endpoint: each request pops the next reply
/// and records the request body for inspection.
private final class ScriptedProvider: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: [String: Any]
    }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [[String: Any]] = []
    static let lock = NSLock()

    static func reset(_ scripted: [Reply]) {
        lock.withLock { replies = scripted; requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let reply: Reply? = Self.lock.withLock {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.requests.append(body) }
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply, let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: nil, headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a }),
              let body = try? JSONSerialization.data(withJSONObject: reply.body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProviderResilienceTests: XCTestCase {
    private static func answer(_ text: String, reason: String = "stop") -> ScriptedProvider.Reply {
        ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": reason, "message": ["role": "assistant", "content": text]]]])
    }

    private static func call(_ id: String) -> ScriptedProvider.Reply {
        ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                "tool_calls": [["id": id, "type": "function",
                                "function": ["name": "read_file", "arguments": "{\"path\":\"a.txt\"}"]]]]]]])
    }

    /// Message text whether sent as a string or as cache-marked text blocks.
    private static func text(_ message: [String: Any]?) -> String? {
        if let text = message?["content"] as? String { return text }
        return (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }

    private func conversation(modelID: String = "anthropic/claude-sonnet-5.5") throws -> ProviderToolConversation {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProvider.self]
        return try ProviderToolConversation(provider: .openRouter, modelID: modelID,
            messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Read a.txt", sequence: 0)],
            apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])],
            session: URLSession(configuration: config), modelSupportsImages: true,
            retryPolicy: ProviderRetryPolicy(maximumRetries: 3, delayScale: 0))
    }

    func testRateLimitAndUpstreamFailuresAreRetriedOnTheirOwn() async throws {
        // No answer and no tool call came back, so asking again repeats no effect.
        ScriptedProvider.reset([
            .init(status: 429, headers: ["Retry-After": "0"], body: ["error": ["message": "rate limited"]]),
            .init(status: 200, headers: [:], body: ["error": ["code": 502, "message": "upstream error"]]),
            Self.answer("Answer after the provider recovered.")
        ])
        let turn = try await conversation().next(outputs: [])
        XCTAssertEqual(turn.text, "Answer after the provider recovered.")
        XCTAssertEqual(ScriptedProvider.requests.count, 3)
    }

    func testClaudeRequestsCacheInstructionsAndLatestMessage() async throws {
        ScriptedProvider.reset([Self.call("c1"), Self.answer("Done.")])
        let conversation = try conversation()
        let first = try await conversation.next(outputs: [])
        _ = try await conversation.next(outputs: [ModelToolOutput(id: first.calls[0].id, content: "hello", isError: false)])
        let messages = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(system.last?["cache_control"] as? [String: String], ["type": "ephemeral"])
        let tail = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(tail.last?["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertTrue(Self.text(messages.last)?.contains("hello") == true)
        let marks = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.filter { $0["cache_control"] != nil }
        XCTAssertEqual(marks.count, 2, "Anthropic allows at most four breakpoints; AIM uses two")

        ScriptedProvider.reset([Self.answer("Done.")])
        _ = try await self.conversation(modelID: "openai/gpt-5.5").next(outputs: [])
        let plain = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        XCTAssertTrue(plain.allSatisfy { $0["content"] is String }, "No cache markers for other model families")
    }

    func testStableHistoryEndGetsItsOwnBreakpoint() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProvider.self]
        let id = UUID()
        let conversation = try ProviderToolConversation(provider: .openRouter, modelID: "anthropic/claude-sonnet-5.5",
            messages: [ConversationMessage(conversationID: id, role: .user, content: "First", sequence: 0),
                       ConversationMessage(conversationID: id, role: .assistant, content: "Earlier answer", sequence: 1),
                       ConversationMessage(conversationID: id, role: .user, content: "Turn context", sequence: -3),
                       ConversationMessage(conversationID: id, role: .user, content: "Second", sequence: 2)],
            apiKey: "k", tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])],
            session: URLSession(configuration: config))
        ScriptedProvider.reset([Self.answer("Done.")])
        _ = try await conversation.next(outputs: [])
        let messages = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        let marked = messages.enumerated().filter { ($0.element["content"] as? [[String: Any]])?.contains { $0["cache_control"] != nil } == true }.map(\.offset)
        XCTAssertEqual(marked, [0, 2, 4], "system, end of stable history (the earlier answer), latest message")
        XCTAssertEqual(Self.text(messages[2]), "Earlier answer")
    }

    func testPromptCacheMarkingRules() {
        XCTAssertTrue(ProviderPromptCache.applies(provider: .anthropic, modelID: "claude-sonnet-5-5"))
        XCTAssertTrue(ProviderPromptCache.applies(provider: .openRouter, modelID: "~anthropic/claude-sonnet-latest"))
        XCTAssertFalse(ProviderPromptCache.applies(provider: .openRouter, modelID: "google/gemini-3-pro"))
        XCTAssertFalse(ProviderPromptCache.applies(provider: .openAI, modelID: "gpt-5.5"))
        // Anthropic blocks: the last non-empty cacheable block is marked, thinking blocks never.
        let history: [[String: Any]] = [["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t", "content": "ok"],
            ["type": "text", "text": ""]]]]
        let marked = ProviderPromptCache.markingLastMessage(history)
        let blocks = marked[0]["content"] as? [[String: Any]]
        XCTAssertNotNil(blocks?[0]["cache_control"])
        XCTAssertNil(blocks?[1]["cache_control"])
        let assistant: [[String: Any]] = [["role": "assistant", "content": NSNull(), "tool_calls": []]]
        XCTAssertTrue(ProviderPromptCache.markingLastMessage(assistant)[0]["content"] is NSNull)
        XCTAssertEqual((ProviderPromptCache.anthropicSystem("rules").first?["text"] as? String), "rules")
    }

    func testRejectedParameterIsDroppedOnceAndUnavailableModelFallsBack() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProvider.self]
        func make(fallback: String?) throws -> ProviderToolConversation {
            try ProviderToolConversation(provider: .openRouter, modelID: "vendor/primary",
                messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Hi", sequence: 0)],
                apiKey: "fixture-key", tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])],
                session: URLSession(configuration: config), openAIReasoningEffort: .high,
                retryPolicy: ProviderRetryPolicy(maximumRetries: 1, delayScale: 0), fallbackModelID: fallback)
        }
        ScriptedProvider.reset([
            .init(status: 400, headers: [:], body: ["error": ["message": "Parameter 'reasoning' is not supported by this model"]]),
            Self.answer("Done.")
        ])
        let first = try make(fallback: nil)
        let answered = try await first.next(outputs: [])
        XCTAssertEqual(answered.text, "Done.")
        XCTAssertNotNil(ScriptedProvider.requests.first?["reasoning"])
        XCTAssertNil(ScriptedProvider.requests.last?["reasoning"], "the rejected field is dropped for the retry")

        ScriptedProvider.reset([
            .init(status: 404, headers: [:], body: ["error": ["message": "No model found: vendor/primary"]]),
            Self.answer("From backup.")
        ])
        let second = try make(fallback: "vendor/backup")
        let recovered = try await second.next(outputs: [])
        XCTAssertEqual(recovered.text, "From backup.")
        XCTAssertEqual(ScriptedProvider.requests.map { $0["model"] as? String }, ["vendor/primary", "vendor/backup"])
        let active = await second.activeModelID
        XCTAssertEqual(active, "vendor/backup")

        ScriptedProvider.reset([.init(status: 404, headers: [:], body: ["error": ["message": "No model found"]])])
        do { _ = try await make(fallback: nil).next(outputs: []); XCTFail("no backup configured") } catch {}
    }

    func testFailureClassification() {
        let unsupported = ProviderRequestFailure(status: 400, retryAfter: nil, bodyPrefix: "Unrecognized request argument supplied: tool_choice", transport: nil)
        XCTAssertEqual(unsupported.rejectedParameters(among: ["tool_choice", "reasoning"]), ["tool_choice"])
        let endpoints = ProviderRequestFailure(status: 404, retryAfter: nil, bodyPrefix: "No endpoints found that support the requested parameters", transport: nil)
        XCTAssertEqual(endpoints.rejectedParameters(among: ["provider", "reasoning", "usage"]), ["provider", "reasoning"])
        XCTAssertFalse(endpoints.isModelUnavailable)
        XCTAssertTrue(ProviderRequestFailure(status: 400, retryAfter: nil, bodyPrefix: "The model `x` does not exist", transport: nil).isModelUnavailable)
        XCTAssertFalse(ProviderRequestFailure(status: 400, retryAfter: nil, bodyPrefix: "messages: field required", transport: nil).isModelUnavailable)
        XCTAssertTrue(ProviderRequestFailure(status: 400, retryAfter: nil, bodyPrefix: "Invalid value for temperature", transport: nil)
            .rejectedParameters(among: ["reasoning"]).isEmpty)
    }

    func testAuthenticationFailureIsNotRetried() async throws {
        ScriptedProvider.reset([.init(status: 401, headers: [:], body: ["error": ["message": "bad key"]]), Self.answer("x")])
        do {
            _ = try await conversation().next(outputs: [])
            XCTFail("A rejected key must surface")
        } catch ChatServiceError.http(401) {}
        XCTAssertEqual(ScriptedProvider.requests.count, 1)
    }

    func testRetryBudgetIsBounded() async throws {
        let refusal = ScriptedProvider.Reply(status: 429, headers: ["Retry-After": "0"], body: ["error": ["message": "busy"]])
        ScriptedProvider.reset(Array(repeating: refusal, count: 6))
        do {
            _ = try await conversation().next(outputs: [])
            XCTFail("Retries must stop")
        } catch ChatServiceError.http(429) {}
        XCTAssertEqual(ScriptedProvider.requests.count, 4, "One attempt plus three bounded retries")
    }

    func testTruncatedAnswerIsContinuedAndJoined() async throws {
        ScriptedProvider.reset([Self.answer("First half, ", reason: "length"), Self.answer("second half.")])
        let turn = try await conversation().next(outputs: [])
        XCTAssertEqual(turn.text, "First half, second half.")
        let messages = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(Self.text(messages.last), ProviderToolConversation.continuationPrompt)
        XCTAssertEqual(messages[messages.count - 2]["content"] as? String, "First half, ")
    }

    func testCutOffToolCallAsksForSmallerPiecesInsteadOfStopping() async throws {
        let cut = ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": "length", "message": ["role": "assistant", "content": NSNull(),
                "tool_calls": [["id": "big", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"a"]]]]]]])
        ScriptedProvider.reset([cut, Self.call("small")])
        let turn = try await conversation().next(outputs: [])
        XCTAssertEqual(turn.calls.map(\.id), ["small"], "the cut-off call never runs")
        let messages = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(Self.text(messages.last), ProviderToolConversation.cutOffCallPrompt)
    }

    func testUnexpectedArgumentsReachTheDispatcherInsteadOfEndingTheRun() async throws {
        ScriptedProvider.reset([ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                "tool_calls": [["id": "c1", "type": "function",
                                "function": ["name": "read_file", "arguments": "{\"path\":\"a.txt\",\"max_length\":500}"]]]]]]])])
        let turn = try await conversation().next(outputs: [])
        XCTAssertEqual(turn.calls.first?.name, "read_file")
        XCTAssertEqual(turn.calls.first?.arguments["max_length"], "500")
    }

    func testTextPartsAndUpstreamErrorsAreHandled() async throws {
        let parts = ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": "stop", "message": ["role": "assistant", "content": [["type": "text", "text": "Done "], ["type": "text", "text": "here."]]]]]])
        let upstream = ScriptedProvider.Reply(status: 200, headers: [:], body: ["choices": [[
            "finish_reason": "error", "error": ["code": 502, "message": "upstream"], "message": ["role": "assistant", "content": ""]]]])
        // An upstream error mid-answer is asked again (nothing was executed), then the answer arrives.
        ScriptedProvider.reset([upstream, parts])
        let conversation = try conversation()
        let turn = try await conversation.next(outputs: [])
        XCTAssertEqual(turn.text, "Done here.")
        XCTAssertEqual(ScriptedProvider.requests.count, 2)
        let cause = await conversation.lastInvalidCause
        XCTAssertEqual(cause, "upstream error 502")
        // Three invalid answers in a row end the turn without running anything.
        ScriptedProvider.reset([upstream, upstream, upstream])
        do {
            _ = try await self.conversation().next(outputs: [])
            XCTFail("Repeated invalid responses fail closed")
        } catch ModelToolError.invalidProtocol {}
        XCTAssertEqual(ScriptedProvider.requests.count, 3)
    }

    func testEmptyReplyIsAskedOnceThenFailsClosed() async throws {
        ScriptedProvider.reset([Self.answer(""), Self.answer("Final answer.")])
        let turn = try await conversation().next(outputs: [])
        XCTAssertEqual(turn.text, "Final answer.")
        let messages = try XCTUnwrap(ScriptedProvider.requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(Self.text(messages.last), ProviderToolConversation.emptyReplyPrompt)
        XCTAssertFalse(messages.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String) == "" })

        ScriptedProvider.reset([Self.answer(""), Self.answer("  ")])
        do {
            _ = try await conversation().next(outputs: [])
            XCTFail("Two empty replies end the turn")
        } catch ModelToolError.invalidProtocol {}
    }

    func testOldScreenshotsAreRemovedInBatchesSoThePromptCacheHolds() async throws {
        // Round 37: removing one old screenshot per step changed an earlier message every step and
        // voided the prompt cache; they now accumulate to four and drop back to two at once.
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 1, count: 64)
        var script: [ScriptedProvider.Reply] = (0..<6).map { Self.call("c\($0)") }
        script.append(Self.answer("Done."))
        ScriptedProvider.reset(script)
        let service = try conversation()
        var turn = try await service.next(outputs: [])
        for _ in 0..<6 {
            turn = try await service.next(outputs: [ModelToolOutput(id: turn.calls[0].id, content: "seen", isError: false, imagePNG: png)])
        }
        func images(_ body: [String: Any]) -> Int {
            (body["messages"] as? [[String: Any]] ?? []).reduce(0) { total, message in
                total + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0)
            }
        }
        XCTAssertEqual(ScriptedProvider.requests.dropFirst().map(images), [1, 2, 3, 4, 2, 3])
    }

    func testContextOverflowShrinksOldScreenshotsAndResultsOnce() async throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 1, count: 64)
        var script: [ScriptedProvider.Reply] = (0..<5).map { Self.call("c\($0)") }
        script.append(.init(status: 400, headers: [:], body: ["error": ["message": "This model's maximum context length is 200000 tokens"]]))
        script.append(Self.answer("Recovered."))
        ScriptedProvider.reset(script)
        let service = try conversation()
        var turn = try await service.next(outputs: [])
        for index in 0..<5 {
            let output = ModelToolOutput(id: turn.calls[0].id, content: String(repeating: "x", count: 5_000),
                isError: false, imagePNG: png)
            turn = try await service.next(outputs: [output])
            _ = index
        }
        XCTAssertEqual(turn.text, "Recovered.")
        func images(_ body: [String: Any]) -> Int {
            (body["messages"] as? [[String: Any]] ?? []).reduce(0) { total, message in
                total + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0)
            }
        }
        let beforeOverflow = ScriptedProvider.requests[ScriptedProvider.requests.count - 2]
        let afterOverflow = ScriptedProvider.requests[ScriptedProvider.requests.count - 1]
        XCTAssertEqual(images(beforeOverflow), ProviderTranscriptBudget.retainedToolImages,
            "Only the latest screenshots are resent")
        XCTAssertEqual(images(afterOverflow), 1, "After an overflow only the newest screenshot remains")
        let toolContents = (afterOverflow["messages"] as? [[String: Any]] ?? [])
            .filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
        XCTAssertTrue(toolContents.first?.contains("Earlier tool output shortened") == true)
        XCTAssertFalse(toolContents.last?.contains("Earlier tool output shortened") == true)
    }

    func testRetryAfterParsingAndBackoffBounds() {
        XCTAssertEqual(ProviderRequestFailure.retryAfter("7"), 7)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(ProviderRequestFailure.retryAfter(formatter.string(from: now.addingTimeInterval(30)), now: now) ?? 0,
            30, accuracy: 1)
        let refusal = ProviderRequestFailure(status: 503, retryAfter: nil, bodyPrefix: "", transport: nil)
        XCTAssertEqual(refusal.delay(attempt: 0, jitter: 1), 2)
        XCTAssertEqual(refusal.delay(attempt: 2, jitter: 1), 8)
        XCTAssertEqual(refusal.delay(attempt: 9, jitter: 1), 60)
        XCTAssertEqual(ProviderRequestFailure(status: 429, retryAfter: 600, bodyPrefix: "", transport: nil).delay(attempt: 0), 600)
        // Overload, temporary server failures and dropped connections are retried; the agent keeps going.
        for status in [408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529] {
            XCTAssertTrue(ProviderRequestFailure(status: status, retryAfter: 0, bodyPrefix: "", transport: nil).isRetryable, "\(status)")
        }
        XCTAssertFalse(ProviderRequestFailure(status: 409, retryAfter: 0, bodyPrefix: "", transport: nil).isRetryable)
        XCTAssertFalse(ProviderRequestFailure(status: 402, retryAfter: nil, bodyPrefix: "", transport: nil).isRetryable)
        XCTAssertFalse(ProviderRequestFailure(status: 429, retryAfter: nil, bodyPrefix: "insufficient credits", transport: nil).isRetryable)
        XCTAssertTrue(ProviderRequestFailure(status: nil, retryAfter: nil, bodyPrefix: "", transport: .networkConnectionLost).isRetryable)
        XCTAssertTrue(ProviderRequestFailure(status: nil, retryAfter: nil, bodyPrefix: "", transport: .timedOut).isRetryable)
        XCTAssertTrue(ProviderRequestFailure(status: 400, retryAfter: nil,
            bodyPrefix: "prompt is too long: 210000 tokens > 200000 maximum", transport: nil).isContextOverflow)
    }
}

extension ProviderResilienceTests {
    private func routedConversation() throws -> RoutedToolConversation {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProvider.self]
        let session = URLSession(configuration: config)
        let messages = [ConversationMessage(conversationID: UUID(), role: .user, content: "Exact prompt", sequence: 0)]
        let routes: [AIMCore.NativeChatRoute] = [
            .init(provider: .anthropic, model: .init(id: "claude-sonnet-4-6", name: "Sonnet"), key: "fixture"),
            .init(provider: .openRouter, model: .init(id: "anthropic/claude-sonnet-4.6", name: "Sonnet"), key: "fixture")]
        return try RoutedToolConversation(routes: routes) { route in
            try ProviderToolConversation(provider: route.provider, modelID: route.model.id,
                messages: messages, apiKey: route.key, tools: [], session: session, anthropicOutputTokens: 128,
                retryPolicy: ProviderRetryPolicy(maximumRetries: 0))
        }
    }
    func testRound24ToolRouteFallbackUsesExactAliasAndPreservesCheckpointRoute() async throws {
        ScriptedProvider.reset([
            .init(status: 429, headers: [:], body: ["error": ["message": "rate limited"]]),
            Self.answer("Final answer")])
        let conversation = try routedConversation()
        let answer = try await conversation.next(outputs: [])
        XCTAssertEqual(answer.text, "Final answer")
        XCTAssertEqual(ScriptedProvider.requests.compactMap { $0["model"] as? String }, ["claude-sonnet-4-6", "anthropic/claude-sonnet-4.6"])
        let checkpoint = try await conversation.exportCheckpoint()
        XCTAssertEqual(checkpoint.provider, .openRouter)
        XCTAssertEqual(checkpoint.modelID, "anthropic/claude-sonnet-4.6")
    }
    func testRound24ToolRouteNeverFallsBackAfterHTTPAcceptanceOrSecurityDenial() async throws {
        for reply in [ScriptedProvider.Reply(status: 200, headers: [:], body: ["error": ["code": 429, "message": "upstream ambiguous"]]), .init(status: 403, headers: [:], body: ["error": ["message": "denied"]])] {
            ScriptedProvider.reset([reply, Self.answer("Must never run")])
            do { _ = try await routedConversation().next(outputs: []); XCTFail("Expected refusal") } catch { }
            XCTAssertEqual(ScriptedProvider.requests.count, 1)
        }
    }
}
