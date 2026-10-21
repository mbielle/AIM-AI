import AIMApplication
import XCTest

final class ContextUsageTests: XCTestCase {
    func testPartsFromReservedSequencesAndScaling() {
        let id = UUID()
        let messages = [
            ConversationMessage(conversationID: id, role: .user, content: String(repeating: "m", count: 400), sequence: 0),
            ConversationMessage(conversationID: id, role: .user, content: String(repeating: "s", count: 200), sequence: -4),
            ConversationMessage(conversationID: id, role: .user, content: String(repeating: "r", count: 100), sequence: -3),
            ConversationMessage(conversationID: id, role: .user, content: "Earlier conversation summary " + String(repeating: "x", count: 100), sequence: -3),
        ]
        let tools = [ModelToolDefinition(name: "read_file", description: "Reads"), ModelToolDefinition(name: "mcp__notion__search", description: "Searches")]
        var usage = ContextUsage.estimate(messages: messages, systemPrompt: String(repeating: "p", count: 80), tools: tools, limit: 1_000)
        XCTAssertEqual(usage.tokens(.messages), 104)
        XCTAssertEqual(usage.tokens(.skills), 54)
        XCTAssertGreaterThan(usage.tokens(.memory), 0)
        XCTAssertGreaterThan(usage.tokens(.summary), 0)
        XCTAssertGreaterThan(usage.tokens(.mcpTools), 0)
        XCTAssertGreaterThan(usage.tokens(.systemTools), 0)
        let estimated = usage.total
        usage.reportedTotal = estimated * 2
        XCTAssertEqual(usage.tokens(.messages), 208, "Parts follow the provider's real count")
        XCTAssertEqual(usage.fraction ?? 0, min(1, Double(estimated * 2) / 1_000), accuracy: 0.001)
    }

    func testForcedCompactionKeepsTheLastTwoExchanges() throws {
        let id = UUID()
        let messages = (0..<10).map { index in
            ConversationMessage(conversationID: id, role: index % 2 == 0 ? .user : .assistant, content: "Message \(index)", sequence: index)
        }
        XCTAssertTrue(try SessionCompactionContext.nextBatch(messages, checkpoint: nil).isEmpty, "Small: no automatic compaction")
        let batch = try SessionCompactionContext.nextBatch(messages, checkpoint: nil, force: true)
        XCTAssertEqual(batch.map(\.sequence), Array(0..<6))
    }
}
