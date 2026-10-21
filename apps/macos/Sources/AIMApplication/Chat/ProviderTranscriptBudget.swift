import AIMCore
import Foundation

/// Keeps a native tool transcript sendable during long runs. Tool screenshots
/// are the largest items and are only useful while current, so older ones are
/// replaced by a short note; on a context overflow, older tool results are also
/// shortened. The local run journal and artifacts keep everything.
enum ProviderTranscriptBudget {
    static let retainedToolImages = 2
    static let retainedFullToolResults = 4
    static let shortenedToolResultCharacters = 2_000
    static let imageNote = "[An earlier screenshot from this tool call was removed from the model context to save space. Observe again if it is needed.]"
    static let resultNote = "\n[Earlier tool output shortened to save context. The complete text remains in AIM's run journal; use read_tool_artifact when an artifact id was given.]"

    /// Replaces all but the latest `keep` tool-produced images. User-attached
    /// images in the original conversation are never touched.
    @discardableResult
    /// `slack`: images may accumulate up to `keep + slack` before the older ones are removed in one
    /// go. Each removal changes an earlier message and voids the provider's prompt cache from there,
    /// so removing in batches keeps most steps cached (Round 37: single removals cost 0.33 $ steps).
    static func pruneToolImages(_ history: inout [[String: Any]], provider: ChatProvider, keep: Int = retainedToolImages,
                                slack: Int = 0) -> Int {
        var locations: [(message: Int, block: Int?)] = []
        for (index, message) in history.enumerated() {
            switch provider {
            case .anthropic:
                guard message["role"] as? String == "user", let blocks = message["content"] as? [[String: Any]] else { continue }
                for (blockIndex, block) in blocks.enumerated() where block["type"] as? String == "tool_result" {
                    if let content = block["content"] as? [[String: Any]], content.contains(where: { $0["type"] as? String == "image" }) {
                        locations.append((index, blockIndex))
                    }
                }
            case .google:
                guard let parts = message["parts"] as? [[String: Any]],
                      parts.contains(where: { $0["functionResponse"] != nil }) else { continue }
                for (partIndex, part) in parts.enumerated() where part["inline_data"] != nil {
                    locations.append((index, partIndex))
                }
            default:
                if isToolScreenshotMessage(message) { locations.append((index, nil)) }
            }
        }
        guard locations.count > keep + max(0, slack) else { return 0 }
        let removable = locations.dropLast(max(0, keep))
        for location in removable {
            switch provider {
            case .anthropic:
                guard var blocks = history[location.message]["content"] as? [[String: Any]], let blockIndex = location.block,
                      let content = blocks[blockIndex]["content"] as? [[String: Any]] else { continue }
                let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                blocks[blockIndex]["content"] = (texts + [imageNote]).joined(separator: "\n")
                history[location.message]["content"] = blocks
            case .google:
                guard var parts = history[location.message]["parts"] as? [[String: Any]], let partIndex = location.block else { continue }
                parts[partIndex] = ["text": imageNote]
                history[location.message]["parts"] = parts
            default:
                let textType = provider.usesResponsesAPI ? "input_text" : "text"
                history[location.message]["content"] = [["type": textType, "text": imageNote]]
            }
        }
        return removable.count
    }

    /// Shortens tool outputs older than the latest few. Used once after a
    /// provider reports a context overflow.
    @discardableResult
    static func shortenOldToolResults(_ history: inout [[String: Any]], provider: ChatProvider,
                                      keep: Int = retainedFullToolResults,
                                      limit: Int = shortenedToolResultCharacters) -> Int {
        var locations: [(message: Int, block: Int?)] = []
        for (index, message) in history.enumerated() {
            if provider == .google, let parts = message["parts"] as? [[String: Any]] {
                for (blockIndex, part) in parts.enumerated() where part["functionResponse"] != nil {
                    locations.append((index, blockIndex))
                }
            } else if provider == .anthropic, message["role"] as? String == "user",
               let blocks = message["content"] as? [[String: Any]] {
                for (blockIndex, block) in blocks.enumerated() where block["type"] as? String == "tool_result" {
                    locations.append((index, blockIndex))
                }
            } else if message["role"] as? String == "tool" || message["type"] as? String == "function_call_output" {
                locations.append((index, nil))
            }
        }
        var shortened = 0
        for location in locations.dropLast(max(0, keep)) {
            if let blockIndex = location.block {
                if provider == .google {
                    guard var parts = history[location.message]["parts"] as? [[String: Any]],
                          var function = parts[blockIndex]["functionResponse"] as? [String: Any],
                          var response = function["response"] as? [String: Any] else { continue }
                    let key = response["error"] != nil ? "error" : "output"
                    guard let text = response[key] as? String, text.count > limit else { continue }
                    response[key] = String(text.prefix(limit)) + resultNote
                    function["response"] = response; parts[blockIndex]["functionResponse"] = function
                    history[location.message]["parts"] = parts; shortened += 1
                    continue
                }
                guard var blocks = history[location.message]["content"] as? [[String: Any]] else { continue }
                if let text = blocks[blockIndex]["content"] as? String, text.count > limit {
                    blocks[blockIndex]["content"] = String(text.prefix(limit)) + resultNote
                    history[location.message]["content"] = blocks
                    shortened += 1
                }
                continue
            }
            let key = history[location.message]["role"] as? String == "tool" ? "content" : "output"
            guard let raw = history[location.message][key] as? String else { continue }
            if let data = raw.data(using: .utf8),
               var envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = envelope["content"] as? String, content.count > limit {
                envelope["content"] = String(content.prefix(limit)) + resultNote
                if let encoded = try? JSONSerialization.data(withJSONObject: envelope) {
                    history[location.message][key] = String(decoding: encoded, as: UTF8.self)
                    shortened += 1
                }
            } else if raw.count > limit {
                history[location.message][key] = String(raw.prefix(limit)) + resultNote
                shortened += 1
            }
        }
        return shortened
    }

    private static func isToolScreenshotMessage(_ message: [String: Any]) -> Bool {
        guard message["role"] as? String == "user", let parts = message["content"] as? [[String: Any]],
              let first = parts.first?["text"] as? String, first.hasPrefix("Screenshot from tool call") else { return false }
        return parts.contains { ["image_url", "input_image"].contains($0["type"] as? String ?? "") }
    }
}

/// Bounded retries for refused or interrupted model requests.
public struct ProviderRetryPolicy: Sendable {
    public var maximumRetries: Int
    /// Multiplies every computed delay; tests use 0.
    public var delayScale: Double
    public var durable: Bool = false

    public init(maximumRetries: Int = 3, delayScale: Double = 1) {
        self.maximumRetries = maximumRetries
        self.delayScale = delayScale
    }

    public static let standard = ProviderRetryPolicy()
    /// Durable runs: three quick retries, then the task waits and resumes on its own.
    public static var persistent: ProviderRetryPolicy {
        var value = ProviderRetryPolicy(maximumRetries: 3); value.durable = true; return value
    }
}

public struct ProviderRetryDeferral: Error, Sendable {
    public let status: Int?
    public let notBefore: Date?
    public init(status: Int?, notBefore: Date?) { self.status = status; self.notBefore = notBefore }
}

/// Stable, secret-free classifications for durable recovery. Provider bodies stay in memory.
public struct ProviderRequestError: LocalizedError, Sendable {
    public enum Classification: String, Codable, Sendable {
        case authentication, quota, configuration, modelUnavailable, transient, invalidResponse
    }
    public let classification: Classification
    public let status: Int?
    public init(classification: Classification, status: Int? = nil) {
        self.classification = classification; self.status = status
    }
    public var errorDescription: String? {
        switch classification {
        case .authentication: "The provider rejected access. Reconnect it in Settings."
        case .quota: "The provider account needs credits or a quota change."
        case .configuration: "The provider rejected this request's configuration. Review the model and settings."
        case .modelUnavailable: "The selected model is unavailable. Choose another model."
        case .transient: "The provider is temporarily unavailable."
        case .invalidResponse: "The provider returned an invalid response. Inspection is required."
        }
    }
}

public enum ProviderCredentialError: LocalizedError, Sendable {
    case unavailable, expired
    public var errorDescription: String? {
        switch self {
        case .unavailable: "AIM could not read or save the provider credentials. Check Keychain access and reconnect the provider."
        case .expired: "The provider session expired. Sign in again in Settings."
        }
    }
}

/// A provider refusal or transport failure, with what AIM needs to decide on a
/// bounded retry. Bodies are kept only in memory for classification.
struct ProviderRequestFailure: Error {
    let status: Int?
    let retryAfter: TimeInterval?
    let bodyPrefix: String
    let transport: URLError.Code?

    /// Overload and temporary server failures: no answer was produced, so nothing ran twice.
    static let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529]
    static let retryableTransport: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
        .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed]

    var isContextOverflow: Bool {
        guard let status, [400, 413, 422].contains(status) else { return false }
        let text = bodyPrefix.lowercased()
        return ["context length", "context_length", "maximum context", "context window", "too many tokens",
                "prompt is too long", "input is too long", "reduce the length", "exceeds the context",
                "request too large", "model_context_window_exceeded"].contains { text.contains($0) }
    }

    /// Optional request fields a 400/422 explicitly rejects (stripped for one retry).
    func rejectedParameters(among optional: Set<String>) -> Set<String> {
        guard let status, [400, 404, 422].contains(status) else { return [] }
        let text = bodyPrefix.lowercased()
        if text.contains("no endpoints found that support") || text.contains("require_parameters") {
            return optional.intersection(["provider", "reasoning"])
        }
        let refusal = ["unsupported", "not supported", "unknown", "unrecognized", "not allowed", "extra inputs",
                       "invalid parameter", "unexpected", "not permitted"].contains { text.contains($0) }
        guard refusal else { return [] }
        return optional.filter { text.contains($0.lowercased()) }
    }

    /// The model itself cannot serve this request (removed, renamed or unavailable).
    var isModelUnavailable: Bool {
        guard let status else { return false }
        let text = bodyPrefix.lowercased()
        if status == 404 && !text.contains("no endpoints found that support") { return true }
        guard [400, 403, 422].contains(status), text.contains("model") else { return false }
        return ["not found", "does not exist", "not a valid model", "is not available", "no longer available",
                "deprecated", "decommissioned", "no allowed providers"].contains { text.contains($0) }
    }

    var isRetryable: Bool {
        if let status {
            let text = bodyPrefix.lowercased()
            if [400, 429].contains(status),
               ["insufficient_quota", "insufficient credits", "insufficient balance", "billing_hard_limit", "credit balance is too low", "quota exhausted"].contains(where: text.contains) { return false }
            return Self.retryableStatuses.contains(status)
        }
        // A dropped connection may have been billed, but no tool ran from it: asking again is safe
        // for the work and keeps the agent going on its own, as the person chose.
        return transport.map(Self.retryableTransport.contains) ?? false
    }

    var classification: ProviderRequestError.Classification {
        if isModelUnavailable { return .modelUnavailable }
        if let status, [401, 403].contains(status) { return .authentication }
        if status == 402 { return .quota }
        let text = bodyPrefix.lowercased()
        if let status, [400, 429].contains(status),
           ["insufficient_quota", "insufficient credits", "insufficient balance", "billing_hard_limit", "credit balance is too low", "quota exhausted"].contains(where: text.contains) { return .quota }
        if isRetryable { return .transient }
        if let status, [400, 404, 405, 413, 415, 422].contains(status) { return .configuration }
        return .invalidResponse
    }

    var durableError: ProviderRequestError { ProviderRequestError(classification: classification, status: status) }

    /// Exponential backoff with jitter; a server's Retry-After is a lower bound.
    func delay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite { return max(0, retryAfter) }
        return min(60, 2 * pow(2, Double(attempt)) * jitter)
    }

    var publicError: Error {
        if let status { return ChatServiceError.http(status) }
        if let transport { return URLError(transport) }
        return ModelToolError.invalidProtocol
    }

    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { $0.timeIntervalSince(now) }
    }

    /// OpenRouter can return HTTP 200 with an `error` object from the upstream.
    static func embeddedError(in data: Data) -> ProviderRequestFailure? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        let code = (error["code"] as? Int) ?? Int(error["code"] as? String ?? "")
        let message = error["message"] as? String ?? ""
        return ProviderRequestFailure(status: code ?? 502, retryAfter: nil,
            bodyPrefix: String(message.prefix(2_000)), transport: nil)
    }
}
