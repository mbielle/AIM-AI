import AIMCore
import Foundation
import ImageIO

public enum MediaKind: String, Codable, Sendable { case image, video }

/// A generated video. The `.mp4` file lives in AIM's media folder; the message keeps this.
public struct VideoAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The file name inside the media folder (`<id>.mp4`), never a path.
    public let fileName: String
    public let mimeType: String
    public let byteCount: Int
    public let title: String

    public init(id: UUID = UUID(), byteCount: Int, title: String) {
        self.id = id
        self.fileName = id.uuidString.lowercased() + ".mp4"
        self.mimeType = "video/mp4"
        self.byteCount = byteCount
        self.title = title
    }

    /// An MP4/MOV container starts with an `ftyp` box.
    public static func isVideo(_ data: Data) -> Bool {
        data.count > 12 && data[data.startIndex + 4..<data.startIndex + 8] == Data("ftyp".utf8)
    }
}

/// How AIM reaches a media model: the person's Black Forest Labs key or OpenRouter.
public enum MediaRoute: String, Sendable, CaseIterable, Identifiable {
    case blackForestLabs, openRouter
    public var id: String { rawValue }
    public var title: String { self == .blackForestLabs ? "Black Forest Labs (your key)" : "OpenRouter" }
}

/// An image or video model, named by its OpenRouter-style slug (`maker/model`).
public struct MediaModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: MediaKind

    public init(id: String, name: String, kind: MediaKind) {
        self.id = id; self.name = name; self.kind = kind
    }

    public var creator: String { String(id.split(separator: "/").first ?? "other") }

    /// The Black Forest Labs endpoint serving this model with the person's own key.
    public var bflEndpoint: String? { Self.bflEndpoints[id] }

    static let bflEndpoints: [String: String] = [
        "black-forest-labs/flux-3-image": "flux-3-image", "black-forest-labs/flux-3-video": "flux-3-video",
        "black-forest-labs/flux.2-pro": "flux-2-pro", "black-forest-labs/flux.2-max": "flux-2-max",
        "black-forest-labs/flux.2-flex": "flux-2-flex", "black-forest-labs/flux-1.1-pro-ultra": "flux-pro-1.1-ultra",
        "black-forest-labs/flux-kontext-pro": "flux-kontext-pro",
    ]

    /// Offered with a Black Forest Labs key, with or without OpenRouter.
    public static let blackForestLabs: [MediaModel] = [
        .init(id: "black-forest-labs/flux-3-image", name: "FLUX.3 Image", kind: .image),
        .init(id: "black-forest-labs/flux-3-video", name: "FLUX.3 Video", kind: .video),
        .init(id: "black-forest-labs/flux.2-max", name: "FLUX.2 [max]", kind: .image),
        .init(id: "black-forest-labs/flux.2-pro", name: "FLUX.2 [pro]", kind: .image),
        .init(id: "black-forest-labs/flux.2-flex", name: "FLUX.2 [flex]", kind: .image),
    ]

    /// A catalog model that creates images or videos (nil for chat and other models).
    public static func from(_ model: ChatModel) -> MediaModel? {
        guard let outputs = model.architecture?.outputModalities, !outputs.contains("text") else { return nil }
        let kind: MediaKind
        if outputs.contains("video") { kind = .video } else if outputs.contains("image") { kind = .image } else { return nil }
        // "Black Forest Labs: FLUX.3 Image" → "FLUX.3 Image".
        let name = model.name.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? model.name
        return MediaModel(id: model.id, name: name.isEmpty ? model.id : name, kind: kind)
    }

    public func routes(hasBFLKey: Bool, hasOpenRouter: Bool) -> [MediaRoute] {
        var result: [MediaRoute] = []
        if hasBFLKey, bflEndpoint != nil { result.append(.blackForestLabs) }
        if hasOpenRouter { result.append(.openRouter) }
        return result
    }
}

/// What the person chose for one generation.
public struct MediaOptions: Sendable, Equatable {
    public var aspectRatio: String
    /// FLUX.3 Image: 768sq, 1k, 1.5k, 2k, 4k. FLUX.3 Video: hd, fhd, qhd, uhd. OpenRouter: 720p, 1080p, 1K…
    public var resolution: String?
    public var durationSeconds: Int?
    public var generateAudio: Bool
    public var references: [ImageAttachment]

    public init(aspectRatio: String = "auto", resolution: String? = nil, durationSeconds: Int? = nil,
                generateAudio: Bool = true, references: [ImageAttachment] = []) {
        self.aspectRatio = aspectRatio; self.resolution = resolution; self.durationSeconds = durationSeconds
        self.generateAudio = generateAudio; self.references = references
    }

    /// Width and height near one megapixel (multiples of 16) for models that take pixels.
    var pixels: (width: Int, height: Int) {
        let parts = aspectRatio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (1024, 1024) }
        let ratio = parts[0] / parts[1]
        let height = (1_048_576 / ratio).squareRoot()
        func round16(_ value: Double) -> Int { max(256, min(2048, Int((value / 16).rounded()) * 16)) }
        return (round16(height * ratio), round16(height))
    }
}

public enum GeneratedMedia: Sendable {
    case image(ImageAttachment)
    case video(Data)
}

public enum MediaGenerationError: LocalizedError, Equatable, Sendable {
    case missingKey(String), invalidPrompt, credentialsRejected(String), rateLimited(String)
    case moderated, failed(String), timedOut, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "Add your \(provider) key in Settings → Providers to use this model."
        case .invalidPrompt: "Describe what to create in 1–4,000 characters."
        case .credentialsRejected(let provider): "\(provider) rejected this key or model access. Check your account."
        case .rateLimited(let provider): "\(provider) is limiting requests right now. Please try again shortly."
        case .moderated: "The provider declined this request under its content policy. Nothing was charged by AIM."
        case .failed(let reason): "The generation failed: \(reason)"
        case .timedOut: "The provider did not finish in time. It may still bill the request; check its dashboard."
        case .invalidResponse: "The provider did not return a usable result. Nothing was saved."
        }
    }
}

extension ImageAttachment {
    /// A generated image in any format ImageIO reads (PNG, JPEG, WebP…), kept as PNG/JPEG.
    public static func generated(_ data: Data) throws -> ImageAttachment {
        if data.starts(with: [0xff, 0xd8, 0xff]) { return try generatedJPEG(data) }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]), data.count <= 6_000_000 {
            return try ImageAttachment(name: "Generated image.png", mimeType: "image/png", data: data)
        }
        guard data.count <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageAttachmentError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
            throw ImageAttachmentError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageAttachmentError.invalidImage }
        return try generatedJPEG(encoded as Data)
    }
}

// MARK: Black Forest Labs

extension BlackForestLabsImageService {
    /// One FLUX request: FLUX.3 takes an aspect ratio and a resolution tier; FLUX.2 takes pixels.
    public static func mediaRequest(prompt: String, model: MediaModel, options: MediaOptions, apiKey: String) throws -> URLRequest {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { throw MediaGenerationError.invalidPrompt }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw MediaGenerationError.missingKey("Black Forest Labs") }
        guard let endpoint = model.bflEndpoint else { throw MediaGenerationError.invalidResponse }
        var body: [String: Any] = ["prompt": text]
        switch endpoint {
        case "flux-3-image":
            body["aspect_ratio"] = options.aspectRatio
            body["resolution"] = options.resolution ?? "1k"
            if !options.references.isEmpty { body["images"] = options.references.prefix(10).map(\.dataURL) }
        case "flux-3-video":
            body["mode"] = options.references.isEmpty ? "t2v" : "i2v"
            body["aspect_ratio"] = options.aspectRatio
            body["resolution"] = options.resolution ?? "hd"
            body["duration"] = options.durationSeconds.map { max(5, min(20, $0)) as Any } ?? "auto"
            body["generate_audio"] = options.generateAudio
            if !options.references.isEmpty { body["keyframes"] = options.references.prefix(10).map(\.dataURL) }
        default:
            let size = options.pixels
            body["width"] = size.width; body["height"] = size.height
            body["output_format"] = "jpeg"
            if let first = options.references.first { body["input_image"] = first.data.base64EncodedString() }
        }
        var request = URLRequest(url: URL(string: "https://api.bfl.ai/v1/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The result URL when ready, nil while pending (images: `result.sample`; videos may use other keys).
    public static func readyMediaURL(_ data: Data) throws -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaGenerationError.invalidResponse }
        switch json["status"] as? String {
        case "Ready":
            let result = json["result"] as? [String: Any] ?? [:]
            let candidates: [Any?] = [result["sample"], result["video"], result["url"], (result["videos"] as? [Any])?.first,
                                      (result["sample"] as? [Any])?.first]
            guard let text = candidates.compactMap({ $0 as? String }).first, let url = URL(string: text), url.scheme == "https" else {
                throw MediaGenerationError.invalidResponse
            }
            return url
        case "Content Moderated", "Request Moderated": throw MediaGenerationError.moderated
        case "Error", "Failed": throw MediaGenerationError.failed((json["details"] as? String) ?? "Black Forest Labs reported an error.")
        default: return nil
        }
    }

    public func generate(prompt: String, model: MediaModel, options: MediaOptions, apiKey: String) async throws -> GeneratedMedia {
        let request = try Self.mediaRequest(prompt: prompt, model: model, options: options, apiKey: apiKey)
        let feature = model.kind == .video ? "video-generation" : "image-generation"
        let (data, response) = try await meter.perform(provider: Self.keyName, modelID: model.id, feature: feature) {
            try await session.data(for: request)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw MediaGenerationError.invalidResponse }
        if status == 401 || status == 403 { throw MediaGenerationError.credentialsRejected("Black Forest Labs") }
        if status == 429 { throw MediaGenerationError.rateLimited("Black Forest Labs") }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let polling = (json["polling_url"] as? String).flatMap(URL.init(string:)), polling.scheme == "https" else {
            throw MediaGenerationError.failed(Self.message(data) ?? "HTTP \(status)")
        }
        // Images take seconds; a video can take several minutes.
        let interval: Duration = model.kind == .video ? .seconds(3) : pollInterval
        let attempts = model.kind == .video ? 200 : 170
        for _ in 0..<attempts {
            try await Task.sleep(for: interval)
            var poll = URLRequest(url: polling)
            poll.setValue(apiKey, forHTTPHeaderField: "x-key")
            let (result, _) = try await session.data(for: poll)
            if let url = try Self.readyMediaURL(result) {
                let (file, _) = try await session.data(from: url)
                if model.kind == .video {
                    guard VideoAttachment.isVideo(file) else { throw MediaGenerationError.invalidResponse }
                    return .video(file)
                }
                do { return .image(try ImageAttachment.generated(file)) } catch { throw MediaGenerationError.invalidResponse }
            }
        }
        throw MediaGenerationError.timedOut
    }

    static func message(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? String { return detail }
        if let detail = (json["detail"] as? [[String: Any]])?.first?["msg"] as? String { return detail }
        return ((json["error"] as? [String: Any])?["message"] as? String) ?? json["message"] as? String
    }
}

// MARK: OpenRouter

/// OpenRouter's media APIs: `POST /api/v1/images` (base64 result) and the asynchronous
/// `POST /api/v1/videos` job, polled until `completed`, then downloaded with the key.
public struct OpenRouterMediaService: Sendable {
    public static let base = "https://openrouter.ai/api/v1"
    private let session: URLSession
    private let meter: BillableRequestMeter
    private let pollInterval: Duration

    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter(), pollInterval: Duration = .seconds(3)) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
        self.pollInterval = pollInterval
    }

    public static func request(prompt: String, model: MediaModel, options: MediaOptions, apiKey: String) throws -> URLRequest {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { throw MediaGenerationError.invalidPrompt }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw MediaGenerationError.missingKey("OpenRouter") }
        var body: [String: Any] = ["model": model.id, "prompt": text]
        if options.aspectRatio != "auto" { body["aspect_ratio"] = options.aspectRatio }
        if let resolution = options.resolution { body["resolution"] = resolution }
        let path: String
        if model.kind == .video {
            path = "/videos"
            if let duration = options.durationSeconds { body["duration"] = duration }
            body["generate_audio"] = options.generateAudio
            if let first = options.references.first {
                body["frame_images"] = [["type": "image_url", "image_url": ["url": first.dataURL], "frame_type": "first_frame"]]
            }
        } else {
            path = "/images"
            body["output_format"] = "jpeg"
        }
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: model.kind == .video ? 60 : 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AIM AI", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The first image of an `/images` response and its reported cost.
    public static func decodeImage(_ data: Data) throws -> (ImageAttachment, cost: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first,
              let encoded = first["b64_json"] as? String, let bytes = Data(base64Encoded: encoded) else {
            throw MediaGenerationError.invalidResponse
        }
        let image: ImageAttachment
        do { image = try ImageAttachment.generated(bytes) } catch { throw MediaGenerationError.invalidResponse }
        return (image, cost(json))
    }

    public enum VideoJob: Equatable, Sendable { case pending, completed(URL, cost: String?), failed(String) }

    /// One video job state (submit or poll response).
    public static func decodeVideoJob(_ data: Data, id fallbackID: String? = nil) throws -> VideoJob {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaGenerationError.invalidResponse }
        switch json["status"] as? String {
        case "completed":
            let id = (json["id"] as? String) ?? fallbackID
            let listed = (json["unsigned_urls"] as? [String])?.first.flatMap(URL.init(string:))
            guard let url = listed ?? id.flatMap({ URL(string: base + "/videos/\($0)/content?index=0") }),
                  url.scheme == "https", url.host == "openrouter.ai" else { throw MediaGenerationError.invalidResponse }
            return .completed(url, cost: cost(json))
        case "failed", "cancelled", "expired":
            return .failed((json["error"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "OpenRouter reported a failure.")
        case "pending", "in_progress", "queued", nil: return .pending
        default: return .pending
        }
    }

    private static func cost(_ json: [String: Any]) -> String? {
        guard let value = (json["usage"] as? [String: Any])?["cost"] else { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String
    }

    public func generate(prompt: String, model: MediaModel, options: MediaOptions, apiKey: String) async throws -> GeneratedMedia {
        let request = try Self.request(prompt: prompt, model: model, options: options, apiKey: apiKey)
        let session = session, pollInterval = pollInterval
        let feature = model.kind == .video ? "video-generation" : "image-generation"
        let result: (GeneratedMedia, String?) = try await meter.perform(
            provider: ChatProvider.openRouter.rawValue, modelID: model.id, feature: feature, receiptUSD: { $0.1 }) {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw MediaGenerationError.credentialsRejected("OpenRouter") }
            if status == 402 { throw MediaGenerationError.failed("your OpenRouter account needs credits.") }
            if status == 429 { throw MediaGenerationError.rateLimited("OpenRouter") }
            guard (200..<300).contains(status) else {
                throw MediaGenerationError.failed(BlackForestLabsImageService.message(data) ?? "HTTP \(status)")
            }
            if model.kind == .image {
                let (image, cost) = try Self.decodeImage(data)
                return (.image(image), cost)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String,
                  !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else {
                throw MediaGenerationError.invalidResponse
            }
            let polling = URL(string: Self.base + "/videos/" + id)!
            // Up to fifteen minutes; the job keeps running at OpenRouter if AIM stops waiting.
            for _ in 0..<300 {
                var poll = URLRequest(url: polling)
                poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (state, _) = try await session.data(for: poll)
                switch try Self.decodeVideoJob(state, id: id) {
                case .pending: try await Task.sleep(for: pollInterval)
                case .failed(let reason): throw MediaGenerationError.failed(reason)
                case .completed(let url, let cost):
                    var download = URLRequest(url: url, timeoutInterval: 300)
                    download.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    let (file, _) = try await session.data(for: download)
                    guard VideoAttachment.isVideo(file) else { throw MediaGenerationError.invalidResponse }
                    return (.video(file), cost)
                }
            }
            throw MediaGenerationError.timedOut
        }
        return result.0
    }
}
