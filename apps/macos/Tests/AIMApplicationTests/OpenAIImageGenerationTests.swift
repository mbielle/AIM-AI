import AIMApplication
import ImageIO
import XCTest

private final class ImageGenerationFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization")
        let status = key == "Bearer denied" ? 401 : key == "Bearer throttled" ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
            let source = CGImageSourceCreateWithData(png as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let jpeg = NSMutableData()
            let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let bytes = key == "Bearer oversized" ? (jpeg as Data) + Data(repeating: 0, count: 6_100_000) : jpeg as Data
            let payload = try! JSONSerialization.data(withJSONObject: ["data": [["b64_json": bytes.base64EncodedString()]]])
            client?.urlProtocol(self, didLoad: payload)
        } else {
            client?.urlProtocol(self, didLoad: Data(#"{"error":"private provider text"}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenAIImageGenerationTests: XCTestCase {
    private func service() -> OpenAIImageGenerationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageGenerationFixture.self]
        return OpenAIImageGenerationService(session: URLSession(configuration: config))
    }

    func testRequestIsDirectAndUsesBYOKWithoutExtraQuota() throws {
        let request = try OpenAIImageGenerationService.request(prompt: "  A monochrome star  ", model: .flare,
                                                                size: .square, quality: .medium, apiKey: "fixture-key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-image-2.5-flare")
        XCTAssertEqual(body["prompt"] as? String, "A monochrome star")
        XCTAssertEqual(body["size"] as? String, "1024x1024")
        XCTAssertEqual(body["quality"] as? String, "medium")
        XCTAssertEqual(body["output_format"] as? String, "jpeg")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("fixture-key"))
        XCTAssertThrowsError(try OpenAIImageGenerationService.request(prompt: "", model: .flare, size: .square,
                                                                        quality: .medium, apiKey: "fixture-key"))
        XCTAssertThrowsError(try OpenAIImageGenerationService.request(prompt: "A star", model: .flare, size: .square,
                                                                        quality: .medium, apiKey: "bad\nkey"))
    }

    func testGeneratedImageIsValidatedAndProviderErrorsArePrivate() async throws {
        let image = try await service().generate(prompt: "A star", model: .sunburst, size: .portrait,
                                                  quality: .low, apiKey: "fixture-key")
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertTrue(image.data.starts(with: [0xff, 0xd8, 0xff]))
        do {
            _ = try await service().generate(prompt: "A star", model: .flare, size: .square,
                                             quality: .low, apiKey: "denied")
            XCTFail("Rejected key accepted")
        } catch OpenAIImageGenerationError.credentialsRejected {}
        do {
            _ = try await service().generate(prompt: "A star", model: .flare, size: .square,
                                             quality: .low, apiKey: "throttled")
            XCTFail("Rate limit accepted")
        } catch OpenAIImageGenerationError.providerRateLimited {}
        XCTAssertFalse(OpenAIImageGenerationError.providerRateLimited.localizedDescription.contains("private provider text"))
    }

    func testValidLargeJPEGIsReencodedLocallyInsteadOfDiscarded() async throws {
        let image = try await service().generate(prompt: "A star", model: .sunburst, size: .landscape,
                                                  quality: .high, apiKey: "oversized")
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(image.data.count, 6_000_000)
        XCTAssertTrue(image.data.starts(with: [0xff, 0xd8, 0xff]))
    }

    func testGeneratedPromptAndAssistantImagePersistAtomically() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "A star")
        try await repository.save(conversation)
        let image = try await service().generate(prompt: "A star", model: .flare, size: .square,
                                                  quality: .low, apiKey: "fixture-key")
        let prompt = ConversationMessage(conversationID: conversation.id, role: .user, content: "A star", sequence: 0)
        let result = ConversationMessage(conversationID: conversation.id, role: .assistant,
                                         content: "Created with OpenAI · Flare", sequence: 1, images: [image])
        try await repository.appendPair(prompt, result)
        let saved = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(saved.map(\.id), [prompt.id, result.id])
        XCTAssertEqual(saved.last?.images, [image])

        let retryPrompt = ConversationMessage(conversationID: conversation.id, role: .user, content: "Try again", sequence: 2)
        let duplicateResult = ConversationMessage(id: result.id, conversationID: conversation.id, role: .assistant,
                                                  content: "Duplicate", sequence: 3, images: [image])
        do { try await repository.appendPair(retryPrompt, duplicateResult); XCTFail("Duplicate result was accepted") }
        catch { }
        let afterFailure = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(afterFailure.map(\.id), [prompt.id, result.id])
    }
}
