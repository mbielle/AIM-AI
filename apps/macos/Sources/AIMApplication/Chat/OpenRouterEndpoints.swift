import AIMCore
import Foundation

/// One host serving a model on OpenRouter (public `/models/{id}/endpoints`, no key).
public struct OpenRouterEndpoint: Decodable, Sendable, Identifiable, Equatable {
    public let name: String
    public let providerName: String
    public let tag: String?
    public let contextLength: Int?
    public let maxCompletionTokens: Int?
    public let quantization: String?
    public let pricing: ChatModel.Pricing?
    public let uptime5m: Double?
    public let uptime30m: Double?
    public let uptime1d: Double?
    public let status: Int?
    public var id: String { tag ?? name }

    enum CodingKeys: String, CodingKey {
        case name, tag, quantization, pricing, status
        case providerName = "provider_name"
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
        case uptime5m = "uptime_last_5m"
        case uptime30m = "uptime_last_30m"
        case uptime1d = "uptime_last_1d"
    }
}

public enum OpenRouterEndpoints {
    public static func fetch(modelID: String, session: URLSession = RuntimeManagedNetworkSession.shared) async throws -> [OpenRouterEndpoint] {
        let id = modelID.split(separator: ":").first.map(String.init) ?? modelID
        guard id.range(of: #"^[a-z0-9~._-]+/[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://openrouter.ai/api/v1/models/\(id)/endpoints") else { throw ChatServiceError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatServiceError.invalidResponse }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> [OpenRouterEndpoint] {
        struct Root: Decodable { struct Inner: Decodable { let endpoints: [OpenRouterEndpoint] }; let data: Inner }
        return try JSONDecoder().decode(Root.self, from: data).data.endpoints
    }
}

/// What AIM has observed about models over time, kept 30 days on this Mac: hourly uptime
/// of OpenRouter hosts, and the speed of AIM's own responses (time to first word, words/s).
public actor ModelStatsStore {
    public static let shared = ModelStatsStore()

    public struct UptimeSample: Codable, Equatable, Sendable {
        public let model: String
        public let host: String
        public let date: Date
        public let uptime: Double
    }

    public struct SpeedSample: Codable, Equatable, Sendable {
        public let model: String
        public let provider: String
        public let date: Date
        public let firstTokenSeconds: Double
        public let tokensPerSecond: Double
        /// Local engines: prompt processing speed and which engine ran ("mlx", "llama.cpp").
        public var promptTokensPerSecond: Double?
        public var engine: String?
    }

    private struct File: Codable {
        var uptime: [UptimeSample] = []
        var speed: [SpeedSample] = []
        var lastUptimeFetch: [String: Date] = [:]
    }

    private let url: URL
    private var file: File?
    private let retention: TimeInterval = 30 * 86_400

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AIMInstallationContext.legacyDirectoryName + "/ModelStats.json")) {
        self.url = url
    }

    private func load() -> File {
        if let file { return file }
        let loaded = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File()
        file = loaded
        return loaded
    }

    private func save(_ value: File) {
        var value = value
        let cutoff = Date.now.addingTimeInterval(-retention)
        value.uptime = Array(value.uptime.filter { $0.date > cutoff }.suffix(20_000))
        value.speed = Array(value.speed.filter { $0.date > cutoff }.suffix(5_000))
        file = value
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    /// Records the hosts' current uptime, at most once an hour per model.
    public func recordUptime(model: String, endpoints: [OpenRouterEndpoint], now: Date = .now) {
        var value = load()
        if let last = value.lastUptimeFetch[model], now.timeIntervalSince(last) < 3_600 { return }
        value.lastUptimeFetch[model] = now
        for endpoint in endpoints {
            if let uptime = endpoint.uptime30m ?? endpoint.uptime1d {
                value.uptime.append(UptimeSample(model: model, host: endpoint.providerName, date: now, uptime: uptime))
            }
        }
        save(value)
    }

    public func needsUptime(model: String, now: Date = .now) -> Bool {
        guard let last = load().lastUptimeFetch[model] else { return true }
        return now.timeIntervalSince(last) >= 3_600
    }

    public func recordSpeed(model: String, provider: String, firstTokenSeconds: Double, tokensPerSecond: Double,
                            promptTokensPerSecond: Double? = nil, engine: String? = nil, now: Date = .now) {
        guard firstTokenSeconds.isFinite, tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        var value = load()
        value.speed.append(SpeedSample(model: model, provider: provider, date: now,
                                       firstTokenSeconds: firstTokenSeconds, tokensPerSecond: tokensPerSecond,
                                       promptTokensPerSecond: promptTokensPerSecond?.isFinite == true ? promptTokensPerSecond : nil,
                                       engine: engine))
        save(value)
    }

    public func uptime(model: String) -> [UptimeSample] { load().uptime.filter { $0.model == model } }
    public func speed(model: String) -> [SpeedSample] { load().speed.filter { $0.model == model } }

    /// Measurements of local models whose name starts like `repo` ("Qwen/Qwen3-8B-GGUF" matches
    /// "Qwen3-8B-4bit" and "Qwen3-8B-Q4_K_M"): the same model, whatever its format.
    public func localSpeed(repo: String) -> [SpeedSample] {
        let key = Self.localKey(repo)
        guard key.count >= 3 else { return [] }
        return load().speed.filter { $0.provider == "local" && Self.localKey($0.model).hasPrefix(key) }
    }

    static func localKey(_ name: String) -> String {
        var base = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        for suffix in ["-gguf", "-mlx", "_gguf", "-4bit", "-8bit", "-bf16", "-fp16"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return base.filter { $0.isLetter || $0.isNumber }
    }
}
