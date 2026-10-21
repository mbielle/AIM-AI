import Foundation
import ImageIO
import XCTest
@testable import AIMApplication

final class ImageAttachmentTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private func fixture() throws -> ImageAttachment {
        try ImageAttachment(name: "pixel.png", mimeType: "image/png", data: png)
    }

    func testRejectsSpoofedAndOversizedImages() throws {
        XCTAssertThrowsError(try ImageAttachment(name: "fake.png", mimeType: "image/png", data: Data("not an image".utf8)))
        XCTAssertThrowsError(try ImageAttachment(name: "pixel.png", mimeType: "image/jpeg", data: png))
        let image = try fixture()
        XCTAssertThrowsError(try ImageAttachment.validate([image, image]))
    }

    func testHEICImportProducesValidatedMetadataFreeJPEG() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let pixel = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try (encoded as Data).write(to: url)

        let attachment = try ImageAttachment.read(url)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.name, url.deletingPathExtension().lastPathComponent + ".jpg")
        XCTAssertTrue(attachment.data.starts(with: [0xff, 0xd8, 0xff]))
        XCTAssertLessThanOrEqual(attachment.data.count, 6_000_000)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)

        let spoofed = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: spoofed) }
        try png.write(to: spoofed)
        XCTAssertThrowsError(try ImageAttachment.read(spoofed))
    }

    func testAllSupportedProvidersReceiveActualImageBytes() throws {
        let id = UUID()
        let image = try fixture()
        let message = ConversationMessage(conversationID: id, role: .user, content: "Describe this", sequence: 0, images: [image])
        for provider in [ChatProvider.openAI, .xAI, .perplexity, .anthropic, .google, .openRouter] {
            let request = try ProviderChatService.request(provider: provider, modelID: "vision-test", messages: [message], apiKey: "test-key", mode: .chat, catalogMaximumOutputTokens: 4096)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let parts: [[String: Any]]
            switch provider {
            case .openAI, .xAI, .perplexity:
                let input = try XCTUnwrap(root["input"] as? [[String: Any]])
                parts = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
                XCTAssertEqual(parts.last?["type"] as? String, "input_image")
                XCTAssertEqual(parts.last?["image_url"] as? String, image.dataURL)
            case .anthropic:
                let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
                parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                let source = try XCTUnwrap(parts[0]["source"] as? [String: Any])
                XCTAssertEqual(source["data"] as? String, png.base64EncodedString())
                XCTAssertEqual(source["media_type"] as? String, "image/png")
            case .google:
                let contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
                parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
                let inline = try XCTUnwrap(parts[0]["inline_data"] as? [String: Any])
                XCTAssertEqual(inline["data"] as? String, png.base64EncodedString())
            case .openRouter:
                let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
                parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                let url = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
                XCTAssertEqual(url["url"] as? String, image.dataURL)
            default: XCTFail("\(provider) should not be in this loop")
            }
        }
        XCTAssertThrowsError(try ProviderChatService.request(provider: .deepSeek, modelID: "deepseek-chat", messages: [message], apiKey: "test-key", mode: .chat, catalogMaximumOutputTokens: 4096))
        let later = ConversationMessage(conversationID: id, role: .user, content: "Continue in text", sequence: 1)
        let deepSeek = try ProviderChatService.request(provider: .deepSeek, modelID: "deepseek-chat", messages: [message, later], apiKey: "test-key", mode: .chat, catalogMaximumOutputTokens: 4096)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(deepSeek.httpBody)) as? [String: Any])
        let wire = try XCTUnwrap(root["messages"] as? [[String: String]])
        XCTAssertTrue(wire[0]["content", default: ""].contains("cannot be sent"))
    }

    func testGeneratedAssistantImageStaysLocalUntilUserReattachesIt() throws {
        let id = UUID()
        let image = try fixture()
        let generated = ConversationMessage(conversationID: id, role: .assistant,
                                            content: "Created with OpenAI", sequence: 0, images: [image])
        let followUp = ConversationMessage(conversationID: id, role: .user,
                                           content: "Describe the result", sequence: 1)
        let request = try ProviderChatService.request(provider: .openAI, modelID: "fixture",
                                                      messages: [generated, followUp], apiKey: "fixture", mode: .chat)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains(image.data.base64EncodedString()))
        XCTAssertTrue(body.contains("generated image(s) are saved locally"))
        let reattached = ConversationMessage(conversationID: id, role: .user, content: "Now inspect it",
                                             sequence: 2, images: [image])
        let withAttachment = try ProviderChatService.request(provider: .openAI, modelID: "fixture",
                                                             messages: [generated, reattached], apiKey: "fixture", mode: .chat)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(withAttachment.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(wire["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        XCTAssertTrue(content.contains { ($0["image_url"] as? String)?.contains(image.data.base64EncodedString()) == true })
    }

    func testImageOnlyMessageContainsNoEmptyTextPartInProviderRequests() throws {
        let message = ConversationMessage(conversationID: UUID(), role: .user, content: "", sequence: 0,
                                          images: [try fixture()])
        for provider in [ChatProvider.openAI, .xAI, .perplexity, .anthropic, .google, .openRouter] {
            let request = try ProviderChatService.request(provider: provider, modelID: "vision-test",
                                                          messages: [message], apiKey: "test-key", mode: .chat, catalogMaximumOutputTokens: 4096)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let parts: [[String: Any]]
            if provider == .openAI || provider == .xAI || provider == .perplexity {
                let input = try XCTUnwrap(root["input"] as? [[String: Any]])
                parts = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
                XCTAssertEqual(parts.first?["type"] as? String, "input_image")
            } else if provider == .google {
                let input = try XCTUnwrap(root["contents"] as? [[String: Any]])
                parts = try XCTUnwrap(input.first?["parts"] as? [[String: Any]])
                XCTAssertNotNil(parts.first?["inline_data"])
            } else {
                let input = try XCTUnwrap(root["messages"] as? [[String: Any]])
                parts = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
                XCTAssertEqual(parts.first?["type"] as? String, provider == .anthropic ? "image" : "image_url")
            }
            XCTAssertEqual(parts.count, 1, "\(provider) should send only the image part")
        }
    }

    func testImageSurvivesDatabaseDraftAndBranch() async throws {
        let database = try AIMDatabase(inMemory: true)
        let store = ComposerDraftStore(database: database)
        let image = try fixture()
        let draft = ComposerDraft(text: "Unsent", images: [image])
        try store.save(draft, key: "image-test")
        XCTAssertEqual(try store.load(key: "image-test"), draft)

        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Image")
        try await repository.save(conversation)
        let message = ConversationMessage(conversationID: conversation.id, role: .user, content: "Look", sequence: 0, images: [image])
        try await repository.append(message)
        let loaded = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(loaded.first?.images, [image])
        let branch = try ConversationBranch(source: conversation, messages: loaded, at: message.id, includingMessage: true)
        XCTAssertEqual(branch.messages.first?.images, [image])
    }

    func testOldImagesAreOmittedFromOversizedRequestButSavedHistoryIsUnchanged() throws {
        let id = UUID()
        let history = try (0..<3).map { index in
            ConversationMessage(conversationID: id, role: .user, content: "Image \(index)", sequence: index,
                                images: [try ImageAttachment(name: "\(index).png", mimeType: "image/png", data: png)])
        }
        let prepared = try ImageMessageEncoding.prepare(history, provider: .openAI, maxPayloadBytes: Int64(png.count * 2))
        XCTAssertNil(prepared[0].images)
        XCTAssertTrue(prepared[0].content.contains("omitted"))
        XCTAssertEqual(prepared[1].images?.count, 1)
        XCTAssertEqual(prepared[2].images?.count, 1)
        XCTAssertEqual(history[0].images?.count, 1)
    }
}
