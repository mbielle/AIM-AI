import Foundation

/// Black Forest Labs' FLUX models (api.bfl.ai): a request returns a polling URL; the result
/// holds a signed image URL valid ten minutes, downloaded at once. Key header: `x-key`.
public enum FluxImageModel: String, CaseIterable, Identifiable, Sendable {
    case flux2Pro = "flux-2-pro"
    case flux2Max = "flux-2-max"
    case flux2Flex = "flux-2-flex"
    case flux11Ultra = "flux-pro-1.1-ultra"
    case kontextPro = "flux-kontext-pro"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .flux2Pro: "FLUX.2 [pro]"
        case .flux2Max: "FLUX.2 [max]"
        case .flux2Flex: "FLUX.2 [flex]"
        case .flux11Ultra: "FLUX 1.1 [pro] Ultra"
        case .kontextPro: "FLUX.1 Kontext [pro]"
        }
    }
}

public struct BlackForestLabsImageService: Sendable {
    /// The Keychain name of the key (Black Forest Labs is an image provider, not a chat one).
    public static let keyName = "bfl"
    public static let keyURL = URL(string: "https://dashboard.bfl.ai/api/keys")!

    let session: URLSession
    let meter: BillableRequestMeter
    let pollInterval: Duration

    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter(), pollInterval: Duration = .milliseconds(700)) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
        self.pollInterval = pollInterval
    }

    public static func request(prompt: String, model: FluxImageModel, size: OpenAIImageSize, apiKey: String) throws -> URLRequest {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { throw OpenAIImageGenerationError.invalidPrompt }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw OpenAIImageGenerationError.missingKey }
        let dimensions = size.rawValue.split(separator: "x").compactMap { Int($0) }
        var request = URLRequest(url: URL(string: "https://api.bfl.ai/v1/\(model.rawValue)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["prompt": text, "output_format": "jpeg"]
        if dimensions.count == 2 { body["width"] = dimensions[0]; body["height"] = dimensions[1] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The image URL when the job is ready, nil while it is pending; throws when it failed.
    public static func readyImageURL(_ data: Data) throws -> URL? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenAIImageGenerationError.invalidResponse }
        switch json["status"] as? String {
        case "Ready":
            guard let sample = (json["result"] as? [String: Any])?["sample"] as? String, let url = URL(string: sample),
                  url.scheme == "https" else { throw OpenAIImageGenerationError.invalidResponse }
            return url
        case "Error", "Failed", "Content Moderated", "Request Moderated": throw OpenAIImageGenerationError.invalidResponse
        default: return nil
        }
    }

    public func generate(prompt: String, model: FluxImageModel, size: OpenAIImageSize, apiKey: String) async throws -> ImageAttachment {
        let request = try Self.request(prompt: prompt, model: model, size: size, apiKey: apiKey)
        let (data, response) = try await meter.perform(provider: Self.keyName, modelID: model.rawValue, feature: "image-generation") {
            try await session.data(for: request)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw OpenAIImageGenerationError.unavailable }
        if status == 401 || status == 403 { throw OpenAIImageGenerationError.credentialsRejected }
        if status == 429 { throw OpenAIImageGenerationError.providerRateLimited }
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let polling = (json["polling_url"] as? String).flatMap(URL.init(string:)), polling.scheme == "https" else {
            throw OpenAIImageGenerationError.unavailable
        }
        // At most about two minutes of waiting.
        for _ in 0..<170 {
            try await Task.sleep(for: pollInterval)
            var poll = URLRequest(url: polling)
            poll.setValue(apiKey, forHTTPHeaderField: "x-key")
            let (result, _) = try await session.data(for: poll)
            if let url = try Self.readyImageURL(result) {
                let (image, _) = try await session.data(from: url)
                do { return try ImageAttachment.generatedJPEG(image) }
                catch { throw OpenAIImageGenerationError.invalidResponse }
            }
        }
        throw OpenAIImageGenerationError.unavailable
    }
}
