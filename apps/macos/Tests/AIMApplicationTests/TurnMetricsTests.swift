import AIMApplication
import XCTest

final class TurnMetricsTests: XCTestCase {
    func testLlamaCppTimingsAndUsage() throws {
        let payload = #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":420,"completion_tokens":300,"prompt_tokens_details":{"cached_tokens":20}},"timings":{"prompt_n":400,"prompt_ms":800,"predicted_n":300,"predicted_ms":12000,"cache_n":20}}"#
        let usage = try XCTUnwrap(TokenUsageParser.parse(payload))
        XCTAssertEqual(usage.inputTokens, 420)
        XCTAssertEqual(usage.cachedInputTokens, 20)
        XCTAssertEqual(usage.outputTokens, 300)
        XCTAssertEqual(usage.processedPromptTokens, 400)
        XCTAssertEqual(usage.engine, "llama.cpp")
        let metrics = TurnMetrics(provider: "local", modelID: "qwen", mode: "chat", startedAt: .now, usage: usage, totalSeconds: 13)
        XCTAssertEqual(try XCTUnwrap(metrics.promptTokensPerSecond), 500, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.outputTokensPerSecond), 25, accuracy: 0.01)
    }

    func testMLXEngineTimingsNameTheEngine() throws {
        let payload = #"{"choices":[],"timings":{"engine":"mlx","prompt_n":51,"prompt_ms":68,"predicted_n":25,"predicted_ms":228}}"#
        XCTAssertEqual(TokenUsageParser.parse(payload)?.engine, "mlx")
    }

    func testOpenAIResponsesUsage() throws {
        let payload = #"{"type":"response.completed","response":{"usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":600},"output_tokens":200,"output_tokens_details":{"reasoning_tokens":150}}}}"#
        let usage = try XCTUnwrap(TokenUsageParser.parse(payload))
        XCTAssertEqual(usage, TokenUsage(inputTokens: 1000, cachedInputTokens: 600, outputTokens: 200, reasoningTokens: 150))
    }

    func testAnthropicUsageArrivesInTwoEventsAndCountsCacheReads() throws {
        var usage = TokenUsage()
        usage.merge(try XCTUnwrap(TokenUsageParser.parse(#"{"type":"message_start","message":{"usage":{"input_tokens":30,"cache_read_input_tokens":500,"output_tokens":1}}}"#)))
        usage.merge(try XCTUnwrap(TokenUsageParser.parse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":240}}"#)))
        XCTAssertEqual(usage.inputTokens, 530)
        XCTAssertEqual(usage.cachedInputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 240)
    }

    func testGeminiUsageMetadataIncludesThoughts() throws {
        let usage = try XCTUnwrap(TokenUsageParser.parse(#"{"candidates":[],"usageMetadata":{"promptTokenCount":80,"candidatesTokenCount":40,"thoughtsTokenCount":60}}"#))
        XCTAssertEqual(usage.inputTokens, 80)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.reasoningTokens, 60)
    }

    func testTextWithoutUsageIsIgnoredAndAgentStepsAddUp() {
        XCTAssertNil(TokenUsageParser.parse(#"{"choices":[{"delta":{"content":"usage of words"}}]}"#))
        var total = TokenUsage(inputTokens: 100, outputTokens: 10)
        total.add(TokenUsage(inputTokens: 150, outputTokens: 20))
        XCTAssertEqual(total, TokenUsage(inputTokens: 250, outputTokens: 30))
    }

    func testEstimatedOutputWithoutProviderCounts() {
        let metrics = TurnMetrics(provider: "openrouter", modelID: "m", mode: "chat", startedAt: .now,
                                  firstTokenSeconds: 0.5, streamSeconds: 2, totalSeconds: 2.5, characters: 400)
        XCTAssertTrue(metrics.outputIsEstimated)
        XCTAssertEqual(metrics.outputTokens, 100)
        XCTAssertEqual(try XCTUnwrap(metrics.outputTokensPerSecond), 50, accuracy: 0.01)
    }

    func testRepositoryStoresMetricsTitleSourceAndReadState() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Question", mode: .chat)
        try await conversations.save(conversation)
        let repository = SQLiteMessageMetricsRepository(database: database)
        let messageID = UUID()
        let metrics = TurnMetrics(provider: "local", modelID: "qwen", mode: "chat", startedAt: .now,
                                  usage: TokenUsage(inputTokens: 10, outputTokens: 5), totalSeconds: 1)
        try await repository.save(metrics, messageID: messageID, conversationID: conversation.id)
        let saved = try await repository.metrics(conversationID: conversation.id)
        XCTAssertEqual(saved[messageID], metrics)
        let all = try await repository.all()
        XCTAssertEqual(all.count, 1)
        try await repository.setTitleSource(.generated, conversationID: conversation.id)
        try await repository.markRead(conversationID: conversation.id)
        let source = try await repository.titleSource(conversationID: conversation.id)
        XCTAssertEqual(source, .generated)
        let read = try await repository.lastRead()
        XCTAssertNotNil(read[conversation.id])
        try await conversations.delete(id: conversation.id)
        let afterDelete = try await repository.all()
        XCTAssertTrue(afterDelete.isEmpty)
    }
}

final class TitleTagFilterTests: XCTestCase {
    private func run(_ chunks: [String]) -> (text: String, title: String?) {
        var filter = TitleTagFilter()
        var text = "", title: String?
        for chunk in chunks {
            let piece = filter.feed(chunk)
            text += piece.text
            title = title ?? piece.title
        }
        let rest = filter.finish()
        return (text + rest.text, title ?? rest.title)
    }

    func testTagSplitAcrossChunksIsRemoved() {
        let result = run(["<aim", "_title>Quantisation des ", "modèles</aim_ti", "tle>  \n", "La quantisation…"])
        XCTAssertEqual(result.title, "Quantisation des modèles")
        XCTAssertEqual(result.text, "La quantisation…")
    }

    func testAnswerWithoutTagIsUntouched() {
        let result = run(["Bonjour ", "<b>ok</b> et 3 < 4"])
        XCTAssertNil(result.title)
        XCTAssertEqual(result.text, "Bonjour <b>ok</b> et 3 < 4")
    }

    func testTagInTheMiddleIsRemovedToo() {
        let result = run(["Voici. ", "<aim_title>Titre</aim_title>", " Suite"])
        XCTAssertEqual(result.title, "Titre")
        XCTAssertEqual(result.text, "Voici.  Suite")
    }

    func testUnclosedLongTagGivesTextBack() {
        let long = String(repeating: "mot ", count: 100)
        let result = run(["<aim_title>" + long])
        XCTAssertNil(result.title)
        XCTAssertTrue(result.text.contains("mot mot"))
    }

    func testCleanRemovesQuotesAndPrefix() {
        XCTAssertEqual(ConversationTitleProtocol.clean("\"Title: Recette de crêpes.\""), "Recette de crêpes")
        XCTAssertNil(ConversationTitleProtocol.clean("   "))
    }
}
