@testable import AIMApplication
import Foundation
import XCTest

final class ReasoningEffortLevelsTests: XCTestCase {
    func testCatalogLevelsWinAndMandatoryReasoningHasNoOff() throws {
        let json = """
        {"id":"anthropic/claude-opus-5.5","name":"Claude Opus 5.5",
         "reasoning":{"mandatory":true,"supported_efforts":["max","xhigh","high","medium","low"],"default_effort":"high"}}
        """
        let opus = try JSONDecoder().decode(ChatModel.self, from: Data(json.utf8))
        let levels = OpenAIReasoningEffort.levels(provider: .openRouter, modelID: opus.id, info: opus.reasoning)
        XCTAssertEqual(levels, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(OpenAIReasoningEffort.defaultLevel(info: opus.reasoning), .high)
    }

    func testOptionalReasoningOffersOff() {
        let info = ChatModel.ReasoningInfo(mandatory: false, supportedEfforts: ["low", "high"], defaultEffort: "high")
        XCTAssertEqual(OpenAIReasoningEffort.levels(provider: .openRouter, modelID: "x/y", info: info), [.none, .low, .high])
    }

    func testUnsupportedSavedEffortFallsBackToModelDefault() {
        let info = ChatModel.ReasoningInfo(mandatory: true, supportedEfforts: ["low", "medium", "high"], defaultEffort: "medium")
        XCTAssertNil(OpenAIReasoningEffort.effective(.none, provider: .openRouter, modelID: "a/b", info: info))
        XCTAssertNil(OpenAIReasoningEffort.effective(.minimal, provider: .openRouter, modelID: "a/b", info: info))
        XCTAssertEqual(OpenAIReasoningEffort.effective(.high, provider: .openRouter, modelID: "a/b", info: info), .high)
        XCTAssertNil(OpenAIReasoningEffort.effective(.high, provider: .deepSeek, modelID: "deepseek-chat", info: info),
                     "providers without an effort parameter never receive one")
    }

    func testDirectClaude5WithoutCatalogHasNoOff() {
        XCTAssertFalse(OpenAIReasoningEffort.levels(provider: .anthropic, modelID: "claude-opus-5-5", info: nil).contains(.none))
    }
}
