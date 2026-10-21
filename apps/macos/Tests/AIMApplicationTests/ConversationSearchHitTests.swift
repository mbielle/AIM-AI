import AIMApplication
import XCTest

final class ConversationSearchHitTests: XCTestCase {
    func testSearchReturnsMatchingMessageExcerptAndID() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Planning")
        try await repository.save(conversation)
        let message = ConversationMessage(conversationID: conversation.id, role: .user,
                                          content: "Our café renewal meeting is next Tuesday.", sequence: 0)
        try await repository.append(message)
        let hits = try await repository.searchHits("cafe", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.conversation.id, conversation.id)
        XCTAssertEqual(hits.first?.messageID, message.id)
        XCTAssertTrue(hits.first?.excerpt?.contains("renewal meeting") == true)
        let abstract: any ConversationRepository = repository
        let protocolHits = try await abstract.searchHits("cafe", limit: 10)
        XCTAssertEqual(protocolHits.first?.messageID, message.id)
    }

    func testTitleMatchDoesNotInventMessageTargetAndArchivedIsExcluded() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let visible = Conversation(title: "Architecture notes")
        let archived = Conversation(title: "Architecture old", isArchived: true)
        try await repository.save(visible)
        try await repository.save(archived)
        let hits = try await repository.searchHits("Architecture", limit: 10)
        XCTAssertEqual(hits.map(\.id), [visible.id])
        XCTAssertNil(hits.first?.messageID)
        XCTAssertNil(hits.first?.excerpt)
    }

    func testHiddenMessagesAndOversizedQueriesProduceNoSidebarHit() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Visible title")
        try await repository.save(conversation)
        try await repository.append(.init(conversationID: conversation.id, role: .system,
                                          content: "private-sentinel", sequence: 0))
        try await repository.append(.init(conversationID: conversation.id, role: .tool,
                                          content: "tool-sentinel", sequence: 1))
        let systemHits = try await repository.searchHits("private-sentinel", limit: 10)
        let toolHits = try await repository.searchHits("tool-sentinel", limit: 10)
        let oversizedHits = try await repository.searchHits(String(repeating: "x", count: 257), limit: 10)
        XCTAssertTrue(systemHits.isEmpty)
        XCTAssertTrue(toolHits.isEmpty)
        XCTAssertTrue(oversizedHits.isEmpty)
    }
}
