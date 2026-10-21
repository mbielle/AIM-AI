import XCTest
@testable import AIMApplication

final class ExecutionControlReceiptTests: XCTestCase {
    func testDuplicateCorrectionIsAtomicAndNeverResumesUserPause() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Control", mode: .agent)
        let conversations = SQLiteConversationRepository(database: database)
        try await conversations.save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await repository.installOwner(owner)
        let execution = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        _ = try await repository.control(commandID: UUID(), executionID: execution.id, action: "pause", owner: owner)
        let commandID = UUID()
        let first = try await repository.control(commandID: commandID, executionID: execution.id, action: "correct", text: "Use exact reference", owner: owner)
        let repeated = try await repository.control(commandID: commandID, executionID: execution.id, action: "correct", text: "Use exact reference", owner: owner)
        XCTAssertEqual(first, repeated); XCTAssertEqual(first.state, .paused)
        let messages = try await conversations.messages(conversationID: conversation.id)
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?.id, commandID)
        do { _ = try await repository.control(commandID: commandID, executionID: execution.id, action: "correct", text: "Changed payload", owner: owner); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .commandConflict) }
        let nextOwner = UUID(); try await repository.installOwner(nextOwner)
        do { _ = try await repository.control(commandID: UUID(), executionID: execution.id, action: "resume", owner: owner); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        let resumed = try await repository.control(commandID: UUID(), executionID: execution.id, action: "resume", owner: nextOwner)
        XCTAssertEqual(resumed.state, .queued)
    }
}
