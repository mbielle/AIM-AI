import AIMApplication
import XCTest

final class ModelRoutingTests: XCTestCase {
    func testDirectConnectionWinsWithoutDuplicatingCreator() {
        let catalogs: [ChatProvider: [ChatModel]] = [
            .anthropic: [.init(id: "claude-opus-5-5", name: "Claude Opus 5.5")],
            .openRouter: [.init(id: "anthropic/claude-opus-5.5", name: "Anthropic: Claude Opus 5.5")]
        ]
        let entries = ModelRouting.entries(catalogs)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.provider, .anthropic)
        XCTAssertEqual(ModelRouting.resolve(modelID: "anthropic/claude-opus-5.5", provider: .openRouter, catalogs: catalogs)?.provider, .anthropic)
    }
    func testDatedSnapshotIsNotAssumedEquivalentToAnUndatedRoute() {
        let catalogs: [ChatProvider: [ChatModel]] = [
            .anthropic: [.init(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5")],
            .openRouter: [.init(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5")]
        ]
        XCTAssertEqual(ModelRouting.entries(catalogs).count, 2)
        XCTAssertTrue(ModelRouting.entries(catalogs).allSatisfy { $0.routes.count == 1 })
    }

    func testNonChatModelsAreRecognized() throws {
        let json = #"{"id":"typesafe/jev-1.13","name":"Jev","architecture":{"input_modalities":["text"],"output_modalities":["decisions"]}}"#
        let model = try JSONDecoder().decode(ChatModel.self, from: Data(json.utf8))
        XCTAssertFalse(model.isChatModel)
        XCTAssertTrue(ChatModel(id: "claude", name: "Claude").isChatModel)
    }

    func testSnapshotsAndFreeVariantsStayDistinct() {
        XCTAssertNotEqual(ModelRouting.identity("openai/model:free", provider: .openRouter), ModelRouting.identity("model", provider: .openAI))
        XCTAssertNotEqual(ModelRouting.identity("model-20260927", provider: .openAI), ModelRouting.identity("model", provider: .openAI))
    }
    func testFallbackNeverReplaysPartialOrAmbiguousRequests() {
        XCTAssertTrue(ModelRouting.canFallback(ChatServiceError.http(429), emittedOutput: false))
        XCTAssertFalse(ModelRouting.canFallback(ChatServiceError.http(429), emittedOutput: true))
        XCTAssertFalse(ModelRouting.canFallback(URLError(.timedOut), emittedOutput: false))
        XCTAssertFalse(ModelRouting.canFallback(ChatServiceError.incompleteResponse, emittedOutput: false))
    }
    func testAliasesAndNames() {
        XCTAssertEqual(ModelIdentity.normalizedCreator("~x-ai"), "xai")
        XCTAssertEqual(ModelIdentity.displayName(.init(id: "moonshotai/kimi", name: "MoonshotAI: Kimi"), via: .openRouter), "Kimi")
    }
    func testSearchFindsEveryOccurrence() {
        let message = ConversationMessage(conversationID: UUID(), role: .assistant, content: "Share then share again", sequence: 0)
        let result = TranscriptSearch.find("share", in: [message])
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.matches.map(\.offset), [0, 11])
        XCTAssertTrue(result.matches.allSatisfy { $0.messageID == message.id })
    }
}
