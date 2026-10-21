import Foundation
import AIMCore

public typealias ChatProvider = AIMCore.ChatProvider
public typealias ProviderStreamChunk = AIMCore.ProviderStreamChunk
public typealias ProviderWireFormat = AIMCore.ProviderWireFormat

public struct ProviderChatService: Sendable {
    private let session: URLSession
    private let meter: BillableRequestMeter
    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter()) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
    }

    private func routedEvents(routes: [NativeChatRoute], messages: [ConversationMessage], mode: AIMMode,
        anthropicOutputTokens: Int?, openAIReasoningEffort: OpenAIReasoningEffort?, useWebSearch: Bool,
        billingFeature: String?, titleRequested: Bool) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = ChatServiceError.invalidResponse
                var seen = Set<String>()
                var attempts: [ConversationRouteAttempt] = []
                for (index, route) in routes.enumerated() {
                    guard let first = routes.first, CanonicalModelRouting.identity(route.model.id, provider: route.provider.rawValue) == CanonicalModelRouting.identity(first.model.id, provider: first.provider.rawValue), seen.insert(route.provider.rawValue + ":" + route.model.id).inserted else { continue }
                    var admitted = false, output = false
                    attempts = ConversationRouteAttempt.merge(attempts, [.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .trying)]) ?? []
                    continuation.yield(.routing(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .trying)))
                    do {
                        try Task.checkCancellation()
                        for try await event in events(provider: route.provider, modelID: route.model.id, messages: messages, apiKey: route.key, mode: mode,
                            anthropicOutputTokens: anthropicOutputTokens, openAIReasoningEffort: openAIReasoningEffort, useWebSearch: useWebSearch,
                            billingFeature: billingFeature, titleRequested: titleRequested) {
                            if case .requestAccepted = event { admitted = true; attempts = ConversationRouteAttempt.merge(attempts, [.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .accepted)]) ?? [] }
                            if case .text(let text) = event { output = output || !text.isEmpty }
                            if case .webSearch = event { admitted = true }
                            if case .metrics(var value) = event { value.routeAttempts = attempts; continuation.yield(.metrics(value)) } else { continuation.yield(event) }
                        }
                        continuation.yield(.routing(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .accepted)))
                        continuation.finish(); return
                    } catch {
                        lastError = error
                        guard CanonicalModelRouting.permitsFallback(error, admitted: admitted, emittedOutput: output) else {
                            continuation.yield(.routing(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .uncertain)))
                            continuation.finish(throwing: error); return
                        }
                        attempts = ConversationRouteAttempt.merge(attempts, [.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .rejected)]) ?? []
                        continuation.yield(.routing(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .rejected)))
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public enum CredentialCheck: Sendable, Equatable {
        /// OpenRouter's authenticated key-information endpoint accepted the key.
        case keyAccepted
        /// The provider's authenticated model-catalog endpoint accepted the key.
        case catalogAccessible
    }

    /// User-initiated, read-only connection check. It does not generate tokens or prove
    /// that any particular model can be used for inference. The key stays in a header.
    public func checkCredential(provider: ChatProvider, apiKey: String) async throws -> CredentialCheck {
        if provider == .local {
            _ = try await models(provider: .local, apiKey: apiKey)
            return .catalogAccessible
        }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }), !apiKey.contains("\0") else {
            throw ChatServiceError.missingKey
        }
        if let spec = CompatibleProviders.spec(provider) {
            var request = Self.authenticatedRequest(url: URL(string: spec.baseURL + "/models")!, provider: provider, key: apiKey)
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            // A key check needs an actual catalog: `{}` or an error body is not proof the key works.
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] == nil,
                  root["data"] is [[String: Any]] || root["models"] is [[String: Any]] else { throw ChatServiceError.invalidResponse }
            return .catalogAccessible
        }
        let path: String
        switch provider {
        case .openRouter: path = "/api/v1/key"
        case .openAI, .anthropic, .chatgpt: path = "/v1/models"
        case .google: path = "/v1beta/models"
        case .deepSeek: path = "/models"
        case .xAI: path = "/v1/language-models"
        case .perplexity: path = "/router/v1/models"
        case .local: path = "/v1/models"
        default: path = "/models"
        }
        var request = Self.authenticatedRequest(url: URL(string: "https://\(provider.host)\(path)")!, provider: provider, key: apiKey)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] == nil else {
            throw ChatServiceError.invalidResponse
        }
        if provider == .openRouter {
            guard root["data"] is [String: Any] else { throw ChatServiceError.invalidResponse }
            return .keyAccepted
        }
        guard root[provider == .google || provider == .xAI ? "models" : "data"] is [[String: Any]] else {
            throw ChatServiceError.invalidResponse
        }
        return .catalogAccessible
    }

    /// `extraInstruction` is appended to the system instructions of this request only
    /// (e.g. the first turn's title request).
    public static func request(provider: ChatProvider, modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode, anthropicOutputTokens: Int? = nil, openAIReasoningEffort: OpenAIReasoningEffort? = nil, useWebSearch: Bool = true, extraInstruction: String? = nil, catalogMaximumOutputTokens: Int? = nil) throws -> URLRequest {
        guard openAIReasoningEffort == nil || OpenAIReasoningEffort.applies(to: provider) else { throw ChatServiceError.invalidResponse }
        if provider == .openRouter { return try OpenRouterChatService.request(modelID: modelID, messages: messages, apiKey: apiKey, mode: mode, reasoningEffort: openAIReasoningEffort, extraInstruction: extraInstruction, useWebSearch: useWebSearch) }
        if provider == .local { return try localRequest(modelID: modelID, messages: messages, apiKey: apiKey, mode: mode, effort: openAIReasoningEffort, extraInstruction: extraInstruction) }
        guard !apiKey.isEmpty, !apiKey.contains(where: \.isWhitespace) else { throw ChatServiceError.missingKey }
        guard !modelID.isEmpty, modelID.utf8.count < 256,
              modelID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }),
              !modelID.contains("..") else { throw ChatServiceError.invalidResponse }
        let history = try ImageMessageEncoding.prepare(messages.filter { $0.role == .user || $0.role == .assistant }, provider: provider)
        let modeInstruction = "You are AIM, a helpful assistant. You can discuss tasks but cannot execute tools or inspect local files in this version. Never claim to have performed those actions."
        let system = [mode != .chat ? modeInstruction : nil, extraInstruction].compactMap { $0 }.joined(separator: "\n\n")
        let webEnabled = useWebSearch && NativeWebSearchRules.supports(provider: provider, modelID: modelID)
        let path: String
        var body: [String: Any]
        switch provider {
        case _ where provider.isCompatible:
            path = "/chat/completions"
            var wire = history.map { ["role": $0.role.rawValue, "content": ImageMessageEncoding.chatCompletionsContent($0)] as [String: Any] }
            if !system.isEmpty { wire.insert(["role": "system", "content": system], at: 0) }
            body = ["model": modelID, "messages": wire, "stream": true, "stream_options": ["include_usage": true]]
        case .deepSeek:
            path = "/chat/completions"
            var wire = history.map { ["role": $0.role.rawValue, "content": $0.content] }
            if !system.isEmpty { wire.insert(["role": "system", "content": system], at: 0) }
            body = ["model": modelID, "messages": wire, "stream": true, "stream_options": ["include_usage": true]]
        case .openAI, .xAI, .chatgpt:
            path = "/v1/responses"
            body = ["model": modelID, "input": history.map { ["role": $0.role.rawValue, "content": ImageMessageEncoding.responsesContent($0)] as [String: Any] }, "stream": true, "store": false]
            if provider == .openAI || provider == .chatgpt, let openAIReasoningEffort {
                // A readable summary of the model's reasoning, shown above the answer; the reasoning itself stays private.
                body["reasoning"] = openAIReasoningEffort == .none ? ["effort": "none"] : ["effort": openAIReasoningEffort.rawValue, "summary": "auto"]
            }
            if provider == .xAI, let openAIReasoningEffort { body["reasoning"] = ["effort": openAIReasoningEffort.xAIEffort] }
            if !system.isEmpty { body["instructions"] = system }
        case .perplexity:
            path = "/v1/agent"
            body = ["model": modelID,
                    "input": history.map { ["role": $0.role.rawValue, "content": ImageMessageEncoding.responsesContent($0)] as [String: Any] },
                    "stream": true, "store": false]
            if webEnabled { body["tools"] = [NativeWebSearchRules.tool(provider: provider)] }
            if !system.isEmpty { body["instructions"] = system }
        case .anthropic:
            guard anthropicOutputTokens == nil || anthropicOutputTokens! > 0 else { throw ChatServiceError.invalidResponse }
            path = "/v1/messages"
            let budget = openAIReasoningEffort?.anthropicThinkingBudget
            body = ["model": modelID, "messages": history.map { ["role": $0.role.rawValue, "content": ImageMessageEncoding.anthropicContent($0)] as [String: Any] }, "stream": true]
            body["max_tokens"] = try ModelOutputPolicy.resolve(provider: provider, modelID: modelID,
                catalogMaximum: catalogMaximumOutputTokens, userLimit: anthropicOutputTokens, thinkingBudget: budget)
            // Claude 4.6+ rejects budget_tokens; newer models also need an explicit summary to show anything.
            body.merge(AnthropicThinkingPolicy.fields(modelID: modelID, effort: openAIReasoningEffort?.rawValue, budget: budget)) { $1 }
            if !system.isEmpty { body["system"] = system }
        case .google:
            let name = modelID.hasPrefix("models/") ? String(modelID.dropFirst(7)) : modelID
            guard !name.contains("/"), !name.contains(":") else { throw ChatServiceError.invalidResponse }
            path = "/v1beta/models/\(name):streamGenerateContent?alt=sse"
            body = ["contents": history.map { ["role": $0.role == .assistant ? "model" : "user", "parts": ImageMessageEncoding.googleParts($0)] as [String: Any] }]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        default: fatalError("Handled above")
        }
        if webEnabled { body["tools"] = [NativeWebSearchRules.tool(provider: provider)] }
        let base = CompatibleProviders.spec(provider)?.baseURL ?? "https://\(provider.host)"
        var request = authenticatedRequest(url: URL(string: base + path)!, provider: provider, key: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// OpenAI chat-completions against the local server (text turns; images are described as attachments).
    static func localRequest(modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode,
                             effort: OpenAIReasoningEffort? = nil, extraInstruction: String? = nil, now: Date = .now,
                             settings: LocalModelSettings? = nil) throws -> URLRequest {
        let settings = settings ?? LocalModelSettingsStore.shared.settings(for: modelID)
        guard !modelID.isEmpty, modelID.utf8.count < 256, !modelID.contains(where: \.isNewline) else { throw ChatServiceError.invalidResponse }
        var wire: [[String: Any]] = messages.filter { $0.role == .user || $0.role == .assistant }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        let system = [settings.customSystemPrompt ?? LocalModelTuning.systemPrompt(mode: mode, now: now), extraInstruction]
            .compactMap { $0 }.joined(separator: "\n\n")
        wire.insert(["role": "system", "content": system], at: 0)
        var body: [String: Any] = ["model": modelID, "messages": wire, "stream": true, "stream_options": ["include_usage": true]]
        for (key, value) in settings.requestFields(modelID: modelID, thinking: LocalModelTuning.thinks(modelID: modelID, effort: effort)) {
            body[key] = value
        }
        var request = URLRequest(url: LocalModelEndpoint.url("chat/completions"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "POST"
        if !apiKey.isEmpty, apiKey != "local" { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func stream(provider: ChatProvider, modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode, anthropicOutputTokens: Int? = nil, openAIReasoningEffort: OpenAIReasoningEffort? = nil, useWebSearch: Bool = true, billingFeature: String? = nil) -> AsyncThrowingStream<String, Error> {
        let events = events(provider: provider, modelID: modelID, messages: messages, apiKey: apiKey, mode: mode,
                            anthropicOutputTokens: anthropicOutputTokens, openAIReasoningEffort: openAIReasoningEffort,
                            useWebSearch: useWebSearch, billingFeature: billingFeature)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events { if case .text(let text) = event { continuation.yield(text) } }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public enum StreamEvent: Sendable, Equatable {
        case text(String)
        /// A readable reasoning summary delta, when the provider sends one.
        case reasoning(String)
        case requestAccepted
        case routing(ConversationRouteAttempt)
        case connectionWaiting(Bool)
        /// The conversation title, when `titleRequested` and the model wrote one.
        case title(String)
        case webSearch([NativeWebSearchActivity])
        /// Always last, after a complete answer.
        case metrics(TurnMetrics)
    }

    /// The answer's text, then what AIM measured. With `titleRequested`, the model is asked to
    /// title the conversation in a hidden tag, which is removed from the text.
    public func events(provider: ChatProvider, modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode, anthropicOutputTokens: Int? = nil, openAIReasoningEffort: OpenAIReasoningEffort? = nil, useWebSearch: Bool = true, billingFeature: String? = nil, titleRequested: Bool = false, routes: [NativeChatRoute] = [], research: (any AIMResearchToolRuntime)? = nil, credentialProvider: (@Sendable () async throws -> String)? = nil) -> AsyncThrowingStream<StreamEvent, Error> {
        if let research {
            return MacResearchConversation.events(provider: provider, modelID: modelID, messages: messages, apiKey: apiKey,
                mode: mode, outputTokens: anthropicOutputTokens, effort: openAIReasoningEffort, research: research,
                session: session, meter: meter, credentialProvider: credentialProvider)
        }
        if !routes.isEmpty { return routedEvents(routes: routes, messages: messages, mode: mode, anthropicOutputTokens: anthropicOutputTokens, openAIReasoningEffort: openAIReasoningEffort, useWebSearch: useWebSearch, billingFeature: billingFeature, titleRequested: titleRequested) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if provider != .local {
                        do { try await NetworkAvailability.check() }
                        catch is NetworkAvailability.UnavailableBeforeSubmission {
                            continuation.yield(.connectionWaiting(true))
                            try await NetworkAvailability.wait { }
                            continuation.yield(.connectionWaiting(false))
                        }
                    }
                    let webEnabled = useWebSearch && NativeWebSearchRules.supports(provider: provider, modelID: modelID)
                    let outputLimit = try await ProviderModelOutput.resolve(provider: provider, modelID: modelID,
                        userLimit: provider == .anthropic ? anthropicOutputTokens : nil,
                        thinkingBudget: openAIReasoningEffort?.anthropicThinkingBudget, apiKey: apiKey, session: session)
                    let started = Date.now
                    var firstText: Date?
                    var characters = 0
                    var totalUsage = TokenUsage()
                    var totalCost: Decimal = 0
                    var allCostsKnown = true
                    var working = messages
                    var progress = ProviderResponseContinuation()
                    var webActivities: [NativeWebSearchActivity] = []
                    var sources: [ConversationSource]?
                    var webUsage: NativeWebSearchUsage? = webEnabled ? .init() : nil
                    var firstWebAttempt = true
                    while true {
                        try Task.checkCancellation()
                        let needsBound = try await meter.requiresVerifiedBound()
                        let estimatedWeb = try await meter.allowsEstimatedWebSearch()
                        try NativeWebSearchRules.requireBudgetCompatibility(enabled: webEnabled, budgetEnabled: needsBound, allowEstimatedWebSearch: estimatedWeb)
                        var request = try Self.request(provider: provider, modelID: modelID, messages: working, apiKey: apiKey,
                            mode: mode, anthropicOutputTokens: anthropicOutputTokens, openAIReasoningEffort: openAIReasoningEffort,
                            useWebSearch: webEnabled, extraInstruction: titleRequested ? ConversationTitleProtocol.instruction : nil,
                            catalogMaximumOutputTokens: outputLimit)
                        var maximumUSD: String?
                        if provider == .openRouter, needsBound {
                            let bounded = try await OpenRouterSpendQuote.prepare(request.httpBody ?? Data(), modelID: modelID, session: session, allowEstimatedWebSearch: webEnabled && estimatedWeb)
                            request.httpBody = bounded.data; maximumUSD = bounded.maximumUSD
                        }
                        if provider != .local {
                            do { try await NetworkAvailability.check() }
                            catch is NetworkAvailability.UnavailableBeforeSubmission {
                                continuation.yield(.connectionWaiting(true))
                                try await NetworkAvailability.wait { }
                                continuation.yield(.connectionWaiting(false))
                            }
                        }
                        let estimate = await ProviderSpendEstimate.resolve(provider: provider, modelID: modelID)
                        let billableRequest = request
                        let attempt = try await meter.perform(provider: provider.rawValue, modelID: modelID,
                            feature: billingFeature ?? mode.rawValue, conversationID: messages.first?.conversationID,
                            maximumUSD: maximumUSD, estimatedUSD: estimate?.reservation(body: billableRequest.httpBody ?? Data()),
                            estimatedReceiptUSD: { estimate?.completed(usage: $0.usage) }, receiptUSD: { $0.receiptUSD }) {
                            let (bytes, response) = try await session.bytes(for: billableRequest)
                            if provider == .chatgpt, (response as? HTTPURLResponse)?.statusCode == 429 { throw ChatServiceError.planLimitReached }
                            try Self.validate(response)
                            continuation.yield(.requestAccepted)
                            var complete = false
                            var truncated = false
                            var result = ProviderChatAttempt()
                            result.webSearchUsage = webEnabled ? .init() : nil
                            var titles = TitleTagFilter()
                            var searchDecoder = NativeWebSearchDecoder()
                            var searchTracker = NativeWebSearchTracker()
                            var framer = ServerSentEventFramer()
                            func emit(_ piece: (text: String, title: String?)) {
                                if let title = piece.title { continuation.yield(.title(title)) }
                                guard !piece.text.isEmpty else { return }
                                if result.firstText == nil { result.firstText = .now }
                                result.characters += piece.text.count
                                continuation.yield(.text(piece.text))
                            }
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                guard let payload = try framer.append(byte) else { continue }
                                if provider == .openRouter { result.receiptUSD = OpenRouterUsageReceipt.costUSD(in: payload) ?? result.receiptUSD }
                                if let reasoning = ProviderReasoningStream.delta(payload, provider: provider) { continuation.yield(.reasoning(reasoning)) }
                                if let usage = TokenUsageParser.parse(payload) { result.usage.merge(usage) }
                                if webEnabled {
                                    if let report = NativeWebSearchRules.usage(payload, provider: provider) { result.webSearchUsage?.merge(report) }
                                    let updates = searchTracker.consume(payload, provider: provider)
                                    if !updates.isEmpty {
                                        for activity in updates {
                                            if let index = result.webSearchActivities?.firstIndex(where: { $0.id == activity.id }) { result.webSearchActivities?[index] = activity }
                                            else { if result.webSearchActivities == nil { result.webSearchActivities = [] }; result.webSearchActivities?.append(activity) }
                                        }
                                        continuation.yield(.webSearch(updates))
                                    }
                                }
                                let chunk: ProviderStreamChunk
                                do {
                                    chunk = try webEnabled ? searchDecoder.decode(payload, provider: provider)
                                        : ProviderWireFormat.decode(payload, provider: provider)
                                } catch ChatServiceError.incompleteResponse {
                                    guard ProviderStreamTruncation.isOutputLimit(payload, provider: provider) else { throw ChatServiceError.incompleteResponse }
                                    truncated = true
                                    let tail = try ProviderStreamTruncation.text(payload, provider: provider)
                                    chunk = .init(text: tail, isComplete: ProviderStreamTruncation.isTerminal(payload, provider: provider))
                                }
                                if !chunk.text.isEmpty {
                                    result.text += chunk.text
                                    emit(titleRequested ? titles.feed(chunk.text) : (chunk.text, nil))
                                }
                                result.sources = ConversationSource.merge(result.sources, chunk.sources)
                                if chunk.isComplete { complete = true; break }
                            }
                            if titleRequested { emit(titles.finish()) }
                            try Task.checkCancellation()
                            guard complete else { throw ChatServiceError.incompleteResponse }
                            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatServiceError.emptyResponse }
                            result.truncated = truncated
                            return result
                        }
                        totalUsage.add(attempt.usage)
                        if let amount = attempt.receiptUSD.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) { totalCost += amount }
                        else { allCostsKnown = false }
                        characters += attempt.characters
                        if firstText == nil { firstText = attempt.firstText }
                        if let usage = attempt.webSearchUsage {
                            if firstWebAttempt { webUsage = usage; firstWebAttempt = false }
                            else {
                                let previous = webUsage
                                webUsage = .init(requests: previous?.requests.flatMap { prior in usage.requests.map { prior + $0 } },
                                    additionalCostUSD: previous?.additionalCostUSD.flatMap { prior in usage.additionalCostUSD.map { prior + $0 } })
                            }
                        }
                        webActivities += attempt.webSearchActivities ?? []
                        sources = ConversationSource.merge(sources, attempt.sources)
                        if !attempt.truncated { _ = try progress.completed(with: attempt.text); break }
                        try progress.appendTruncated(attempt.text)
                        let id = messages.first?.conversationID ?? UUID()
                        working.append(ConversationMessage(conversationID: id, role: .assistant, content: attempt.text, sequence: working.count))
                        working.append(ConversationMessage(conversationID: id, role: .user, content: ProviderToolConversation.continuationPrompt, sequence: working.count))
                    }
                    let finished = Date.now
                    if totalUsage.engine == nil, provider == .local, totalUsage.promptSeconds != nil { totalUsage.engine = "llama.cpp" }
                    let measured = TurnMetrics(provider: provider.rawValue, modelID: modelID, mode: mode.rawValue,
                        effort: openAIReasoningEffort?.rawValue, startedAt: started, usage: totalUsage,
                        firstTokenSeconds: firstText.map { $0.timeIntervalSince(started) }, streamSeconds: firstText.map { finished.timeIntervalSince($0) },
                        totalSeconds: finished.timeIntervalSince(started), characters: characters,
                        costUSD: allCostsKnown ? NSDecimalNumber(decimal: totalCost).doubleValue : nil,
                        webSearchUsage: webUsage, webSearchActivities: webActivities.isEmpty ? nil : webActivities, sources: sources)
                    if let speed = measured.outputTokensPerSecond, let first = measured.firstTokenSeconds, measured.outputTokens > 20 {
                        await ModelStatsStore.shared.recordSpeed(model: ModelRouting.canonicalIdentity(modelID, provider: provider), provider: provider.rawValue,
                            firstTokenSeconds: first, tokensPerSecond: speed, promptTokensPerSecond: measured.promptTokensPerSecond, engine: totalUsage.engine)
                    }
                    continuation.yield(.metrics(measured))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func models(provider: ChatProvider, apiKey: String?) async throws -> [ChatModel] {
        if provider == .openRouter { return try await OpenRouterChatService(session: session).models() }
        if provider == .local {
            // Whatever the local server has loaded or can load; no key unless the person set one.
            var request = URLRequest(url: LocalModelEndpoint.url("models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            if let apiKey, !apiKey.isEmpty, apiKey != "local" { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
                throw ChatServiceError.invalidResponse
            }
            return rows.compactMap { row in
                guard let id = row["id"] as? String, !id.lowercased().contains("embed"), !id.lowercased().contains("whisper") else { return nil }
                return ChatModel(id: id, name: id.replacingOccurrences(of: "--", with: "/"),
                                 contextLength: (row["max_model_len"] ?? row["context_length"] ?? row["max_context_length"]) as? Int)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        guard let apiKey, !apiKey.isEmpty else { throw ChatServiceError.missingKey }
        if let spec = CompatibleProviders.spec(provider) {
            let request = Self.authenticatedRequest(url: URL(string: spec.baseURL + "/models")!, provider: provider, key: apiKey)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            // Embedding, audio and image models are not chat models.
            return try CompatibleProviders.decodeModels(data).filter { model in
                !["embed", "whisper", "tts", "rerank", "guard", "moderation", "flux", "stable-diffusion", "transcrib"]
                    .contains(where: model.id.lowercased().contains)
            }
        }
        if provider == .chatgpt {
            var request = Self.authenticatedRequest(url: URL(string: "https://api.openai.com/v1/models")!, provider: provider, key: apiKey)
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            return try Self.chatGPTPlanModels(data)
        }
        var result: [ChatModel] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<20 {
            let modelsPath = provider == .perplexity ? "/router/v1/models" : (provider == .xAI ? "/v1/language-models" : (provider == .google ? "/v1beta/models" : (provider == .deepSeek ? "/models" : "/v1/models")))
            var url = URLComponents(string: "https://\(provider.host)\(modelsPath)")!
            if provider == .anthropic { url.queryItems = [.init(name: "limit", value: "100")] }
            if let cursor { url.queryItems = (url.queryItems ?? []) + [.init(name: provider == .google ? "pageToken" : "after_id", value: cursor)] }
            let request = Self.authenticatedRequest(url: url.url!, provider: provider, key: apiKey)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatServiceError.invalidResponse }
            guard let rows = json[provider == .google || provider == .xAI ? "models" : "data"] as? [[String: Any]] else { throw ChatServiceError.invalidResponse }
            for row in rows {
                guard let id = row[provider == .google ? "name" : "id"] as? String else { continue }
                if provider == .google && !(row["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { continue }
                if (provider == .openAI || provider == .chatgpt) && !Self.isTextModel(id) { continue }
                if provider == .perplexity {
                    guard id.hasPrefix("perplexity/"), !id.contains("image"), !id.contains("video") else { continue }
                    result.append(ChatModel(id: id, name: row["name"] as? String ?? id, contextLength: row["context_window"] as? Int,
                                            inputModalities: row["input_modalities"] as? [String]))
                    continue
                }
                if provider == .deepSeek || provider == .xAI {
                    if provider == .xAI, let inputs = row["input_modalities"] as? [String], !inputs.contains("text") { continue }
                    if let outputs = row["output_modalities"] as? [String], !outputs.contains("text") { continue }
                    result.append(ChatModel(id: id, name: row["name"] as? String ?? id,
                                            contextLength: row["context_window"] as? Int,
                                            inputModalities: row["input_modalities"] as? [String]))
                    continue
                }
                let model = ChatModel(id: id, name: row[provider == .google ? "displayName" : "display_name"] as? String ?? id, contextLength: row[provider == .google ? "inputTokenLimit" : "max_input_tokens"] as? Int, created: (row["created"] as? Double) ?? (row["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }, maxOutputTokens: row[provider == .anthropic ? "max_tokens" : "outputTokenLimit"] as? Int)
                result.append(model)
            }
            cursor = provider == .google ? json["nextPageToken"] as? String : (json["has_more"] as? Bool == true ? json["last_id"] as? String : nil)
            guard let next = cursor else { return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            guard seenCursors.insert(next).inserted else { throw ChatServiceError.invalidResponse }
        }
        throw ChatServiceError.invalidResponse
    }

    /// The catalog of a ChatGPT plan token: `models[]` with `slug`, `display_name` and
    /// `visibility` (only "list" entries are meant for a picker).
    static func chatGPTPlanModels(_ data: Data) throws -> [ChatModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) else {
            throw ChatServiceError.invalidResponse
        }
        var seen = Set<String>()
        return rows.compactMap { row -> ChatModel? in
            guard let slug = (row["slug"] as? String) ?? (row["id"] as? String), !slug.isEmpty,
                  (row["visibility"] as? String ?? "list") == "list", seen.insert(slug).inserted else { return nil }
            let context = (row["context_window"] as? Int) ?? (row["context_length"] as? Int) ?? (row["max_context_window"] as? Int)
            return ChatModel(id: slug, name: row["display_name"] as? String ?? slug, contextLength: context)
        }
    }

    private static func isTextModel(_ id: String) -> Bool {
        let id = id.lowercased()
        return (id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")) && !["audio", "realtime", "transcribe", "image", "tts", "search"].contains(where: id.contains)
    }
    private static func authenticatedRequest(url: URL, provider: ChatProvider, key: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ChatServiceError.http(http.statusCode) }
    }
}
