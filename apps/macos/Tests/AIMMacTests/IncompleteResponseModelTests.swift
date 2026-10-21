@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

@MainActor
final class IncompleteResponseModelTests: XCTestCase {
    func testFailedPartialAnswerIsPersistedAndLabeled() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = preparedModel(database: database)
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.handle(.textDelta(conversationID: id, text: "Unfinished"))
        await model.handle(.failed(conversationID: id,
            diagnostic: EngineDiagnostic(code: "fixture", message: "Provider failed", isRecoverable: true)))
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.messages.last?.content, "Unfinished")
        XCTAssertEqual(model.messages.last?.completionStatus, .failed)
        let saved = try await SQLiteConversationRepository(database: database).messages(conversationID: id)
        XCTAssertEqual(saved.last?.completionStatus, .failed)
        XCTAssertEqual(ProviderHistory.completedContext(saved).map(\.content), ["Question"])
        _ = await model.prepareForTermination()
    }

    func testCancelledBeforeFirstTokenLeavesVisibleDurableMarker() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = preparedModel(database: database)
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.cancelCurrentTurn()
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.messages.last?.role, .assistant)
        XCTAssertEqual(model.messages.last?.content, "")
        XCTAssertEqual(model.messages.last?.completionStatus, .cancelled)
        let saved = try await SQLiteConversationRepository(database: database).messages(conversationID: id)
        XCTAssertEqual(saved.last?.completionStatus, .cancelled)
        _ = await model.prepareForTermination()
    }

    private func preparedModel(database: AIMDatabase) -> AppModel {
        let model = AppModel(database: database, turnRunner: HoldingResponseRunner())
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        return model
    }
}

private struct HoldingResponseRunner: NativeAgentTurnRunning {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { _ in }
    }
    func cancel(conversationID: UUID) async {}
}
