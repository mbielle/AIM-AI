@testable import AIMApplication
import Foundation
import XCTest

final class LocalModelTuningTests: XCTestCase {
    func testChatModeGetsInstructionsAndQwenSettings() throws {
        let message = ConversationMessage(conversationID: UUID(), role: .user, content: "fait moi une blague", sequence: 0)
        let request = try ProviderChatService.localRequest(modelID: "Qwen3-8B-Q4_K_M", messages: [message], apiKey: "local", mode: .chat)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertTrue((messages.first?["content"] as? String ?? "").contains("same language"))
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual(body["top_k"] as? Int, 20)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false, "thinking is off unless asked")
    }

    func testThinkingFollowsTheEffortSwitch() {
        XCTAssertTrue(LocalModelTuning.thinks(modelID: "Qwen3-8B", effort: .high))
        XCTAssertFalse(LocalModelTuning.thinks(modelID: "Qwen3-8B", effort: OpenAIReasoningEffort.none))
        XCTAssertFalse(LocalModelTuning.thinks(modelID: "llama-3.1-8b", effort: .high))
        XCTAssertEqual(OpenAIReasoningEffort.levels(provider: .local, modelID: "Qwen3-8B", info: nil), [.none, .high])
    }
}
