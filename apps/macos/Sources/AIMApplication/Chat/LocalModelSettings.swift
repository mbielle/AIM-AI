import AIMCore
import Foundation

/// The person's own settings for one local model. Every empty field means "AIM's
/// recommendation" (the maker's published values, a context that fits this Mac).
public struct LocalModelSettings: Codable, Equatable, Sendable {
    public var contextTokens: Int?
    public var kvCacheQuantized: Bool?
    /// Replaces AIM's instructions when not empty.
    public var systemPrompt: String?
    public var maxResponseTokens: Int?
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var minP: Double?
    public var repeatPenalty: Double?
    public var seed: Int?
    public var stopStrings: [String]?

    public init() {}

    public var isDefault: Bool { self == LocalModelSettings() }

    /// The values AIM uses when the person sets nothing.
    public static func recommended(modelID: String) -> LocalModelSettings {
        let sampling = LocalModelTuning.sampling(modelID: modelID, thinking: false)
        var settings = LocalModelSettings()
        settings.temperature = sampling["temperature"] as? Double
        settings.topK = sampling["top_k"] as? Int
        settings.topP = sampling["top_p"] as? Double
        settings.minP = (sampling["min_p"] as? Double) ?? (sampling["min_p"] as? Int).map(Double.init) ?? 0.05
        settings.repeatPenalty = 1.0
        return settings
    }

    /// The request fields: AIM's sampling for the model, then the person's own values on top.
    public func requestFields(modelID: String, thinking: Bool) -> [String: Any] {
        var fields = LocalModelTuning.sampling(modelID: modelID, thinking: thinking)
        if let temperature { fields["temperature"] = temperature }
        if let topK { fields["top_k"] = topK }
        if let topP { fields["top_p"] = topP }
        if let minP { fields["min_p"] = minP }
        if let repeatPenalty { fields["repeat_penalty"] = repeatPenalty }
        if let seed { fields["seed"] = seed }
        if let stopStrings, !stopStrings.isEmpty { fields["stop"] = Array(stopStrings.prefix(4)) }
        if let maxResponseTokens, maxResponseTokens > 0 { fields["max_tokens"] = maxResponseTokens }
        return fields
    }

    public var customSystemPrompt: String? {
        let trimmed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Local model settings kept on this Mac, one entry per model name (the name sent to the engine).
public final class LocalModelSettingsStore: @unchecked Sendable {
    public static let shared = LocalModelSettingsStore()

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: LocalModelSettings]?

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AIMInstallationContext.legacyDirectoryName + "/LocalModelSettings.json")) {
        self.url = url
    }

    private func all() -> [String: LocalModelSettings] {
        if let cache { return cache }
        let loaded = (try? JSONDecoder().decode([String: LocalModelSettings].self, from: Data(contentsOf: url))) ?? [:]
        cache = loaded
        return loaded
    }

    public func settings(for model: String) -> LocalModelSettings {
        lock.lock(); defer { lock.unlock() }
        return all()[model] ?? LocalModelSettings()
    }

    public func save(_ settings: LocalModelSettings, for model: String) {
        lock.lock(); defer { lock.unlock() }
        var values = all()
        values[model] = settings.isDefault ? nil : settings
        cache = values
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
