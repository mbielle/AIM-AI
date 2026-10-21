@testable import AIMApplication
import Foundation
import XCTest

final class ToolTurnReasoningTests: XCTestCase {
    func testResponsesReasoningSummaryIsShownWhileTheItemIsReplayedUnchanged() throws {
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque",
            "summary": [["type": "summary_text", "text": "**Plan** Check the file first."], ["type": "summary_text", "text": "Then answer."]]]
        let response: [String: Any] = ["object": "response", "status": "completed", "error": NSNull(), "output": [reasoning,
            ["type": "message", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]]]
        let decoded = try OpenAIToolWire.decode(try JSONSerialization.data(withJSONObject: response), tools: [])
        XCTAssertEqual(decoded.turn.text, "Done.")
        XCTAssertEqual(decoded.turn.reasoning, "**Plan** Check the file first.\n\nThen answer.")
        XCTAssertEqual(decoded.items.first?["encrypted_content"] as? String, "opaque")
    }

    func testEmptySummariesStayAbsentAndOlderCheckpointsDecode() throws {
        XCTAssertNil(ModelToolTurn(text: "a", calls: [], reasoning: "  ").reasoning)
        let old = try JSONDecoder().decode(ModelToolTurn.self, from: Data(#"{"text":"a","calls":[]}"#.utf8))
        XCTAssertNil(old.reasoning)
    }
}
