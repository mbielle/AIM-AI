@testable import AIMApplication
import ImageIO
import XCTest

/// A real 4×4 PNG (image validation decodes it).
private func tinyPNG() -> Data {
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

final class MediaAndPlanTests: XCTestCase {
    // MARK: ChatGPT plan

    func testChatGPTPlanCatalogKeepsListedModels() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list","context_window":400000},{"slug":"internal-x","display_name":"Hidden","visibility":"hide"},{"slug":"gpt-6.1-sol","display_name":"Duplicate","visibility":"list"},{"display_name":"no slug"}]}"#.utf8)
        let models = try ProviderChatService.chatGPTPlanModels(data)
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol"])
        XCTAssertEqual(models.first?.name, "GPT-6.1 Sol")
        XCTAssertEqual(models.first?.contextLength, 400_000)
        XCTAssertThrowsError(try ProviderChatService.chatGPTPlanModels(Data("{}".utf8)))
    }

    func testChatGPTPlanIsTheDefaultRouteForGPTModels() throws {
        let catalogs: [ChatProvider: [ChatModel]] = [
            .openRouter: [ChatModel(id: "openai/gpt-6.1-sol", name: "GPT")],
            .openAI: [ChatModel(id: "gpt-6.1-sol", name: "GPT")],
            .chatgpt: [ChatModel(id: "gpt-6.1-sol", name: "GPT")],
        ]
        let entry = try XCTUnwrap(ModelRouting.entries(catalogs).first)
        XCTAssertEqual(entry.routes.map(\.provider), [.chatgpt, .openAI, .openRouter])
        XCTAssertEqual(entry.provider, .chatgpt)
        // A remembered choice still wins.
        XCTAssertEqual(ModelRouting.entries(catalogs) { _ in .openAI }.first?.provider, .openAI)
    }

    func testPlanUsageUnavailableIsItsOwnError() {
        XCTAssertTrue(ChatGPTPlanAuth.isPlanUnavailable(#"{"code":"subscription_sharing_usage_unavailable"}"#))
        XCTAssertFalse(ChatGPTPlanAuth.isPlanLimit(#"{"code":"subscription_sharing_usage_unavailable"}"#))
        let stream = Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}}\n".utf8)
        XCTAssertThrowsError(try ProviderToolConversation.completedResponse(fromStream: stream)) {
            guard case .planUsageUnavailable = $0 as? ChatServiceError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Media models

    private func catalogModel(_ json: String) throws -> ChatModel {
        try JSONDecoder().decode(ChatModel.self, from: Data(json.utf8))
    }

    func testMediaModelsComeFromNonTextOutputs() throws {
        let image = try catalogModel(#"{"id":"black-forest-labs/flux-3-image","name":"Black Forest Labs: FLUX.3 Image","architecture":{"input_modalities":["text","image"],"output_modalities":["image"]}}"#)
        let video = try catalogModel(#"{"id":"bytedance/seedance-2.5","name":"ByteDance: Seedance 2.5","architecture":{"input_modalities":["text"],"output_modalities":["video"]}}"#)
        let chat = try catalogModel(#"{"id":"openai/gpt-6.1","name":"GPT","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}"#)
        XCTAssertEqual(MediaModel.from(image), MediaModel(id: "black-forest-labs/flux-3-image", name: "FLUX.3 Image", kind: .image))
        XCTAssertEqual(MediaModel.from(video)?.kind, .video)
        XCTAssertNil(MediaModel.from(chat))
        XCTAssertEqual(MediaModel.from(image)?.bflEndpoint, "flux-3-image")
        XCTAssertNil(MediaModel.from(video)?.bflEndpoint)
        XCTAssertEqual(MediaModel.from(image)?.routes(hasBFLKey: true, hasOpenRouter: true), [.blackForestLabs, .openRouter])
        XCTAssertEqual(MediaModel.from(video)?.routes(hasBFLKey: true, hasOpenRouter: true), [.openRouter])
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testFluxThreeRequests() throws {
        let reference = try ImageAttachment(name: "ref.png", mimeType: "image/png", data: tinyPNG())
        let image = MediaModel.blackForestLabs[0]
        let imageRequest = try BlackForestLabsImageService.mediaRequest(prompt: "A fox", model: image,
            options: MediaOptions(aspectRatio: "16:9", resolution: "2k", references: [reference]), apiKey: "k")
        XCTAssertEqual(imageRequest.url?.absoluteString, "https://api.bfl.ai/v1/flux-3-image")
        let imageBody = try body(imageRequest)
        XCTAssertEqual(imageBody["aspect_ratio"] as? String, "16:9")
        XCTAssertEqual(imageBody["resolution"] as? String, "2k")
        XCTAssertEqual((imageBody["images"] as? [String])?.first?.hasPrefix("data:image/png;base64,"), true)

        let video = MediaModel.blackForestLabs[1]
        let videoBody = try body(BlackForestLabsImageService.mediaRequest(prompt: "Waves", model: video,
            options: MediaOptions(durationSeconds: 40, generateAudio: false), apiKey: "k"))
        XCTAssertEqual(videoBody["mode"] as? String, "t2v")
        XCTAssertEqual(videoBody["duration"] as? Int, 20)
        XCTAssertEqual(videoBody["resolution"] as? String, "hd")
        XCTAssertEqual(videoBody["generate_audio"] as? Bool, false)
        let auto = try body(BlackForestLabsImageService.mediaRequest(prompt: "Waves", model: video, options: MediaOptions(), apiKey: "k"))
        XCTAssertEqual(auto["duration"] as? String, "auto")

        let pro = try body(BlackForestLabsImageService.mediaRequest(prompt: "x", model: MediaModel.blackForestLabs[3],
            options: MediaOptions(aspectRatio: "16:9"), apiKey: "k"))
        let width = try XCTUnwrap(pro["width"] as? Int), height = try XCTUnwrap(pro["height"] as? Int)
        XCTAssertEqual(width % 16, 0); XCTAssertEqual(height % 16, 0)
        XCTAssertEqual(Double(width) / Double(height), 16.0 / 9.0, accuracy: 0.05)
        XCTAssertThrowsError(try BlackForestLabsImageService.mediaRequest(prompt: "x", model: MediaModel(id: "x/y", name: "Y", kind: .image), options: MediaOptions(), apiKey: "k"))
    }

    func testFluxResultShapes() throws {
        XCTAssertNil(try BlackForestLabsImageService.readyMediaURL(Data(#"{"status":"Processing"}"#.utf8)))
        XCTAssertEqual(try BlackForestLabsImageService.readyMediaURL(Data(#"{"status":"Ready","result":{"video":"https://d.bfl.ai/v.mp4"}}"#.utf8))?.path, "/v.mp4")
        XCTAssertEqual(try BlackForestLabsImageService.readyMediaURL(Data(#"{"status":"Ready","result":{"sample":"https://d.bfl.ai/i.jpg"}}"#.utf8))?.path, "/i.jpg")
        XCTAssertThrowsError(try BlackForestLabsImageService.readyMediaURL(Data(#"{"status":"Request Moderated"}"#.utf8))) {
            XCTAssertEqual($0 as? MediaGenerationError, .moderated)
        }
    }

    func testOpenRouterMediaRequestsAndResults() throws {
        let image = MediaModel(id: "black-forest-labs/flux-3-image", name: "FLUX.3 Image", kind: .image)
        let imageRequest = try OpenRouterMediaService.request(prompt: "A fox", model: image, options: MediaOptions(aspectRatio: "1:1"), apiKey: "or")
        XCTAssertEqual(imageRequest.url?.absoluteString, "https://openrouter.ai/api/v1/images")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer or")
        XCTAssertEqual(try body(imageRequest)["aspect_ratio"] as? String, "1:1")

        let video = MediaModel(id: "bytedance/seedance-2.5", name: "Seedance", kind: .video)
        let videoRequest = try OpenRouterMediaService.request(prompt: "Waves", model: video, options: MediaOptions(durationSeconds: 8), apiKey: "or")
        XCTAssertEqual(videoRequest.url?.absoluteString, "https://openrouter.ai/api/v1/videos")
        XCTAssertEqual(try body(videoRequest)["duration"] as? Int, 8)
        XCTAssertNil(try body(videoRequest)["aspect_ratio"])

        let png = tinyPNG()
        let response = Data(#"{"data":[{"b64_json":"\#(png.base64EncodedString())","media_type":"image/png"}],"usage":{"cost":0.04}}"#.utf8)
        let (decoded, cost) = try OpenRouterMediaService.decodeImage(response)
        XCTAssertEqual(decoded.mimeType, "image/png")
        XCTAssertEqual(cost, "0.04")

        XCTAssertEqual(try OpenRouterMediaService.decodeVideoJob(Data(#"{"id":"abc","status":"in_progress"}"#.utf8)), .pending)
        XCTAssertEqual(try OpenRouterMediaService.decodeVideoJob(Data(#"{"id":"abc","status":"failed","error":"busy"}"#.utf8)), .failed("busy"))
        let done = try OpenRouterMediaService.decodeVideoJob(Data(#"{"id":"abc","status":"completed","unsigned_urls":["https://openrouter.ai/api/v1/videos/abc/content?index=0"],"usage":{"cost":0.25}}"#.utf8))
        XCTAssertEqual(done, .completed(URL(string: "https://openrouter.ai/api/v1/videos/abc/content?index=0")!, cost: "0.25"))
        // The key is only ever sent back to OpenRouter.
        XCTAssertThrowsError(try OpenRouterMediaService.decodeVideoJob(Data(#"{"id":"abc","status":"completed","unsigned_urls":["https://evil.example/x"]}"#.utf8)))
    }

    func testVideosArePersistedWithTheirMessage() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Media", mode: .chat)
        try await repository.save(conversation)
        let video = VideoAttachment(byteCount: 1_234, title: "FLUX.3 Video")
        try await repository.appendPair(
            ConversationMessage(conversationID: conversation.id, role: .user, content: "Waves", sequence: 0),
            ConversationMessage(conversationID: conversation.id, role: .assistant, content: "Generated", sequence: 1, videos: [video]))
        let messages = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(messages.last?.videos, [video])
        XCTAssertEqual(video.fileName, video.id.uuidString.lowercased() + ".mp4")
        XCTAssertTrue(VideoAttachment.isVideo(Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8) + Data(repeating: 0, count: 8)))
        XCTAssertFalse(VideoAttachment.isVideo(Data("<html>error</html>".utf8)))
    }
}
