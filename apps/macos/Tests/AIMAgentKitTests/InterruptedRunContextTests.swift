import AIMAgentKit
import AIMApplication
import XCTest

final class InterruptedRunContextTests: XCTestCase {
    func testInterruptedRunJournalIsGivenBackToTheModel() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Resume", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: database)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openRouter, modelID: "m", workspacePath: "")
        try await repository.begin(run)
        let read = try WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "c1", name: "read_file", arguments: ["path": "notes.txt"]))
        try await repository.requested(read)
        try await repository.returned(runID: run.id, output: ModelToolOutput(id: "c1",
            content: "API_KEY=abcdefgh12345678 and the plan", isError: false))
        let send = try WorkspaceCall(runID: run.id, ordinal: 1,
            call: ModelToolCall(id: "c2", name: "mail_send", arguments: ["to": "x@example.invalid"]))
        try await repository.requested(send)

        let runs = try await repository.history(conversationID: conversation.id, limit: 1)
        let message = try XCTUnwrap(InterruptedRunContext.message(runs, conversationID: conversation.id))
        XCTAssertTrue(message.content.contains("was cut off"))
        XCTAssertTrue(message.content.contains("1. read_file(path=notes.txt) → ok"))
        XCTAssertTrue(message.content.contains("2. mail_send(to=x@example.invalid) → OUTCOME UNKNOWN"))
        XCTAssertFalse(message.content.contains("abcdefgh12345678"), "journal excerpts are redacted")

        try await repository.finish(runID: run.id, state: .cancelled)
        let cancelled = try await repository.history(conversationID: conversation.id, limit: 1)
        XCTAssertTrue(InterruptedRunContext.message(cancelled, conversationID: conversation.id)?.content.contains("ended early (cancelled)") == true)

        let next = WorkspaceRun(conversationID: conversation.id, provider: .openRouter, modelID: "m", workspacePath: "")
        try await repository.begin(next)
        try await repository.finish(runID: next.id, state: .unverified)
        let finished = try await repository.history(conversationID: conversation.id, limit: 1)
        XCTAssertNil(InterruptedRunContext.message(finished, conversationID: conversation.id), "a finished run needs no resume context")
    }
}
