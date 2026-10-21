import Foundation

public struct NativeChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public var sources: [ConversationSource]?
    public var routeAttempts: [ConversationRouteAttempt]?
    public var visualReport: VisualAnalysisReport?
    public var actions: [ConversationAction]?
    /// Order of reasoning, text and actions in this turn; nil for older messages.
    public var timeline: TurnTimeline?
    public var attachments: [NativeChatAttachment]?
    public var mediaAssetIDs: [UUID]?
    public var skillActivities: [NativeSkillActivity]?
    public var webSearchActivities: [NativeWebSearchActivity]?
    public var webSearchUsage: NativeWebSearchUsage?
    public var createdAt: Date
    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now, webSearchUsage: NativeWebSearchUsage? = nil, webSearchActivities: [NativeWebSearchActivity]? = nil, skillActivities: [NativeSkillActivity]? = nil, mediaAssetIDs: [UUID]? = nil, attachments: [NativeChatAttachment]? = nil, actions: [ConversationAction]? = nil, visualReport: VisualAnalysisReport? = nil, sources: [ConversationSource]? = nil, routeAttempts: [ConversationRouteAttempt]? = nil, timeline: TurnTimeline? = nil) {
        self.timeline = timeline
        self.routeAttempts = routeAttempts
        self.sources = sources
        self.visualReport = visualReport; self.actions = actions; self.id = id; self.attachments = attachments; self.role = role; self.text = text; self.mediaAssetIDs = mediaAssetIDs; self.skillActivities = skillActivities; self.createdAt = createdAt; self.webSearchUsage = webSearchUsage; self.webSearchActivities = webSearchActivities
    }
}

public struct NativeChatEvent: Sendable {
    public var text: String
    /// Readable reasoning summary delta, when the provider sends one.
    public var reasoning: String?
    public var sources: [ConversationSource]?
    public var usage: TokenUsage?
    public var skillActivities: [NativeSkillActivity]?
    public var webSearchActivities: [NativeWebSearchActivity]?
    public var webSearchUsage: NativeWebSearchUsage?
    public var isComplete: Bool
    public var requestAccepted: Bool?
    public var routeAttempt: ConversationRouteAttempt?
    public var connectionWaiting: Bool?
    public init(text: String = "", usage: TokenUsage? = nil, isComplete: Bool = false, webSearchUsage: NativeWebSearchUsage? = nil, webSearchActivities: [NativeWebSearchActivity]? = nil, skillActivities: [NativeSkillActivity]? = nil, connectionWaiting: Bool? = nil, sources: [ConversationSource]? = nil, requestAccepted: Bool? = nil, routeAttempt: ConversationRouteAttempt? = nil, reasoning: String? = nil) {
        self.reasoning = reasoning; self.requestAccepted = requestAccepted; self.routeAttempt = routeAttempt
        self.sources = sources
        self.connectionWaiting = connectionWaiting; self.text = text; self.skillActivities = skillActivities; self.usage = usage; self.isComplete = isComplete; self.webSearchUsage = webSearchUsage; self.webSearchActivities = webSearchActivities
    }
}

/// Shared phone/Mac transport. Only explicitly enabled hosted web search is accepted.
/// Each request fixes its provider and model; failures never switch billing targets.
public struct NativeChatTransport: Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    private let networkReadiness: @Sendable (@escaping @Sendable () -> Void) async throws -> Void
    public static func secretSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        return AIMManagedNetworkSession.make(configuration: config, delegate: NoRedirects())
    }
    public init(session: URLSession? = nil,
                networkReadiness: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> Void = { try await NetworkAvailability.wait(onWaiting: $0) }) {
        self.session = session ?? Self.secretSession(); self.networkReadiness = networkReadiness
    }
    public static func request(provider: ChatProvider, modelID: String, messages: [NativeChatMessage], key: String,
                               instructions: String = "", maxOutputTokens: Int? = nil, webSearch: Bool = false, catalogMaximum: Int? = nil,
                               reasoningSummary: Bool = false) throws -> URLRequest {
        guard provider != .local, provider != .chatgpt else { throw ChatServiceError.planUsageUnavailable }
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }), !key.contains("\0") else { throw ChatServiceError.missingKey }
        guard !modelID.isEmpty, modelID.utf8.count < 256, !modelID.contains(".."),
              modelID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }),
              maxOutputTokens.map({ $0 > 0 }) ?? true else { throw ChatServiceError.invalidResponse }
        let outputLimit = try ModelOutputPolicy.resolve(provider: provider, modelID: modelID, catalogMaximum: catalogMaximum, userLimit: maxOutputTokens)
        if webSearch { try NativeWebSearchRules.requireCompatibility(provider: provider, modelID: modelID) }
        for message in messages {
            try NativeChatAttachment.validate(message.attachments ?? [])
            guard message.role == .user || (message.attachments ?? []).isEmpty else { throw ChatServiceError.invalidResponse }
        }
        guard messages.reduce(0, { $0 + NativeAttachmentEncoding.text($1).utf8.count - $1.text.utf8.count }) <= 512_000 else { throw NativeDocumentError.historyLimit }
        if provider == .deepSeek && messages.contains(where: { ($0.attachments ?? []).contains { $0.containsVisualContent } }) { throw NativeImageSnapshotError.unsupportedProvider }
        let history: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": NativeAttachmentEncoding.content($0, provider: provider)] }
        var path: String
        var body: [String: Any]
        let base = CompatibleProviders.spec(provider)?.baseURL ?? "https://\(provider.host)"
        if provider.usesChatCompletions {
            path = provider == .openRouter ? "/api/v1/chat/completions" : "/chat/completions"
            var wire = history
            if !instructions.isEmpty { wire.insert(["role": "system", "content": instructions], at: 0) }
            body = ["model": modelID, "messages": wire, "stream": true]
            if provider == .openRouter { body["usage"] = ["include": true] }
            else { body["stream_options"] = ["include_usage": true] }
        } else {
            switch provider {
            case .anthropic:
                path = "/v1/messages"
                body = ["model": modelID, "messages": history, "stream": true]
                // Models that always think stream an empty summary unless one is requested; no extra cost.
                body.merge(AnthropicThinkingPolicy.fields(modelID: modelID, effort: nil, budget: nil)) { $1 }
                if !instructions.isEmpty { body["system"] = instructions }
            case .google:
                let name = modelID.hasPrefix("models/") ? String(modelID.dropFirst(7)) : modelID
                guard !name.contains("/"), !name.contains(":") else { throw ChatServiceError.invalidResponse }
                path = "/v1beta/models/\(name):streamGenerateContent?alt=sse"
                body = ["contents": messages.map { ["role": $0.role == .assistant ? "model" : "user", "parts": NativeAttachmentEncoding.googleParts($0)] as [String: Any] }]
                if !instructions.isEmpty { body["systemInstruction"] = ["parts": [["text": instructions]]] }
            case .openAI, .xAI, .perplexity:
                path = provider == .perplexity ? "/v1/agent" : "/v1/responses"
                body = ["model": modelID, "input": history, "stream": true, "store": false]
                // Only reasoning models accept this field; the caller states it from the catalog.
                if reasoningSummary, provider == .openAI { body["reasoning"] = ["summary": "auto"] }
                if !instructions.isEmpty { body["instructions"] = instructions }
            default: throw ChatServiceError.invalidResponse
            }
        }
        if let outputLimit {
            if provider == .google { body["generationConfig"] = ["maxOutputTokens": outputLimit] }
            else if provider.usesChatCompletions || provider == .anthropic { body["max_tokens"] = outputLimit }
            else { body["max_output_tokens"] = outputLimit }
        }
        if webSearch { body["tools"] = [NativeWebSearchRules.tool(provider: provider)] }
        var request = authenticatedRequest(url: URL(string: base + path)!, provider: provider, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public func stream(provider: ChatProvider, modelID: String, messages: [NativeChatMessage], key: String,
                       instructions: String = "", maxOutputTokens: Int? = nil, webSearch: Bool = false, catalogMaximum: Int? = nil, reasoningSummary: Bool = false, admission: @escaping @Sendable () async throws -> Void = {}) -> AsyncThrowingStream<NativeChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try AIMNetworkPrivacyPolicy.requireNetwork()
                    try await networkReadiness { continuation.yield(.init(connectionWaiting: true)) }
                    try Task.checkCancellation()
                    try await admission()
                    continuation.yield(.init(connectionWaiting: false))
                    var maximum = catalogMaximum
                    if provider == .anthropic, maxOutputTokens == nil, maximum == nil {
                        maximum = try await modelCapacity(modelID: modelID, key: key)
                    }
                    let request = try Self.request(provider: provider, modelID: modelID, messages: messages, key: key,
                                                   instructions: instructions, maxOutputTokens: maxOutputTokens, webSearch: webSearch, catalogMaximum: maximum,
                                                   reasoningSummary: reasoningSummary)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)
                    continuation.yield(.init(requestAccepted: true))
                    var framer = ServerSentEventFramer(); var complete = false; var visible = false
                    var searchDecoder = NativeWebSearchDecoder()
                    var searchTracker = NativeWebSearchTracker()
                    func emit(_ payload: String) throws {
                        if let reasoning = ProviderReasoningStream.delta(payload, provider: provider) { continuation.yield(.init(reasoning: reasoning)) }
                        if webSearch {
                            let activities = searchTracker.consume(payload, provider: provider)
                            if !activities.isEmpty { continuation.yield(.init(webSearchActivities: activities)) }
                        }
                        let chunk = try webSearch ? searchDecoder.decode(payload, provider: provider) : ProviderWireFormat.decode(payload, provider: provider)
                        visible = visible || !chunk.text.isEmpty; complete = complete || chunk.isComplete
                        continuation.yield(.init(text: chunk.text, usage: TokenUsageParser.parse(payload), isComplete: chunk.isComplete,
                                                 webSearchUsage: webSearch ? NativeWebSearchRules.usage(payload, provider: provider) : nil, sources: chunk.sources))
                    }
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let payload = try framer.append(byte) {
                            try emit(payload)
                            if complete { break }
                        }
                    }
                    guard complete else { throw ChatServiceError.incompleteResponse }
                    guard visible else { throw ChatServiceError.emptyResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func validateKey(provider: ChatProvider, key: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        if provider == .openRouter {
            let request = Self.authenticatedRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, provider: provider, key: key)
            let (data, response) = try await session.data(for: request); try Self.validate(response)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["data"] is [String: Any], root["error"] == nil else { throw ChatServiceError.invalidResponse }
        } else { _ = try await models(provider: provider, key: key) }
    }
    public func models(provider: ChatProvider, key: String?) async throws -> [ChatModel] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard provider != .local, provider != .chatgpt else { throw ChatServiceError.planUsageUnavailable }
        if provider != .openRouter, key?.isEmpty != false { throw ChatServiceError.missingKey }
        let base = CompatibleProviders.spec(provider)?.baseURL ?? "https://\(provider.host)"
        let path: String
        switch provider {
        case .openRouter: path = "/api/v1/models"
        case .google: path = "/v1beta/models"
        case .xAI: path = "/v1/language-models"
        case .perplexity: path = "/router/v1/models"
        case .deepSeek: path = "/models"
        default: path = provider.isCompatible ? "/models" : "/v1/models"
        }
        var result: [ChatModel] = []; var cursor: String?; var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            var url = URLComponents(string: base + path)!
            if provider == .openRouter { url.queryItems = [.init(name: "output_modalities", value: "all")] }
            if provider == .anthropic { url.queryItems = [.init(name: "limit", value: "100")] }
            if let cursor { url.queryItems = (url.queryItems ?? []) + [.init(name: provider == .google ? "pageToken" : "after_id", value: cursor)] }
            let (data, response) = try await session.data(for: Self.authenticatedRequest(url: url.url!, provider: provider, key: key ?? ""))
            try Self.validate(response)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else { throw ChatServiceError.invalidResponse }
            if provider == .openRouter { return try JSONDecoder().decode(Catalog.self, from: data).data }
            if provider.isCompatible { return try CompatibleProviders.decodeModels(data).filter(Self.isChatModel) }
            guard let rows = root[provider == .google || provider == .xAI ? "models" : "data"] as? [[String: Any]] else { throw ChatServiceError.invalidResponse }
            result += rows.compactMap { row in
                guard let id = row[provider == .google ? "name" : "id"] as? String else { return nil }
                if provider == .google, !(row["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { return nil }
                let model = ChatModel(id: id, name: (row["displayName"] ?? row["display_name"]) as? String ?? id,
                                      contextLength: (row["context_length"] ?? row["inputTokenLimit"] ?? row["max_input_tokens"]) as? Int,
                                      maxOutputTokens: (row["max_tokens"] ?? row["outputTokenLimit"]) as? Int)
                return Self.isChatModel(model) ? model : nil
            }
            let next = provider == .google ? root["nextPageToken"] as? String : (root["has_more"] as? Bool == true ? root["last_id"] as? String : nil)
            guard let next, !next.isEmpty else { return result }
            guard seen.insert(next).inserted else { throw ChatServiceError.invalidResponse }; cursor = next
        }
    }
    /// Anthropic requires max_tokens; use its authenticated model metadata, not
    /// a product quota or a guessed default. This endpoint never generates text.
    private func modelCapacity(modelID: String, key: String) async throws -> Int? {
        let url = URL(string: "https://api.anthropic.com/v1/models/" + modelID)!
        let (data, response) = try await session.data(for: Self.authenticatedRequest(url: url, provider: .anthropic, key: key))
        try Self.validate(response)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (row["id"] as? String)?.isEmpty == false, let maximum = row["max_tokens"] as? Int, maximum > 0 else {
            throw ModelOutputPolicyError.modelCapacityUnknown
        }
        return maximum
    }
    private struct Catalog: Decodable { let data: [ChatModel] }
    private static func isChatModel(_ model: ChatModel) -> Bool {
        model.isChatModel && !["embed", "whisper", "tts", "rerank", "moderation", "transcrib", "image", "realtime", "audio"].contains(where: model.id.lowercased().contains)
    }
    private static func authenticatedRequest(url: URL, provider: ChatProvider, key: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        switch provider {
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }
    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ChatServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ChatServiceError.http(response.statusCode) }
    }
}

public enum ChatCostRules {
    /// An estimate from catalog prices, never a provider invoice or a ChatGPT charge.
    public static func estimateUSD(usage: TokenUsage, pricing: ChatModel.Pricing?, webSearch: NativeWebSearchUsage? = nil, allowPartialWebSearchCost: Bool = false) -> Double? {
        // A provider total already includes its billable components. Never add token/search estimates again.
        if let total = webSearch?.providerTotalCostUSD, total.isFinite, total >= 0 { return total }
        guard let pricing, let input = usage.inputTokens, let output = usage.outputTokens,
              input >= 0, output >= 0, let inputRate = pricing.inputPerMillion, let outputRate = pricing.outputPerMillion,
              inputRate.isFinite, outputRate.isFinite else { return nil }
        let cached = min(input, max(0, usage.cachedInputTokens ?? 0))
        let cachedRate = pricing.cacheReadPerMillion ?? inputRate
        guard cachedRate.isFinite else { return nil }
        let searchCost: Double
        if let webSearch {
            if let cost = webSearch.additionalCostUSD {
                guard cost.isFinite, cost >= 0 else { return nil }
                searchCost = cost
            } else {
                // This returns only a known subtotal. The nil metadata stays nil, never a free-search claim.
                guard allowPartialWebSearchCost else { return nil }
                searchCost = 0
            }
        } else { searchCost = 0 }
        let amount = (Double(input - cached) * inputRate + Double(cached) * cachedRate + Double(output) * outputRate) / 1_000_000 + searchCost
        return amount.isFinite && amount >= 0 ? amount : nil
    }
}
