import XCTest
import GRDB
@testable import AIMApplication

final class ExecutionArtifactStoreTests: XCTestCase {
    func testPrivateDeduplicatedArtifactsRejectCorruptionAndPathTraversal() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-artifacts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ExecutionArtifactStore(directory: directory)
        let bytes = Data(repeating: 0x41, count: 1024 * 1024)
        let first = try store.put(bytes); XCTAssertEqual(try store.put(bytes), first)
        XCTAssertEqual(try store.read(first), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: first).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertThrowsError(try store.read("../private"))
        try Data("corrupt".utf8).write(to: directory.appending(path: first))
        XCTAssertThrowsError(try store.read(first))
    }
    func testCheckpointReferencesLargeDataAndRestoresExactlyWithNewRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-checkpoint-artifacts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "large", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let vault = try ExecutionArtifactStore(directory: directory)
        let store = SQLiteAgentExecutionRepository(database: db, artifacts: vault)
        let owner = UUID(); try await store.installOwner(owner)
        let execution = try await store.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        let running = try await store.transition(execution.id, owner: owner, expectedRevision: 0, to: .running)
        let transcript = Data(repeating: 0x54, count: 1024 * 1024)
        let image = Data(repeating: 0x49, count: 512 * 1024)
        let call = ModelToolCall(id: "capture", name: "capture", arguments: [:])
        var effect = ExecutionEffect(call: call, policy: .readOnly)
        effect.state = .returned; effect.output = ModelToolOutput(id: call.id, content: "Historical image", isError: false, imagePNG: image)
        let checkpoint = ExecutionCheckpoint(conversation: ModelConversationCheckpoint(codec: "test", provider: .google, modelID: "fake",
            transcript: transcript, pendingIDs: [call.id], seenIDs: [call.id], finished: false, usage: TokenUsage()),
            turn: ModelToolTurn(text: "", calls: [call]), effects: [effect], ordinal: 1, seenCallIDs: [call.id])
        _ = try await store.saveCheckpoint(checkpoint, executionID: execution.id, owner: owner, expectedRevision: running.revision)
        let bytes = try await db.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [execution.id.uuidString])
        }
        XCTAssertLessThan(try XCTUnwrap(bytes).count, 8192)
        let replacement = SQLiteAgentExecutionRepository(database: db, artifacts: vault)
        let restored = try await replacement.checkpoint(execution.id)
        XCTAssertEqual(restored, checkpoint)
    }
}
