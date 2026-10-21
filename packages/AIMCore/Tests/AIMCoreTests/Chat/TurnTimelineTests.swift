import XCTest
@testable import AIMCore

final class TurnTimelineTests: XCTestCase {
    private struct Tool: Sendable { let id: String; let name: String }

    func testBuilderPlacesActionsWhereTheyHappenedAndSplitsTheFinalAnswer() {
        let start = Date(timeIntervalSince1970: 0)
        var builder = TurnTimelineBuilder(startedAt: start)
        builder.reasoning("Need fresh ", at: start)
        builder.reasoning("sources.", at: start.addingTimeInterval(1))
        builder.text("Je vérifie… ", at: start.addingTimeInterval(2))
        builder.action("web:1", at: start.addingTimeInterval(3))
        builder.action("web:2", at: start.addingTimeInterval(4))
        builder.action("web:1", at: start.addingTimeInterval(5))
        builder.text("Réponse finale 🇫🇷.", at: start.addingTimeInterval(6))
        builder.finish(at: start.addingTimeInterval(72))
        let content = "Je vérifie… Réponse finale 🇫🇷."
        let layout = TurnLayout.make(content: content, timeline: builder.timeline,
            tools: [Tool(id: "web:1", name: "web_search"), Tool(id: "web:2", name: "web_search")], key: \.id)

        XCTAssertEqual(layout.work.map(\.id).count, 3)
        guard case let .reasoning(_, text, duration, running) = layout.work[0] else { return XCTFail("reasoning first") }
        XCTAssertEqual(text, "Need fresh sources."); XCTAssertEqual(duration, 2); XCTAssertFalse(running)
        guard case let .text(_, intermediate) = layout.work[1] else { return XCTFail("intermediate text") }
        XCTAssertEqual(intermediate, "Je vérifie… ")
        guard case let .tools(_, tools) = layout.work[2] else { return XCTFail("one group") }
        XCTAssertEqual(tools.map(\.id), ["web:1", "web:2"])
        guard case let .text(_, answer) = layout.answer.first else { return XCTFail("answer") }
        XCTAssertEqual(answer, "Réponse finale 🇫🇷.")
        XCTAssertEqual(layout.duration, 72)
        XCTAssertEqual(TurnLayoutText.header(onlyReasoning: layout.onlyReasoning, duration: layout.duration, running: false, locale: Locale(identifier: "en")), "Worked for 1 min 12 s")
    }

    func testOlderMessagesKeepActionsBeforeTheAnswerWithoutTimeline() {
        let layout = TurnLayout.make(content: "Answer", timeline: nil, tools: [Tool(id: "a", name: "read_file")], key: \.id)
        XCTAssertEqual(layout.work.count, 1)
        guard case let .text(_, text) = layout.answer.first else { return XCTFail() }
        XCTAssertEqual(text, "Answer")
    }

    func testUnreferencedActionsAndUntrackedTextAreNeverLost() {
        var builder = TurnTimelineBuilder()
        builder.text("Hello")
        builder.finish()
        let layout = TurnLayout.make(content: "Hello world", timeline: builder.timeline, tools: [Tool(id: "late", name: "view_image")], key: \.id)
        guard case let .tools(_, tools) = layout.work.first else { return XCTFail("unplaced tools kept") }
        XCTAssertEqual(tools.map(\.id), ["late"])
        guard case let .text(_, text) = layout.answer.first else { return XCTFail() }
        XCTAssertEqual(text, "Hello world")
    }

    func testAnswerSavedWithoutItsWorkingNotesIsShownWholeNotCutMidWord() {
        // Round 36: the timeline indexes the streamed text (notes + answer) but the message kept
        // only the delivered answer; the answer must never start in the middle of a word.
        var builder = TurnTimelineBuilder()
        builder.text("Je crée le rappel. ")
        builder.action("call-1")
        builder.text("Test terminé : le rappel a été créé puis supprimé.")
        builder.finish()
        let saved = "Test terminé : le rappel a été créé puis supprimé."
        let layout = TurnLayout.make(content: saved, timeline: builder.timeline, tools: [Tool(id: "call-1", name: "reminders_create")], key: \.id)
        guard case let .text(_, answer) = layout.answer.first else { return XCTFail("answer") }
        XCTAssertEqual(answer, saved)
        XCTAssertTrue(layout.work.contains { if case .tools = $0 { return true }; return false }, "actions stay in the work")
    }

    func testOnlyReasoningUsesThoughtHeaderAndRunningReasoningStaysOpen() {
        let start = Date(timeIntervalSince1970: 100)
        var builder = TurnTimelineBuilder(startedAt: start)
        builder.reasoning("Planning", at: start)
        let live = TurnLayout<Tool>.make(content: "", timeline: builder.timeline, tools: [], key: \.id, running: true, now: start.addingTimeInterval(3))
        guard case let .reasoning(_, _, duration, running) = live.work.first else { return XCTFail() }
        XCTAssertTrue(running); XCTAssertEqual(duration, 3)
        builder.text("Done.", at: start.addingTimeInterval(8)); builder.finish(at: start.addingTimeInterval(8))
        let done = TurnLayout<Tool>.make(content: "Done.", timeline: builder.timeline, tools: [], key: \.id)
        XCTAssertTrue(done.onlyReasoning)
        XCTAssertEqual(TurnLayoutText.header(onlyReasoning: true, duration: done.duration, running: false, locale: Locale(identifier: "fr")), "Réfléchi pendant 8 s")
    }

    func testMergePrefersFinishedThenLongerTimelineAndCodableRoundTrip() throws {
        var running = TurnTimelineBuilder(); running.text("a"); running.action("x")
        var finished = TurnTimelineBuilder(); finished.text("a"); finished.finish()
        XCTAssertEqual(TurnTimeline.merge(running.timeline, finished.timeline), finished.timeline)
        XCTAssertEqual(TurnTimeline.merge(nil, running.timeline), running.timeline)
        let data = try JSONEncoder().encode(NativeChatMessage(role: .assistant, text: "a", timeline: finished.timeline))
        XCTAssertEqual(try JSONDecoder().decode(NativeChatMessage.self, from: data).timeline, finished.timeline)
        let legacy = try JSONDecoder().decode(NativeChatMessage.self, from: try JSONEncoder().encode(NativeChatMessage(role: .assistant, text: "old")))
        XCTAssertNil(legacy.timeline)
    }

    func testATurnThatEndedOnAnActionKeepsItsLastWordsVisible() {
        var builder = TurnTimelineBuilder(startedAt: .now)
        builder.text("Je lance deux sous-agents. ")
        builder.action("d1")
        builder.text("Ils travaillent. ")
        builder.action("a1")
        let tools = [Tool(id: "d1", name: "delegate_task"), Tool(id: "a1", name: "await_subagents")]
        let layout = TurnLayout.make(content: "Je lance deux sous-agents. Ils travaillent. ", timeline: builder.timeline, tools: tools, key: \.id)
        guard case let .text(_, text)? = layout.answer.first else { return XCTFail("The last words stay visible") }
        XCTAssertEqual(text, "Ils travaillent. ")
        XCTAssertEqual(layout.work.count, 3)
    }

    func testEveryToolHasAHumanName() {
        let english = Locale(identifier: "en_US"), french = Locale(identifier: "fr_FR")
        for name in ["list_subagents", "retry_subagent", "recommend_subagent_models", "mail_send", "bg_click", "some_new_tool", "web_fetch"] {
            for locale in [english, french] {
                let title = ToolDisplayName.title(name, locale: locale)
                XCTAssertFalse(title.contains("_"), "\(name) → \(title)")
                XCTAssertFalse(title.lowercased().contains(name.replacingOccurrences(of: "_", with: " ")), "\(name) leaks as \(title)")
            }
        }
        XCTAssertEqual(ToolDisplayName.title("web_fetch", running: true, locale: french), "Lecture d'une page web")
    }

    func testGroupTitlesAndSubagents() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(TurnLayoutText.group(names: ["web_search", "web_search", "read_file"], running: false, locale: en), "Searched 2 times, read file")
        XCTAssertEqual(TurnLayoutText.group(names: ["run_command"], running: false, locale: Locale(identifier: "fr")), "Commande exécutée")
        var builder = TurnTimelineBuilder()
        builder.subagents(["a", "b"]); builder.subagents(["b", "c"])
        XCTAssertEqual(builder.timeline.entries.count, 1)
        XCTAssertEqual(builder.timeline.entries[0].subagentIDs, ["a", "b", "c"])
    }

    func testAnthropicThinkingMatchesEachGeneration() {
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-sonnet-4-20250514"), .budget)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-haiku-4-5"), .budget)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-3-7-sonnet-latest"), .budget)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-opus-4-6"), .adaptive46)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-opus-4-8"), .adaptive)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-sonnet-5"), .adaptive)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-sonnet-5-5"), .alwaysOn)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-opus-5-5"), .alwaysOn)
        XCTAssertEqual(AnthropicThinkingPolicy.generation(modelID: "claude-fable-5-1"), .alwaysOn)

        let legacy = AnthropicThinkingPolicy.fields(modelID: "claude-haiku-4-5", effort: "high", budget: 16_384)
        XCTAssertEqual((legacy["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 16_384)
        let modern = AnthropicThinkingPolicy.fields(modelID: "claude-opus-5-5", effort: "xhigh", budget: 32_000)
        XCTAssertEqual((modern["thinking"] as? [String: String]), ["type": "adaptive", "display": "summarized"])
        XCTAssertEqual((modern["output_config"] as? [String: String])?["effort"], "xhigh")
        XCTAssertNil((modern["thinking"] as? [String: Any])?["budget_tokens"])
        XCTAssertEqual((AnthropicThinkingPolicy.fields(modelID: "claude-opus-4-6", effort: "xhigh", budget: nil)["output_config"] as? [String: String])?["effort"], "high")
        XCTAssertTrue(AnthropicThinkingPolicy.fields(modelID: "claude-opus-4-8", effort: "none", budget: nil).isEmpty)
        XCTAssertEqual(AnthropicThinkingPolicy.fields(modelID: "claude-sonnet-5-5", effort: nil, budget: nil)["output_config"] as? [String: String], nil)
        XCTAssertNotNil(AnthropicThinkingPolicy.fields(modelID: "claude-sonnet-5-5", effort: nil, budget: nil)["thinking"])
    }

    func testReasoningDeltasForEachWireFormat() {
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"type":"response.reasoning_summary_text.delta","delta":"Compare"}"#, provider: .openAI), "Compare")
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"type":"response.reasoning_summary_part.added","summary_index":1}"#, provider: .chatgpt), "\n\n")
        XCTAssertNil(ProviderReasoningStream.delta(#"{"type":"response.output_text.delta","delta":"Answer"}"#, provider: .openAI))
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Plan"}}"#, provider: .anthropic), "Plan")
        XCTAssertNil(ProviderReasoningStream.delta(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"thinking about"}}"#, provider: .anthropic))
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"choices":[{"delta":{"reasoning":"Step"}}]}"#, provider: .openRouter), "Step")
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"choices":[{"delta":{"reasoning_content":"Why"}}]}"#, provider: .deepSeek), "Why")
        XCTAssertEqual(ProviderReasoningStream.delta(#"{"candidates":[{"content":{"parts":[{"text":"Idea","thought":true},{"text":"Answer"}]}}]}"#, provider: .google), "Idea")
    }

    func testTransportRequestsSummariesOnlyWhereAccepted() throws {
        func body(_ request: URLRequest) throws -> [String: Any] { try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:] }
        let message = NativeChatMessage(role: .user, text: "Hi")
        let claude = try body(NativeChatTransport.request(provider: .anthropic, modelID: "claude-sonnet-5-5", messages: [message], key: "k", catalogMaximum: 4096))
        XCTAssertEqual(claude["thinking"] as? [String: String], ["type": "adaptive", "display": "summarized"])
        let older = try body(NativeChatTransport.request(provider: .anthropic, modelID: "claude-haiku-4-5", messages: [message], key: "k", catalogMaximum: 4096))
        XCTAssertNil(older["thinking"])
        let plain = try body(NativeChatTransport.request(provider: .openAI, modelID: "gpt-4.1", messages: [message], key: "k"))
        XCTAssertNil(plain["reasoning"])
        let reasoning = try body(NativeChatTransport.request(provider: .openAI, modelID: "gpt-6-sol", messages: [message], key: "k", reasoningSummary: true))
        XCTAssertEqual(reasoning["reasoning"] as? [String: String], ["summary": "auto"])
    }
}

final class TurnTimelineMatchingTests: XCTestCase {
    private struct Tool: Sendable { let id: String }
    func testEngineCallIDsMatchStoredActionIDs() {
        var builder = TurnTimelineBuilder()
        builder.action("call_1"); builder.text("a"); builder.action("route:1"); builder.text("b")
        builder.finish()
        let tools = [Tool(id: "web:call_1"), Tool(id: "D2B5:route:1")]
        let layout = TurnLayout.make(content: "ab", timeline: builder.timeline, tools: tools, key: \.id)
        XCTAssertEqual(layout.work.count, 3)
        guard case let .tools(_, first) = layout.work[0], case let .tools(_, second) = layout.work[2] else { return XCTFail() }
        XCTAssertEqual(first.map(\.id), ["web:call_1"])
        XCTAssertEqual(second.map(\.id), ["D2B5:route:1"])
    }
}

final class TurnTimelineRemoteTests: XCTestCase {
    func testRemoteTimelineKeepsTheOrderAndOlderClientsStillReadIt() throws {
        let conversation = UUID(), turn = UUID()
        var builder = TurnTimelineBuilder(startedAt: Date(timeIntervalSince1970: 0))
        builder.reasoning("Plan", at: Date(timeIntervalSince1970: 0))
        builder.text("Checking. ", at: Date(timeIntervalSince1970: 2))
        builder.action("call", at: Date(timeIntervalSince1970: 3))
        builder.text("Answer.", at: Date(timeIntervalSince1970: 5))
        builder.finish(at: Date(timeIntervalSince1970: 9))
        let action = ConversationAction(id: "run:call", conversationID: conversation, turnID: turn, ordinal: 0, name: "read_file", state: .completed, input: "{\"path\":\"a.swift\"}")
        let value = try XCTUnwrap(ConversationAction.remoteTimeline([action], content: "Checking. Answer.", turn: builder.timeline)?.arrayValue)
        XCTAssertEqual(value.compactMap { $0.objectValue?["type"]?.stringValue }, ["reasoning", "text", "tool", "text", "turn"])
        let segments = RemoteTimelineRules.displayTimeline(for: .init(id: "m", role: .assistant, content: "Checking. Answer.", timeline: value))
        XCTAssertEqual(segments.map(\.typeName), ["reasoning", "text", "tool", "text"])
        let layout = TurnLayout<String>.ordered([.reasoning(id: "r", text: "Plan", duration: 2, running: false), .text(id: "a", text: "Checking. "),
            .tools(id: "t1", tools: ["a"]), .tools(id: "t2", tools: ["b"]), .text(id: "b", text: "Answer.")], duration: 9)
        XCTAssertEqual(layout.work.count, 3)
        guard case let .tools(_, merged) = layout.work[2] else { return XCTFail() }
        XCTAssertEqual(merged, ["a", "b"])
        XCTAssertEqual(layout.answer.count, 1)
    }
}
