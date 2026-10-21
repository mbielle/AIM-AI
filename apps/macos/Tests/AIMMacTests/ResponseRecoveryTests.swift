@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMAgentKit
import XCTest

@MainActor
final class ResponseRecoveryTests: XCTestCase {
    func testFailedProviderResponseSurvivesLocalSaveFailure() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = FailingResponseRepository(database: database)
        let model = AppModel(database: database, conversationRepository: repository, turnRunner: EmptyRecoveryRunner())
        model.connectedProviders = [.anthropic]
        model.selectedProvider = .anthropic
        model.selectedModelID = "fixture"
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.handle(.textDelta(conversationID: id, text: "Partial answer"))
        await model.handle(.failed(conversationID: id,
            diagnostic: EngineDiagnostic(code: "fixture", message: "Provider failed", isRecoverable: true)))
        XCTAssertEqual(model.unsavedResponse?.content, "Partial answer")
        XCTAssertEqual(model.unsavedResponse?.completionStatus, .failed)
        XCTAssertNotNil(model.responseSaveError)
        await repository.allowSave()
        await model.retryResponseSave()
        let saved = try await repository.messages(conversationID: id)
        XCTAssertEqual(saved.last?.completionStatus, .failed)
        XCTAssertNil(model.unsavedResponse)
        _ = await model.prepareForTermination()
    }

    func testUncertainCommittedSaveDoesNotDuplicateVisibleOrStoredAnswer() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = FailingResponseRepository(database: database, commitBeforeFailure: true)
        let model = AppModel(database: database, conversationRepository: repository, turnRunner: EmptyRecoveryRunner())
        model.connectedProviders = [.anthropic]
        model.selectedProvider = .anthropic
        model.selectedModelID = "fixture"
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.handle(.textDelta(conversationID: id, text: "Already committed"))
        await model.handle(.completed(conversationID: id))
        await model.selectConversation(id)
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.count, 1)
        await repository.allowSave()
        await model.retryResponseSave()
        let stored = try await repository.messages(conversationID: id)
        XCTAssertEqual(stored.filter { $0.role == .assistant }.count, 1)
        XCTAssertNil(model.unsavedResponse)
        _ = await model.prepareForTermination()
    }

    func testFailedSaveRetainsResponseBlocksSendAndRetryDoesNotCallProvider() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = FailingResponseRepository(database: database)
        let model = AppModel(database: database, conversationRepository: repository, turnRunner: EmptyRecoveryRunner())
        model.connectedProviders = [.anthropic]
        model.selectedProvider = .anthropic
        model.selectedModelID = "fixture"
        model.composerText = "Question"
        await model.sendComposer()
        let id = try XCTUnwrap(model.selectedConversationID)
        await model.handle(.textDelta(conversationID: id, text: "Keep this answer"))
        await model.handle(.completed(conversationID: id))
        XCTAssertEqual(model.unsavedResponse?.content, "Keep this answer")
        XCTAssertFalse(model.isSending)
        model.composerText = "Next question"
        await model.sendComposer()
        XCTAssertEqual(model.composerText, "Next question")
        let before = try await repository.messages(conversationID: id)
        XCTAssertEqual(before.count, 1)
        let quit = await model.prepareForTermination()
        XCTAssertFalse(quit)
        XCTAssertFalse(model.isShuttingDown)
        await repository.allowSave()
        await model.retryResponseSave()
        XCTAssertNil(model.unsavedResponse)
        XCTAssertNil(model.responseSaveError)
        XCTAssertFalse(model.isRetryingResponseSave)
        let after = try await repository.messages(conversationID: id)
        XCTAssertEqual(after.map(\.content), ["Question", "Keep this answer"])
        await model.retryResponseSave()
        let repeated = try await repository.messages(conversationID: id)
        XCTAssertEqual(repeated.count, 2)
        _ = await model.prepareForTermination()
    }
}

private struct EmptyRecoveryRunner: NativeAgentTurnRunning {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel(conversationID: UUID) async {}
}

private actor FailingResponseRepository: ConversationRepository {
    let base: SQLiteConversationRepository
    var failing = true
    let commitBeforeFailure: Bool
    init(database: AIMDatabase, commitBeforeFailure: Bool = false) {
        base = SQLiteConversationRepository(database: database)
        self.commitBeforeFailure = commitBeforeFailure
    }
    func allowSave() { failing = false }
    func list(includeArchived: Bool) async throws -> [Conversation] { try await base.list(includeArchived: includeArchived) }
    func conversation(id: UUID) async throws -> Conversation? { try await base.conversation(id: id) }
    func save(_ conversation: Conversation) async throws { try await base.save(conversation) }
    func delete(id: UUID) async throws { try await base.delete(id: id) }
    func messages(conversationID: UUID) async throws -> [ConversationMessage] { try await base.messages(conversationID: conversationID) }
    func append(_ message: ConversationMessage) async throws {
        if message.role == .assistant && failing {
            if commitBeforeFailure { try await base.append(message) }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await base.append(message)
    }
    func search(_ query: String, limit: Int) async throws -> [Conversation] { try await base.search(query, limit: limit) }
}
