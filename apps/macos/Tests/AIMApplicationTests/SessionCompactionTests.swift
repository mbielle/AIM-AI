import AIMApplication
import XCTest

final class SessionCompactionTests: XCTestCase {
    func testSmallContextModelCompactsBeforeFixedThreshold() throws {
        let id = UUID()
        let history = (0..<12).map { index in
            ConversationMessage(conversationID: id, role: .user,
                                content: String(repeating: "x", count: 2_000), sequence: index)
        }
        // One rule with compaction during a run: 85 % of the working window, about 3 bytes per token.
        XCTAssertEqual(SessionCompactionContext.triggerBytes(contextLength: nil), ContextCompactionPolicy.triggerBytes(contextLength: nil))
        XCTAssertEqual(SessionCompactionContext.triggerBytes(contextLength: nil), 326_400)
        XCTAssertEqual(SessionCompactionContext.triggerBytes(contextLength: 4_096), 12_000)
        XCTAssertEqual(SessionCompactionContext.batchLimitBytes(contextLength: 4_096), 8_000)
        XCTAssertEqual(SessionCompactionContext.summaryLimitBytes(contextLength: 4_096), 3_000)
        XCTAssertTrue(try SessionCompactionContext.nextBatch(history, checkpoint: nil).isEmpty)
        let batch = try SessionCompactionContext.nextBatch(history, checkpoint: nil,
                                                           contextLength: 4_096)
        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(batch.last?.sequence, 2)
        XCTAssertLessThan(SessionCompactionContext.summaryInput(batch, previous: nil, contextLength: 4_096).utf8.count, 9_000)
        let checkpoint = try SessionCompaction(conversationID: id,
                                               throughMessageID: batch.last!.id,
                                               throughSequence: batch.last!.sequence,
                                               summary: "Earlier context is available locally.")
        let retained = try SessionCompactionContext.requestHistory(history, checkpoint: checkpoint)
        XCTAssertEqual(retained.dropFirst().map(\.id), Array(history.dropFirst(3)).map(\.id))
        // Million-token models compact within the 200k-token working window.
        XCTAssertEqual(SessionCompactionContext.triggerBytes(contextLength: Int.max), 510_000)
    }

    func testSingleLongSourceIsBoundedInSmallModelSummaryRequest() throws {
        let id = UUID()
        let history = (0..<10).map { index in
            ConversationMessage(conversationID: id, role: .user,
                                content: index == 0 ? String(repeating: "x", count: 50_000) : "Later \(index)",
                                sequence: index)
        }
        let batch = try SessionCompactionContext.nextBatch(history, checkpoint: nil,
                                                           contextLength: 4_096)
        XCTAssertEqual(batch.map(\.sequence), [0])
        let input = SessionCompactionContext.summaryInput(batch, previous: nil,
                                                          contextLength: 4_096)
        XCTAssertLessThan(input.utf8.count, SessionCompactionContext.triggerBytes(contextLength: 4_096))
        XCTAssertFalse(input.contains(String(repeating: "x", count: 8_001)))
        XCTAssertTrue(input.contains("original retained locally"))
        XCTAssertEqual(history[0].content.utf8.count, 50_000)
    }

    func testAuxiliaryAndToolSchemaReserveTriggersAdditionalCompaction() throws {
        let id = UUID()
        let history = (0..<9).map { index in
            ConversationMessage(conversationID: id, role: .user,
                                content: String(repeating: "x", count: 1_000), sequence: index)
        }
        XCTAssertEqual(SessionCompactionContext.requestTriggerBytes(contextLength: 4_096,
                                                                    reservedRequestBytes: 5_000), 7_000)
        XCTAssertTrue(try SessionCompactionContext.nextBatch(history, checkpoint: nil,
                                                               contextLength: 4_096).isEmpty)
        XCTAssertFalse(try SessionCompactionContext.nextBatch(history, checkpoint: nil,
                                                               contextLength: 4_096,
                                                               reservedRequestBytes: 5_000).isEmpty)
        let short = ModelToolDefinition(name: "read_file", description: "Read a file",
                                        requiredArguments: ["path"])
        let long = ModelToolDefinition(name: "read_file", description: String(repeating: "a", count: 2_000),
                                       requiredArguments: ["path"])
        let shortBytes = try ProviderToolConversation.estimatedFixedRequestBytes(provider: .openAI,
                                                                                 tools: [short], planOnly: false)
        let longBytes = try ProviderToolConversation.estimatedFixedRequestBytes(provider: .openAI,
                                                                                tools: [long], planOnly: false)
        XCTAssertGreaterThan(longBytes - shortBytes, 1_900)
        XCTAssertGreaterThan(TextProtocolToolConversation.estimatedFixedRequestBytes(tools: [long],
                                                                                      planOnly: false), longBytes)
    }

    func testCompactionKeepsRecentMessagesAndOriginalTranscript() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let store = SQLiteSessionCompactionRepository(database: database)
        let conversation = Conversation(title: "Long session", provider: .openAI, modelID: "fixture")
        try await conversations.save(conversation)
        let original = (0..<14).map { index in
            ConversationMessage(conversationID: conversation.id, role: index.isMultiple(of: 2) ? .user : .assistant,
                                content: "Message \(index): " + String(repeating: "a", count: 16_000), sequence: index)
        }
        for message in original { try await conversations.append(message) }
        let firstBatch = try SessionCompactionContext.nextBatch(original, checkpoint: nil, contextLength: 32_000)
        XCTAssertFalse(firstBatch.isEmpty)
        XCTAssertLessThanOrEqual(firstBatch.last!.sequence, 5)
        let checkpoint = try SessionCompaction(conversationID: conversation.id,
                                               throughMessageID: firstBatch.last!.id,
                                               throughSequence: firstBatch.last!.sequence,
                                               summary: "The user chose SQLite; implementation is unfinished.")
        try await store.save(checkpoint)
        let reloaded = try await store.load(conversationID: conversation.id)
        XCTAssertEqual(reloaded, checkpoint)
        let stale = try SessionCompaction(conversationID: conversation.id,
                                          throughMessageID: original[0].id, throughSequence: 0,
                                          summary: "An out-of-order summary")
        do { try await store.save(stale); XCTFail("Checkpoint must never move backwards") }
        catch SessionCompactionError.staleCheckpoint { }
        let selected = try SessionCompactionContext.requestHistory(original, checkpoint: checkpoint)
        XCTAssertTrue(selected.first!.content.contains("The user chose SQLite"))
        XCTAssertTrue(selected.first!.content.contains("read_history_message"))
        XCTAssertTrue(selected.first!.content.contains("sequence \(checkpoint.throughSequence)"))
        XCTAssertEqual(selected.dropFirst().map(\.id), original.filter { $0.sequence > checkpoint.throughSequence }.map(\.id))
        let retained = try await conversations.messages(conversationID: conversation.id)
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        XCTAssertTrue(zip(retained, original).allSatisfy { $0.content == $1.content })
        try await conversations.delete(id: conversation.id)
        let deleted = try await store.load(conversationID: conversation.id)
        XCTAssertNil(deleted)
    }

    func testStaleCheckpointFailsClosedAndSummaryDoesNotIncludeOldFileContents() throws {
        let id = UUID()
        let old = ConversationMessage(conversationID: id, role: .user, content: "Review this", sequence: 0,
                                      attachments: [TextAttachment(name: "private.txt", content: "sensitive attachment body")])
        let prompt = SessionCompactionContext.summaryInput([old], previous: nil)
        XCTAssertTrue(prompt.contains("private.txt"))
        XCTAssertTrue(prompt.contains(old.id.uuidString))
        XCTAssertFalse(prompt.contains("sensitive attachment body"))
        let checkpoint = try SessionCompaction(conversationID: id, throughMessageID: UUID(),
                                               throughSequence: 0, summary: "An old summary")
        XCTAssertThrowsError(try SessionCompactionContext.requestHistory([old], checkpoint: checkpoint))
    }

    func testIncompleteAssistantIsNeverUsedAsCompactionAnchor() throws {
        let id = UUID()
        let history = (0..<14).map { index in
            ConversationMessage(conversationID: id, role: index.isMultiple(of: 2) ? .user : .assistant,
                                content: String(repeating: "x", count: 18_000), sequence: index,
                                completionStatus: index == 3 ? .failed : nil)
        }
        let batch = try SessionCompactionContext.nextBatch(history, checkpoint: nil, contextLength: 32_000)
        XCTAssertFalse(batch.contains { $0.sequence == 3 })
        XCTAssertTrue(batch.allSatisfy { $0.completionStatus == nil })
        XCTAssertEqual(try SessionCompactionContext.requestHistory(history, checkpoint: nil).count, 13)
    }

    func testOlderAttachmentBodiesLeaveRequestContextWithoutExtraSummaryCalls() throws {
        let id = UUID()
        let attachments = [TextAttachment(name: "one.txt", content: String(repeating: "a", count: 64_000)),
                           TextAttachment(name: "two.txt", content: String(repeating: "b", count: 64_000))]
        let history = (0..<10).map { index in
            ConversationMessage(conversationID: id, role: .user, content: "Message \(index)", sequence: index,
                                attachments: attachments)
        }
        let batch = try SessionCompactionContext.nextBatch(history, checkpoint: nil, contextLength: 32_000)
        XCTAssertGreaterThanOrEqual(batch.count, 6) // Names, not 128 KB file bodies, are summarized.
        let last = try XCTUnwrap(batch.last)
        let checkpoint = try SessionCompaction(conversationID: id, throughMessageID: last.id,
                                               throughSequence: last.sequence, summary: "Older files need reattachment.")
        let selected = try SessionCompactionContext.requestHistory(history, checkpoint: checkpoint)
        XCTAssertNoThrow(try AttachmentContext.expand(selected))
        XCTAssertEqual(selected.last?.id, history.last?.id)
    }
}
