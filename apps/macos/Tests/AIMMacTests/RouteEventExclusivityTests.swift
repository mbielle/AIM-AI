@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMAgentKit
import AIMCore
import XCTest

/// Test 27 crashed on the first route event of an OpenRouter-routed answer: the draft was read
/// while its own write access was open. Route attempts, sources and the timeline must survive.
@MainActor
final class RouteEventExclusivityTests: XCTestCase {
    func testRouteAndMetricsEventsUpdateTheDraftWithoutExclusivityConflict() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database, turnRunner: SilentRouteRunner())
        model.connectedProviders = [.openRouter]
        model.selectedProvider = .openRouter
        model.selectedModelID = "anthropic/claude-sonnet-5.5"
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.handle(.routeAttempt(conversationID: id, attempt: .init(provider: .anthropic, modelID: "claude-sonnet-5-5", ordinal: 0, state: .rejected)))
        await model.handle(.routeAttempt(conversationID: id, attempt: .init(provider: .openRouter, modelID: "anthropic/claude-sonnet-5.5", ordinal: 1, state: .trying)))
        await model.handle(.reasoningDelta(conversationID: id, text: "Planning"))
        await model.handle(.textDelta(conversationID: id, text: "Answer [1]"))
        var metrics = TurnMetrics(provider: "openrouter", modelID: "anthropic/claude-sonnet-5.5", mode: "agent", startedAt: .now,
            usage: TokenUsage(), firstTokenSeconds: nil, streamSeconds: nil, totalSeconds: 1, characters: 10)
        metrics.routeAttempts = [.init(provider: .openRouter, modelID: "anthropic/claude-sonnet-5.5", ordinal: 1, state: .accepted)]
        metrics.sources = [ConversationSource(url: "https://example.com", title: "Example", references: [1])!]
        await model.handle(.turnMetrics(conversationID: id, metrics: metrics))
        await model.handle(.completed(conversationID: id))
        let stored = try await model.conversationRepository.messages(conversationID: id)
        let draft = try XCTUnwrap(stored.last { $0.role == .assistant })
        XCTAssertEqual(draft.routeAttempts?.count, 2)
        XCTAssertEqual(draft.sources?.first?.url, "https://example.com")
        XCTAssertTrue(draft.actions?.contains { $0.id.hasSuffix(":route:1") } == true)
        XCTAssertEqual(draft.timeline?.entries.map(\.kind).first, "reasoning")
        _ = await model.prepareForTermination()
    }
}

private struct SilentRouteRunner: NativeAgentTurnRunning {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func cancel(conversationID: UUID) async {}
}
