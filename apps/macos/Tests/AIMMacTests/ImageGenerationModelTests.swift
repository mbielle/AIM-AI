@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation
import ImageIO
import XCTest

@MainActor
final class ImageGenerationModelTests: XCTestCase {
    func testGenerateUsesOpenAIKeyButDoesNotChangeSelectedChatProviderOrDraft() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let keys = EphemeralProviderKeyStore()
        let model = AppModel(database: database, conversationRepository: repository, providerStore: keys,
                             imageGenerator: TestImageGenerator())
        try keys.store(Data("test-key".utf8), forKey: ProfileScopedCredentialStore.prefix(try XCTUnwrap(model.account.identity?.storageID)) + ChatProvider.openAI.rawValue)
        model.selectedProvider = .anthropic
        model.selectedModelID = "claude-fixture"
        model.composerText = "Keep this draft"
        try await model.generateImage(prompt: "A black star", model: .flare,
                                      size: .square, quality: .medium)
        let id = try XCTUnwrap(model.selectedConversationID)
        let saved = try await repository.messages(conversationID: id)
        XCTAssertEqual(saved.map(\.role), [.user, .assistant])
        XCTAssertEqual(saved.first?.content, "A black star")
        XCTAssertEqual(saved.last?.images?.count, 1)
        XCTAssertEqual(model.messages.map(\.id), saved.map(\.id))
        XCTAssertEqual(model.selectedProvider, .anthropic)
        let storedConversation = try await repository.conversation(id: id)
        let conversation = try XCTUnwrap(storedConversation)
        XCTAssertEqual(conversation.provider, .anthropic)
        XCTAssertEqual(conversation.modelID, "claude-fixture")
        await model.newConversation()
        XCTAssertEqual(model.composerText, "Keep this draft")
    }
    func testMissingKeyDoesNotCreateConversationOrDiscardPrompt() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let keys = EphemeralProviderKeyStore()
        let model = AppModel(database: database, conversationRepository: repository, providerStore: keys,
                             imageGenerator: TestImageGenerator())
        model.composerText = "Unsaved ordinary chat draft"
        do {
            try await model.generateImage(prompt: "A star", model: .flare,
                                          size: .square, quality: .low)
            XCTFail("Missing key accepted")
        } catch OpenAIImageGenerationError.missingKey { }
        let conversations = try await repository.list(includeArchived: false)
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertEqual(model.composerText, "Unsaved ordinary chat draft")
    }

    func testCancellationLeavesNoConversation() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let keys = EphemeralProviderKeyStore()
        let model = AppModel(database: database, conversationRepository: repository, providerStore: keys,
                             imageGenerator: SlowImageGenerator())
        try keys.store(Data("test-key".utf8), forKey: ProfileScopedCredentialStore.prefix(try XCTUnwrap(model.account.identity?.storageID)) + ChatProvider.openAI.rawValue)
        var outcome: Result<Void, Error>?
        let generation = Task {
            do {
                try await model.generateImage(prompt: "A black star", model: .flare,
                                              size: .square, quality: .medium)
                outcome = .success(())
            } catch { outcome = .failure(error); throw error }
        }
        defer { generation.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !model.isGeneratingImage && outcome == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if let outcome { try outcome.get(); return XCTFail("Generation ended before cancellation") }
        guard model.isGeneratingImage else { return XCTFail("Generation did not start within three seconds") }
        model.cancelImageGeneration()
        do { try await generation.value; XCTFail("Cancelled generation completed") }
        catch is CancellationError { }
        let conversations = try await repository.list(includeArchived: false)
        XCTAssertTrue(conversations.isEmpty)
        XCTAssertFalse(model.isGeneratingImage)
    }
}

private struct TestImageGenerator: ImageGenerating {
    func generate(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                  quality: OpenAIImageQuality, apiKey: String) async throws -> ImageAttachment {
        guard apiKey == "test-key", prompt == "A black star" else { throw OpenAIImageGenerationError.invalidPrompt }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        return try ImageAttachment(name: "star.png", mimeType: "image/png", data: png)
    }
}

private struct SlowImageGenerator: ImageGenerating {
    func generate(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                  quality: OpenAIImageQuality, apiKey: String) async throws -> ImageAttachment {
        try await Task.sleep(for: .seconds(30))
        throw OpenAIImageGenerationError.invalidResponse
    }
}
