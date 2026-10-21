import AIMCore
import Foundation

public enum OpenAIImageModel: String, CaseIterable, Identifiable, Sendable {
    case flare = "gpt-image-2.5-flare"
    case sunburst = "gpt-image-2.5-sunburst"

    public var id: String { rawValue }
    public var title: String { self == .flare ? "Flare · fast" : "Sunburst · precise" }
}

public enum OpenAIImageSize: String, CaseIterable, Identifiable, Sendable {
    case square = "1024x1024"
    case landscape = "1536x1024"
    case portrait = "1024x1536"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .square: "Square · 1024 × 1024"
        case .landscape: "Landscape · 1536 × 1024"
        case .portrait: "Portrait · 1024 × 1536"
        }
    }
}

public enum OpenAIImageQuality: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum OpenAIImageGenerationError: LocalizedError, Sendable {
    case missingKey, invalidPrompt, credentialsRejected, providerRateLimited, unavailable, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenAI API key in Settings → Providers to generate images."
        case .invalidPrompt: "Describe the image in 1–4,000 characters."
        case .credentialsRejected: "OpenAI rejected this API key or image-model access. Check your account and key."
        case .providerRateLimited: "OpenAI limited this key temporarily. AIM does not add an image-generation quota."
        case .unavailable: "Image generation is unavailable. Check your connection and OpenAI account."
        case .invalidResponse: "OpenAI did not return a usable image. Nothing was saved."
        }
    }
}

public protocol ImageGenerating: Sendable {
    func generate(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                  quality: OpenAIImageQuality, apiKey: String) async throws -> ImageAttachment
}

/// Direct Images API request. The supplied BYOK key is never stored in the request body.
public struct OpenAIImageGenerationService: ImageGenerating {
    private let session: URLSession
    private let meter: BillableRequestMeter
    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter()) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
    }

    public static func request(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                               quality: OpenAIImageQuality, apiKey: String) throws -> URLRequest {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000, text.utf8.count <= 16_000 else {
            throw OpenAIImageGenerationError.invalidPrompt
        }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            throw OpenAIImageGenerationError.missingKey
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.rawValue, "prompt": text, "size": size.rawValue,
            "quality": quality.rawValue, "output_format": "jpeg", "n": 1
        ])
        return request
    }

    public func generate(prompt: String, model: OpenAIImageModel, size: OpenAIImageSize,
                         quality: OpenAIImageQuality, apiKey: String) async throws -> ImageAttachment {
        let request = try Self.request(prompt: prompt, model: model, size: size, quality: quality, apiKey: apiKey)
        let (data, response) = try await meter.perform(provider: ChatProvider.openAI.rawValue,
            modelID: model.rawValue, feature: "image-generation") {
            try await session.data(for: request)
        }
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw OpenAIImageGenerationError.unavailable }
        if status == 401 || status == 403 { throw OpenAIImageGenerationError.credentialsRejected }
        if status == 429 { throw OpenAIImageGenerationError.providerRateLimited }
        guard (200..<300).contains(status) else { throw OpenAIImageGenerationError.unavailable }
        // A 15 MB JPEG expands to roughly 20 MB as base64 before JSON framing.
        guard data.count <= 22_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["data"] as? [[String: Any]], images.count == 1,
              let encoded = images[0]["b64_json"] as? String,
              let decoded = Data(base64Encoded: encoded), !decoded.isEmpty else {
            throw OpenAIImageGenerationError.invalidResponse
        }
        do { return try ImageAttachment.generatedJPEG(decoded) }
        catch { throw OpenAIImageGenerationError.invalidResponse }
    }
}
