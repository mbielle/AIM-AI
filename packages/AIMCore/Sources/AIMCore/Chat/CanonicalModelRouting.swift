import Foundation

/// Exact route aliases only. Dates, versions, suffixes and quantizations remain distinct.
public enum CanonicalModelRouting {
    private static let fluxAliases: [String: String] = Dictionary(uniqueKeysWithValues:
        ["pro-preview", "pro", "max", "flex", "klein-4b", "klein-9b"].flatMap { suffix in
            ["black-forest-labs/flux-2-" + suffix, "black-forest-labs/flux.2-" + suffix].map { ($0, "black-forest-labs/flux-2-" + suffix) }
        })
    public static func identity(_ id: String, provider: String) -> String {
        if let flux = fluxAliases[id] { return flux }
        if provider == "local" { return "local:" + id }
        if provider == "openrouter" { return id }
        let creator = ["chatgpt": "openai", "xai": "x-ai", "mistral": "mistralai", "blackForestLabs": "black-forest-labs"][provider] ?? provider
        if creator == "anthropic" {
            let aliases: [String: String] = ["claude-sonnet-4-5": "claude-sonnet-4.5", "claude-sonnet-4-6": "claude-sonnet-4.6", "claude-opus-4-5": "claude-opus-4.5", "claude-opus-4-6": "claude-opus-4.6", "claude-opus-4-7": "claude-opus-4.7", "claude-opus-4-8": "claude-opus-4.8", "claude-opus-5-5": "claude-opus-5.5", "claude-sonnet-5-5": "claude-sonnet-5.5", "claude-haiku-4-5": "claude-haiku-4.5"]
            return creator + "/" + (aliases[id] ?? id)
        }
        if id.hasPrefix(creator + "/") { return id }
        // Other compatible hosts do not establish that a similarly named model is equivalent.
        guard ["openai", "anthropic", "google", "x-ai", "deepseek", "mistralai", "black-forest-labs"].contains(creator) else { return provider + ":" + id }
        return creator + "/" + id
    }
    public static func publisher(_ value: String) -> String {
        ["black-forest-labs", "black forest labs", "blackforestlabs"].contains(value.lowercased()) ? "Black Forest Labs" : value
    }
    public static func rank(_ provider: String) -> Int { provider == "chatgpt" ? 0 : provider == "openrouter" ? 2 : 1 }
    /// These statuses establish refusal at the HTTP boundary. 403 may be a safety denial;
    /// gateway 5xx and timeouts do not prove non-admission and are never replayed.
    public static func permitsFallback(_ error: Error, admitted: Bool, emittedOutput: Bool) -> Bool {
        guard !admitted, !emittedOutput, !(error is CancellationError), let value = error as? ChatServiceError else { return false }
        if case .planLimitReached = value { return true }
        guard case .http(let status) = value else { return false }
        return [401, 402, 404, 429].contains(status)
    }
    public static func preferenceKey(account: UUID, target: String, model: String) -> String {
        "aim.model-route.v1." + account.uuidString.lowercased() + "." + target + "." + model
    }
}
