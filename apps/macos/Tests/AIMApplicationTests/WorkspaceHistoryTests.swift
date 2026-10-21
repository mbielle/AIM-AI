import AIMApplication
import XCTest

final class WorkspaceHistoryTests: XCTestCase {
    func testTypedArgumentsPersistWithoutStringifyingJSON() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Typed fixture")
        try await SQLiteConversationRepository(database: db).save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "")
        try await repository.begin(run)
        let call = ModelToolCall(id: "typed", name: "fixture", jsonArguments: [
            "enabled": .boolean(true), "count": .integer(2), "values": .array([.string("one")])
        ])
        try await repository.requested(WorkspaceCall(runID: run.id, ordinal: 0, call: call))
        let history = try await repository.history(conversationID: conversation.id)
        let saved = try XCTUnwrap(history.first?.calls.first)
        let decoded = try ToolJSONValue.decodeObject(saved.argumentsJSON)
        XCTAssertEqual(decoded, call.jsonArguments)
        XCTAssertTrue(String(decoding: saved.argumentsJSON, as: UTF8.self).contains("\"enabled\":true"))
    }

    func testLongHistoryLargeArgumentsAndEvidenceSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("long.sqlite").path
        let db = try AIMDatabase(path: path)
        let conversation = Conversation(title: "Long fixture")
        try await SQLiteConversationRepository(database: db).save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "")
        try await repository.begin(run)
        for ordinal in 0..<100 {
            let id = "call\(ordinal)"
            try await repository.requested(WorkspaceCall(runID: run.id, ordinal: ordinal,
                call: ModelToolCall(id: id, name: "fixture", arguments: ["text": String(repeating: "é", count: 40_000)])))
            try await repository.launched(runID: run.id, callID: id)
            try await repository.returned(runID: run.id, output: ModelToolOutput(id: id, content: "observed", isError: false,
                metadata: ["verification": "not_performed"]))
        }
        let artifactID = UUID().uuidString
        try await repository.saveToolArtifact(id: artifactID, runID: run.id, content: Data("full output".utf8))
        try await repository.finish(runID: run.id, state: .unverified)
        let reopened = SQLiteWorkspaceRunRepository(database: try AIMDatabase(path: path))
        let history = try await reopened.history(conversationID: conversation.id)
        XCTAssertEqual(history.first?.calls.count, 100)
        XCTAssertEqual(history.first?.run.state, .unverified)
        XCTAssertNotNil(history.first?.calls.last?.launchedAt)
        XCTAssertNotNil(history.first?.calls.last?.resultMetadataJSON)
        let artifact = try await reopened.readToolArtifact(id: artifactID, runID: run.id, offset: 0, limit: 100)
        XCTAssertEqual(artifact.text, "full output")
        do {
            _ = try await reopened.readToolArtifact(id: artifactID, runID: UUID().uuidString, offset: 0, limit: 100)
            XCTFail("Cross-run reads must fail")
        } catch {}
    }

    func testArtifactCanBeReadAcrossRunsOnlyWithinConversationAndWorkspace() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: db)
        let first = Conversation(title: "First", mode: .agent)
        let second = Conversation(title: "Second", mode: .agent)
        try await conversations.save(first)
        try await conversations.save(second)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let original = WorkspaceRun(conversationID: first.id, provider: .openAI,
                                    modelID: "fixture", workspacePath: "/fixture")
        let otherWorkspace = WorkspaceRun(conversationID: first.id, provider: .openAI,
                                          modelID: "fixture", workspacePath: "/elsewhere")
        let otherConversation = WorkspaceRun(conversationID: second.id, provider: .openAI,
                                             modelID: "fixture", workspacePath: "/fixture")
        for run in [original, otherWorkspace, otherConversation] { try await repository.begin(run) }
        let allowedIDs = [UUID().uuidString, UUID().uuidString]
        for id in allowedIDs {
            try await repository.saveToolArtifact(id: id, runID: original.id,
                                                   content: Data("saved evidence".utf8))
        }
        let wrongWorkspaceID = UUID().uuidString
        let wrongConversationID = UUID().uuidString
        try await repository.saveToolArtifact(id: wrongWorkspaceID, runID: otherWorkspace.id,
                                               content: Data("private workspace".utf8))
        try await repository.saveToolArtifact(id: wrongConversationID, runID: otherConversation.id,
                                               content: Data("private chat".utf8))
        for run in [original, otherWorkspace, otherConversation] {
            try await repository.finish(runID: run.id, state: .unverified)
        }
        let resumed = WorkspaceRun(conversationID: first.id, provider: .openAI,
                                   modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(resumed)
        let page1 = try await repository.listToolArtifacts(conversationID: first.id,
            workspacePath: "/fixture", offset: 0, limit: 1)
        let page2 = try await repository.listToolArtifacts(conversationID: first.id,
            workspacePath: "/fixture", offset: try XCTUnwrap(page1.nextOffset), limit: 1)
        XCTAssertEqual(Set((page1.artifacts + page2.artifacts).map(\.id)), Set(allowedIDs))
        XCTAssertNil(page2.nextOffset)
        let read = try await repository.readToolArtifact(id: allowedIDs[0], conversationID: first.id,
            workspacePath: "/fixture", offset: 0, limit: 100)
        XCTAssertEqual(read.text, "saved evidence")
        for id in [wrongWorkspaceID, wrongConversationID] {
            do {
                _ = try await repository.readToolArtifact(id: id, conversationID: first.id,
                    workspacePath: "/fixture", offset: 0, limit: 100)
                XCTFail("An artifact from another scope must not be readable")
            } catch {}
        }
    }

    func testDatabaseArtifactPagesPreserveUnicodeBoundaries() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Unicode pages", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(run)
        let original = String(repeating: "a", count: 65_533) + "🌍" +
            String(repeating: "é", count: 35_000)
        let id = UUID().uuidString
        try await repository.saveToolArtifact(id: id, runID: run.id,
                                               content: Data(original.utf8))
        try await repository.finish(runID: run.id, state: .unverified)
        var offset = 0
        var restored = ""
        repeat {
            let page = try await repository.readToolArtifact(id: id, conversationID: chat.id,
                workspacePath: "/fixture", offset: offset, limit: 65_535)
            restored += page.text
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(restored, original)
        do {
            _ = try await repository.readToolArtifact(id: id, conversationID: chat.id,
                workspacePath: "/fixture", offset: 65_534, limit: 100)
            XCTFail("A page must not begin inside a UTF-8 code point")
        } catch {}
    }

    func testInterruptedLaunchedActionRequiresReconciliation() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Crash fixture")
        try await SQLiteConversationRepository(database: db).save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(run)
        for index in 0..<2 {
            try await repository.requested(WorkspaceCall(runID: run.id, ordinal: index,
                call: ModelToolCall(id: "\(index)", name: "write", arguments: [:])))
        }
        try await repository.launched(runID: run.id, callID: "1")
        do { try await repository.launched(runID: run.id, callID: "1"); XCTFail("No second launch") } catch {}
        try await repository.finish(runID: run.id, state: .cancelled)
        let history = try await repository.history(conversationID: conversation.id)
        XCTAssertEqual(history.first?.calls[0].requiresReconciliation, false)
        XCTAssertEqual(history.first?.calls[1].requiresReconciliation, true)
    }

    func testCompletedHistorySurvivesReopenAndConversationDeletionCascades() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.sqlite").path
        let db = try AIMDatabase(path: path)
        let conversations = SQLiteConversationRepository(database: db)
        let conversation = Conversation(title: "History", mode: .code)
        try await conversations.save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(run)
        try await repository.requested(WorkspaceCall(runID: run.id, ordinal: 0, call: ModelToolCall(id: "read", name: "read_file", arguments: ["path": "README.md"])))
        try await repository.returned(runID: run.id, output: ModelToolOutput(id: "read", content: "Saved result", isError: false))
        try await repository.finish(runID: run.id, state: .completed)
        let reopened = SQLiteWorkspaceRunRepository(database: try AIMDatabase(path: path))
        let history = try await reopened.history(conversationID: conversation.id)
        XCTAssertEqual(history.first?.run.state, .completed)
        XCTAssertEqual(history.first?.run.provider, .openAI)
        XCTAssertEqual(history.first?.calls.first?.result, "Saved result")
        XCTAssertEqual(history.first?.calls.first?.state, .succeeded)
        try await conversations.delete(id: conversation.id)
        let deleted = try await reopened.history(conversationID: conversation.id)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testIncompleteCallsRemainUnknownUntilExplicitFinalization() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Interrupted")
        try await SQLiteConversationRepository(database: db).save(conversation)
        let repository = SQLiteWorkspaceRunRepository(database: db)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "/fixture")
        try await repository.begin(run)
        let call = try WorkspaceCall(runID: run.id, ordinal: 0, call: ModelToolCall(id: "read", name: "read_file", arguments: [:]))
        try await repository.requested(call)
        do { try await repository.requested(call); XCTFail("Duplicate must fail") } catch {}
        do { try await repository.finish(runID: run.id, state: .completed); XCTFail("Pending result must block completion") } catch {}
        let unfinished = try await repository.history(conversationID: conversation.id)
        XCTAssertEqual(unfinished.first?.run.state, .running)
        XCTAssertEqual(unfinished.first?.calls.first?.state, .requested)
        XCTAssertNil(unfinished.first?.calls.first?.result)
        try await repository.finish(runID: run.id, state: .cancelled)
        let cancelled = try await repository.history(conversationID: conversation.id)
        XCTAssertEqual(cancelled.first?.calls.first?.state, .interrupted)
        do { try await repository.returned(runID: run.id, output: ModelToolOutput(id: "read", content: "Late", isError: false)); XCTFail("Late writes must fail") } catch {}
    }
}
