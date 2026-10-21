@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class SearchNavigationTests: XCTestCase {
    func testOpenHitTargetsSavedMessageAndNormalNavigationClearsTarget() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let matching = Conversation(title: "First")
        let other = Conversation(title: "Second")
        try await repository.save(matching)
        try await repository.save(other)
        let message = ConversationMessage(conversationID: matching.id, role: .user,
                                          content: "Discuss SwiftUI layouts", sequence: 0)
        try await repository.append(message)
        let model = AppModel(database: database)
        let hits = await model.searchConversationHits("SwiftUI")
        XCTAssertEqual(hits.count, 1)
        await model.openSearchHit(try XCTUnwrap(hits.first))
        XCTAssertEqual(model.selectedConversationID, matching.id)
        XCTAssertEqual(model.searchTargetMessageID, message.id)
        await model.selectConversation(other.id)
        XCTAssertNil(model.searchTargetMessageID)
    }
}
