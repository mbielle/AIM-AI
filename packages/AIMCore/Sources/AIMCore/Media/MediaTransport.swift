import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Redirects never carry a user's provider key to another origin.
private final class MediaRedirectDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 512 * 1_024 * 1_024 || totalBytesExpectedToWrite > 512 * 1_024 * 1_024 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else { completionHandler(nil); return }
        completionHandler(request)
    }
}
public struct MediaTransport: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 180
        self.session = session ?? URLSession(configuration: configuration, delegate: MediaRedirectDelegate(), delegateQueue: nil)
    }
    public func data(_ request: URLRequest) async throws -> Data {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response)
        let maximum = 96 * 1_024 * 1_024
        guard response.expectedContentLength <= maximum else { throw MediaGenerationError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw MediaGenerationError.invalidResponse }
            data.append(byte)
        }
        return data
    }
    public func download(_ request: URLRequest, kind: MediaKind) async throws -> URL {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let (file, response) = try await session.download(for: request)
        do {
            try Self.check(response)
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= (kind == .image ? 64 : 512) * 1_024 * 1_024 else { throw MediaGenerationError.invalidResponse }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaGenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MediaGenerationError.rejected(http.statusCode) }
    }
    public static func validProviderURL(_ url: URL, route: MediaRoute, download: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if route == .openRouter { return host == "openrouter.ai" && url.path.hasPrefix("/api/v1/") }
        if download { return host.hasPrefix("delivery.") && host.hasSuffix(".bfl.ai") }
        return (host == "api.bfl.ai" || host.hasSuffix(".bfl.ai")) && url.path.hasPrefix("/v1/")
    }
    public static func authorized(_ url: URL, route: MediaRoute, key: String, download: Bool = false) throws -> URLRequest {
        guard validProviderURL(url, route: route, download: download) else { throw MediaGenerationError.unsafeURL }
        var request = URLRequest(url: url, timeoutInterval: download ? 300 : 180)
        if !(download && route == .blackForestLabs) {
            request.setValue(route == .openRouter ? "Bearer " + key : key, forHTTPHeaderField: route == .openRouter ? "Authorization" : "x-key")
        }
        return request
    }
    public static func submission(_ job: MediaJob, key: String) throws -> URLRequest {
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw MediaGenerationError.missingKey }
        guard !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MediaGenerationError.invalidRequest("Describe what to create.") }
        let model = job.model, options = job.options
        if let ratio = options.aspectRatio, !model.aspectRatios.contains(ratio) { throw MediaGenerationError.invalidRequest("This model does not offer the chosen aspect ratio.") }
        if let resolution = options.resolution, !model.resolutions.contains(resolution) { throw MediaGenerationError.invalidRequest("This model does not offer the chosen resolution.") }
        if let duration = options.durationSeconds, !model.durations.contains(duration) { throw MediaGenerationError.invalidRequest("This model does not offer the chosen duration.") }
        guard options.references.isEmpty || model.acceptsReferences else { throw MediaGenerationError.invalidRequest("This model does not support reference images.") }
        guard options.generateAudio == nil || model.supportsAudio else { throw MediaGenerationError.invalidRequest("This model does not offer audio generation.") }
        let path: String
        var body: [String: Any] = ["prompt": job.prompt]
        if model.route == .openRouter {
            path = "https://openrouter.ai/api/v1/" + (model.kind == .image ? "images" : "videos")
            body["model"] = model.id
            if model.kind == .image { body["n"] = 1 }
            if let value = options.aspectRatio { body["aspect_ratio"] = value }
            if let value = options.resolution { body["resolution"] = value }
            if let value = options.durationSeconds { body["duration"] = value }
            if let value = options.generateAudio { body["generate_audio"] = value }
            if !options.references.isEmpty { body["input_references"] = options.references.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] } }
        } else {
            guard let endpoint = model.bflEndpoint, MediaModel.blackForestLabs.contains(where: { $0.bflEndpoint == endpoint }), model.kind == .image else { throw MediaGenerationError.invalidRequest("This BFL endpoint is not supported.") }
            path = "https://api.bfl.ai/v1/" + endpoint
            if let ratio = options.aspectRatio {
                let values = ratio.split(separator: ":").compactMap { Double($0) }
                guard values.count == 2, values[0] > 0, values[1] > 0 else { throw MediaGenerationError.invalidResponse }
                let height = (1_048_576 / (values[0] / values[1])).squareRoot()
                body["width"] = Int((height * values[0] / values[1] / 16).rounded()) * 16
                body["height"] = Int((height / 16).rounded()) * 16
            }
        }
        var request = try authorized(URL(string: path)!, route: model.route, key: key)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    public enum Result: Sendable { case pending(id: String, polling: URL), ready(url: URL?, bytes: Data?, cost: Double?), failed(String) }
    public static func decode(_ data: Data, job: MediaJob) throws -> Result {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaGenerationError.invalidResponse }
        let rawCost = (json["usage"] as? [String: Any])?["cost"]
        let cost = (rawCost as? NSNumber)?.doubleValue ?? (rawCost as? String).flatMap(Double.init)
        let validCost = cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if job.model.route == .openRouter && job.model.kind == .image {
            guard let item = (json["data"] as? [[String: Any]])?.first, let encoded = item["b64_json"] as? String,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { throw MediaGenerationError.invalidResponse }
            return .ready(url: nil, bytes: bytes, cost: validCost)
        }
        let status = json["status"] as? String
        if ["failed", "cancelled", "expired", "Error", "Failed", "Content Moderated", "Request Moderated", "Task not found"].contains(status ?? "") {
            return .failed("The provider stopped this generation (\(status ?? "failed")).")
        }
        if status == "completed" || status == "Ready" {
            let raw = job.model.route == .openRouter ? (json["unsigned_urls"] as? [String])?.first : (json["result"] as? [String: Any])?["sample"] as? String
            guard let raw, let url = URL(string: raw), validProviderURL(url, route: job.model.route, download: true) else { throw MediaGenerationError.unsafeURL }
            return .ready(url: url, bytes: nil, cost: validCost)
        }
        guard status == nil || ["pending", "in_progress", "queued", "Pending", "Processing"].contains(status!) else { throw MediaGenerationError.invalidResponse }
        guard let id = (json["id"] as? String) ?? job.providerJobID, !id.isEmpty,
              let polling = (json["polling_url"] as? String).flatMap(URL.init(string:)) ?? job.pollingURL,
              validProviderURL(polling, route: job.model.route) else { throw MediaGenerationError.invalidResponse }
        return .pending(id: id, polling: polling)
    }
    public static func catalog(_ data: Data, kind: MediaKind) throws -> [MediaModel] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["data"] as? [[String: Any]] else { throw MediaGenerationError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let parameters = row["supported_parameters"] as? [String: [String: Any]] ?? [:]
            func values(_ key: String) -> [String] { parameters[key]?["values"] as? [String] ?? [] }
            let skus = row["pricing_skus"] as? [String: String] ?? [:]
            return MediaModel(id: id, name: row["name"] as? String ?? id, kind: kind, route: .openRouter,
                description: row["description"] as? String, aspectRatios: row["supported_aspect_ratios"] as? [String] ?? values("aspect_ratio"),
                resolutions: row["supported_resolutions"] as? [String] ?? values("resolution"), durations: row["supported_durations"] as? [Int] ?? [],
                acceptsReferences: parameters["input_references"] != nil || ((row["architecture"] as? [String: Any])?["input_modalities"] as? [String] ?? []).contains("image"),
                supportsAudio: parameters["generate_audio"] != nil, priceUSD: skus["per-video-second"].flatMap(Double.init), priceUnit: skus["per-video-second"] == nil ? nil : "second", fixedPrice: skus.count == 1 && skus["per-video-second"] != nil)
        }
    }
    public static func imageDetails(_ data: Data, model: MediaModel) throws -> MediaModel {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let endpoints = json["endpoints"] as? [[String: Any]] else { throw MediaGenerationError.invalidResponse }
        var result = model
        let prices = endpoints.compactMap { endpoint -> Double? in
            guard let lines = endpoint["pricing"] as? [[String: Any]], lines.count == 1, let line = lines.first,
                  line["billable"] as? String == "output_image", line["unit"] as? String == "image", line["variant"] == nil else { return nil }
            return (line["cost_usd"] as? NSNumber)?.doubleValue ?? (line["cost_usd"] as? String).flatMap(Double.init)
        }
        if let first = prices.first, first.isFinite, first >= 0, prices.count == endpoints.count, prices.allSatisfy({ $0 == first }) {
            result.priceUSD = first; result.priceUnit = "image"; result.fixedPrice = true
        }
        return result
    }
    public static func mimeType(_ prefix: Data, kind: MediaKind) throws -> String {
        if kind == .video, prefix.count >= 12, prefix.dropFirst(4).prefix(4) == Data("ftyp".utf8) { return "video/mp4" }
        if kind == .image {
            if prefix.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { return "image/png" }
            if prefix.starts(with: [0xff,0xd8,0xff]) { return "image/jpeg" }
            if prefix.starts(with: Data("RIFF".utf8)), prefix.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "image/webp" }
        }
        throw MediaGenerationError.invalidResponse
    }
}
