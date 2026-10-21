import Foundation
import CoreFoundation

/// Provider-reported cumulative tool usage. Nil is unknown, never a free search.
public struct NativeWebSearchUsage: Codable, Equatable, Sendable {
    public var requests: Int?
    /// Extra tool fees only. May be estimated from an official request counter and documented rate.
    public var additionalCostUSD: Double?
    /// Provider-reported whole-request charge, including model/tool costs. Never add token estimates or
    /// additionalCostUSD to this amount. Nil means unavailable, not zero. OpenRouter usage.cost only;
    /// upstream_inference_cost is not the charge to the person's account.
    public var providerTotalCostUSD: Double?
    /// Independent search-provider metadata, recorded separately by the host. Never part of a model invoice.
    public var externalSearchCostUSD: Double?
    public var externalCostsTrackedSeparately: Bool?
    /// A complete cumulative snapshot across distinct provider requests. Its unknown fields replace
    /// earlier partial totals; nil preserves legacy same-request, field-by-field merge semantics.
    public var isRequestAggregate: Bool?
    public init(requests: Int? = nil, additionalCostUSD: Double? = nil, providerTotalCostUSD: Double? = nil,
                isRequestAggregate: Bool? = nil, externalSearchCostUSD: Double? = nil,
                externalCostsTrackedSeparately: Bool? = nil) {
        self.requests = requests; self.additionalCostUSD = additionalCostUSD
        self.providerTotalCostUSD = providerTotalCostUSD; self.isRequestAggregate = isRequestAggregate
        self.externalSearchCostUSD = externalSearchCostUSD; self.externalCostsTrackedSeparately = externalCostsTrackedSeparately
    }
    public mutating func merge(_ other: Self) {
        if other.isRequestAggregate == true { self = other; return }
        if let requests = other.requests { self.requests = requests }
        if let cost = other.additionalCostUSD { additionalCostUSD = cost }
        if let total = other.providerTotalCostUSD { providerTotalCostUSD = total }
        if let external = other.externalSearchCostUSD { externalSearchCostUSD = external }
        if let separate = other.externalCostsTrackedSeparately { externalCostsTrackedSeparately = separate }
    }
}

/// Adds distinct provider requests within a tool turn. A missing field in any request makes that
/// aggregate unknown. Use NativeWebSearchUsage.merge for cumulative events of the SAME request.
public struct NativeWebSearchUsageAccumulator: Sendable {
    public private(set) var usage = NativeWebSearchUsage()
    private var hasRequest = false
    public init() {}
    public mutating func append(_ next: NativeWebSearchUsage?) {
        let value = NativeWebSearchUsage(
            requests: next?.requests.flatMap { $0 >= 0 ? $0 : nil },
            additionalCostUSD: next?.additionalCostUSD.flatMap(Self.validCost),
            providerTotalCostUSD: next?.providerTotalCostUSD.flatMap(Self.validCost), isRequestAggregate: true)
        guard hasRequest else { usage = value; hasRequest = true; return }
        let requests: Int?
        if let first = usage.requests, let second = value.requests {
            let sum = first.addingReportingOverflow(second)
            requests = sum.overflow ? nil : sum.partialValue
        } else { requests = nil }
        usage = .init(requests: requests,
            additionalCostUSD: Self.sum(usage.additionalCostUSD, value.additionalCostUSD),
            providerTotalCostUSD: Self.sum(usage.providerTotalCostUSD, value.providerTotalCostUSD), isRequestAggregate: true)
    }
    private static func validCost(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
    private static func sum(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second else { return nil }
        return validCost(first + second)
    }
}

/// Only structured provider events populate this list. A prose claim that the
/// model searched never becomes a tool execution record.
public struct NativeWebSearchActivity: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case running, completed, failed }
    public let id: String
    public var status: Status
    public var input: String?
    public var output: String?
    public init(id: String, status: Status, input: String? = nil, output: String? = nil) { self.id = id; self.status = status; self.input = input; self.output = output }
}

/// Hosted search only. This never enables client tools, code execution, X Search or MCP.
public enum NativeWebSearchRules {
    public static func supports(provider: ChatProvider, modelID: String) -> Bool {
        switch provider {
        case .openRouter:
            // OpenRouter operates its search tool for any model. The engine is fixed below.
            return !modelID.isEmpty && !modelID.contains(":online")
        case .perplexity:
            // Agent API model IDs are provider-qualified; never substitute legacy Sonar.
            return modelID.split(separator: "/").count == 2
        case .openAI:
            return matches(modelID, aliases: ["gpt-4.1", "gpt-4.1-mini", "gpt-5", "gpt-5-mini", "gpt-5-nano",
                "gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5",
                "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "o3", "o4-mini"])
        case .anthropic:
            return matches(modelID, aliases: ["claude-sonnet-4-5", "claude-sonnet-4-6", "claude-sonnet-5", "claude-sonnet-5-5",
                "claude-haiku-4-5", "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                "claude-opus-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1"])
        case .xAI:
            return matches(modelID, aliases: ["grok-4", "grok-4-fast", "grok-4-fast-reasoning", "grok-4-fast-non-reasoning",
                "grok-4-1-fast-reasoning", "grok-4-1-fast-non-reasoning", "grok-4.6", "grok-4.7"])
        default: return false
        }
    }
    public static func requireCompatibility(provider: ChatProvider, modelID: String) throws {
        guard supports(provider: provider, modelID: modelID) else { throw ChatServiceError.unsupportedWebSearch }
    }
    public static func requireBudgetCompatibility(enabled: Bool, budgetEnabled: Bool, allowEstimatedWebSearch: Bool = false) throws {
        // Search loops add provider-controlled input tokens. A call/result limit alone
        // is not a verified upper bound on all billable model and search tokens.
        if enabled && budgetEnabled && !allowEstimatedWebSearch { throw ChatServiceError.webSearchBudgetUnavailable }
    }
    public static func costDescription(provider: ChatProvider, modelID: String) -> String {
        guard supports(provider: provider, modelID: modelID) else {
            return provider == .google ? "Google search requires a grounding display that AIM does not yet support. Chat remains available."
                : "Choose a compatible model to enable search. Chat remains available."
        }
        switch provider {
        case .openRouter: return "Your OpenRouter credits pay for Exa searches and model tokens at current provider rates. Provider-reported charges are used when available."
        case .openAI, .anthropic: return "Your provider bills searches plus model and search-content tokens at its current rates."
        case .xAI: return "Your xAI account bills successful searches or page access plus model tokens at its current rates."
        case .perplexity: return "Your Perplexity account bills searches plus model tokens at its current rates."
        default: return "Search cost unavailable."
        }
    }
    public static func tool(provider: ChatProvider) -> [String: Any] {
        switch provider {
        case .openRouter:
            // Never use 'auto': it can silently change the search engine and its bill.
            return ["type": "openrouter:web_search", "parameters": ["engine": "exa"]]
        case .anthropic:
            // The basic version does not grant dynamic filtering / code execution.
            return ["type": "web_search_20250305", "name": "web_search"]
        case .xAI: return ["type": "web_search", "enable_image_understanding": false, "enable_image_search": false]
        case .perplexity: return ["type": "web_search", "search_type": "web"]
        default: return ["type": "web_search"]
        }
    }
    public static func activities(_ payload: String, provider: ChatProvider) -> [NativeWebSearchActivity] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return [] }
        if provider == .anthropic {
            let message = root["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? (root["content_block"] as? [String: Any]).map { [$0] } ?? []
            return blocks.compactMap { block in
                if block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search", let id = block["id"] as? String {
                    return .init(id: id, status: .running, input: (block["input"] as? [String: Any])?["query"] as? String)
                }
                if block["type"] as? String == "web_search_tool_result", let id = block["tool_use_id"] as? String {
                    return .init(id: id, status: block["content"] is [String: Any] ? .failed : .completed, output: publicJSON(block["content"]))
                }
                return nil
            }
        }
        let type = root["type"] as? String ?? ""
        if type.hasPrefix("response.web_search_call."), let id = root["item_id"] as? String {
            return [.init(id: id, status: type.hasSuffix("completed") ? .completed : type.hasSuffix("failed") ? .failed : .running,
                          input: publicJSON(root["action"]), output: publicJSON(root["results"]))]
        }
        let response = root["response"] as? [String: Any]
        let items = response?["output"] as? [[String: Any]] ?? (root["item"] as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            guard item["type"] as? String == "web_search_call", let id = item["id"] as? String else { return nil }
            let status = item["status"] as? String
            let completed = status == "completed" || (status == nil && ["response.output_item.done", "response.completed"].contains(type))
            return .init(id: id, status: completed ? .completed : status == "failed" ? .failed : .running, input: publicJSON(item["action"]), output: publicJSON(item["results"]))
        }
    }

    private static func publicJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return nil }
        return ConversationAction.redact(text)
    }

    public static func usage(_ payload: String, provider: ChatProvider) -> NativeWebSearchUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        let response = root["response"] as? [String: Any]
        let message = root["message"] as? [String: Any]
        let usage = (response?["usage"] ?? root["usage"] ?? message?["usage"]) as? [String: Any]
        let count: Int?
        let rate: Double
        switch provider {
        case .openRouter:
            guard let usage else { return nil }
            count = integer((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
            // OpenRouter documents usage.cost as the whole amount charged to the account.
            // Search counts alone cannot capture engine modes, extra results or current rates.
            return .init(requests: count, additionalCostUSD: count == 0 ? 0 : nil,
                         providerTotalCostUSD: money(usage["cost"]))
        case .anthropic:
            guard ["message", "message_start", "message_delta"].contains(root["type"] as? String ?? ""), let usage else { return nil }
            count = integer((usage["server_tool_use"] as? [String: Any])?["web_search_requests"]); rate = 0.01
        case .perplexity:
            guard root["type"] as? String == "response.completed" else { return nil }
            let details = usage?["tool_calls_details"] as? [String: Any]
            count = integer((details?["search_web"] as? [String: Any])?["invocation"]); rate = 0.0025
        case .openAI:
            guard root["type"] as? String == "response.completed", let items = response?["output"] as? [[String: Any]] else { return nil }
            let actions = items.filter { $0["type"] as? String == "web_search_call" }.map { ($0["action"] as? [String: Any])?["type"] as? String }
            count = actions.allSatisfy { ["search", "open_page", "find_in_page"].contains($0 ?? "") }
                ? actions.filter { $0 == "search" }.count : nil
            rate = 0.01
        case .xAI:
            guard root["type"] as? String == "response.completed" else { return nil }
            // Attempted output calls are not authoritative: xAI charges successful calls.
            let details = usage?["server_side_tool_usage_details"] as? [String: Any]
            let categories = response?["server_side_tool_usage"] as? [String: Any]
            count = integer(details?["web_search_calls"] ?? categories?["SERVER_SIDE_TOOL_WEB_SEARCH"]); rate = 0.005
        default: return nil
        }
        // OpenAI additionally bills retrieved search content (fixed 8K blocks on
        // some models). Its search-call output alone cannot reconcile those tokens
        // with the model's usage total. Retain the count without inventing a total.
        let cost = provider == .openAI && (count ?? 0) > 0 ? nil : count.map { Double($0) * rate }
        return .init(requests: count, additionalCostUSD: cost)
    }
    private static func money(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1_000_000).contains(number.doubleValue),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func matches(_ id: String, aliases: [String]) -> Bool {
        aliases.contains { alias in
            if id == alias { return true }
            guard id.hasPrefix(alias + "-") else { return false }
            let suffix = id.dropFirst(alias.count + 1)
            return (suffix.count == 8 && suffix.allSatisfy(\.isNumber)) ||
                (suffix.count == 10 && suffix.enumerated().allSatisfy { offset, char in
                    offset == 4 || offset == 7 ? char == "-" : char.isASCII && char.isNumber
                })
        }
    }
}

/// Citation metadata becomes safe, persisted Markdown; the existing chat renderer
/// and exports retain the same original-source links after reopening a conversation.
public struct NativeWebSearchDecoder: Sendable {
    private var sources: [(url: String, title: String)] = []
    private var seen = Set<String>()
    private var finished = false
    private var hasAnswer = false
    public init() {}
    public mutating func decode(_ payload: String, provider: ChatProvider) throws -> ProviderStreamChunk {
        guard !finished else { return .init() }
        let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        if let json {
            if provider == .anthropic { try collectAnthropic(json) }
            else if provider == .openRouter { try collectOpenRouter(json) }
            else if provider == .openAI || provider == .xAI { try collectResponses(json) }
        }
        var chunk = try ProviderWireFormat.decode(payload, provider: provider, allowWebSearch: true)
        hasAnswer = hasAnswer || (!chunk.text.isEmpty && !chunk.isComplete)
        if chunk.isComplete {
            // A source list alone is not an answer. Some gateways send only the final
            // Responses message, so retain that text when there were no text deltas.
            if !hasAnswer, provider == .openAI || provider == .xAI,
               let response = json?["response"] as? [String: Any] {
                chunk.text = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
                    .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["text"] as? String ?? $0["refusal"] as? String }.joined()
                hasAnswer = !chunk.text.isEmpty
            }
            guard hasAnswer else { throw ChatServiceError.emptyResponse }
            finished = true

        }
        chunk.sources = ConversationSource.merge(chunk.sources, sources.enumerated().compactMap { index, source in ConversationSource(url: source.url, title: source.title, references: [index + 1]) })
        return chunk
    }
    private mutating func collectResponses(_ json: [String: Any]) throws {
        if let type = json["type"] as? String,
           ["response.code_interpreter_call.", "response.mcp_call.", "response.computer_call."].contains(where: type.hasPrefix) {
            throw ChatServiceError.unsupportedTools
        }
        if let annotation = json["annotation"] as? [String: Any] { try collectAnnotation(annotation) }
        let response = json["response"] as? [String: Any]
        let items = response?["output"] as? [[String: Any]] ?? (json["item"] as? [String: Any]).map { [$0] } ?? []
        for item in items {
            for content in item["content"] as? [[String: Any]] ?? [] {
                for annotation in content["annotations"] as? [[String: Any]] ?? [] { try collectAnnotation(annotation) }
            }
        }
        for rawURL in response?["citations"] as? [String] ?? [] { try add(url: rawURL, title: nil) }
    }
    private mutating func collectOpenRouter(_ json: [String: Any]) throws {
        for choice in json["choices"] as? [[String: Any]] ?? [] {
            for value in [choice["delta"], choice["message"]] {
                guard let message = value as? [String: Any] else { continue }
                for annotation in message["annotations"] as? [[String: Any]] ?? [] { try collectAnnotation(annotation) }
            }
        }
    }
    private mutating func collectAnnotation(_ annotation: [String: Any]) throws {
        guard annotation["type"] as? String == "url_citation" else { return }
        let citation = annotation["url_citation"] as? [String: Any] ?? annotation
        guard let url = citation["url"] as? String else { throw ChatServiceError.invalidResponse }
        try add(url: url, title: citation["title"] as? String)
    }
    private mutating func collectAnthropic(_ json: [String: Any]) throws {
        let delta = json["delta"] as? [String: Any]
        if delta?["stop_reason"] as? String == "pause_turn" { throw ChatServiceError.incompleteResponse }
        if let citation = delta?["citation"] as? [String: Any], citation["type"] as? String == "web_search_result_location" {
            guard let url = citation["url"] as? String else { throw ChatServiceError.invalidResponse }
            try add(url: url, title: citation["title"] as? String)
        }
        let message = json["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? (json["content_block"] as? [String: Any]).map { [$0] } ?? []
        for block in blocks {
            switch block["type"] as? String {
            case "server_tool_use":
                guard block["name"] as? String == "web_search" else { throw ChatServiceError.unsupportedTools }
            case "web_search_tool_result":
                if block["content"] is [String: Any] { throw ChatServiceError.webSearchFailed }
                guard let results = block["content"] as? [[String: Any]],
                      results.allSatisfy({ $0["type"] as? String == "web_search_result" }) else { throw ChatServiceError.invalidResponse }
            case "text", "thinking", "redacted_thinking": break
            default: throw ChatServiceError.unsupportedTools
            }
            for citation in block["citations"] as? [[String: Any]] ?? [] where citation["type"] as? String == "web_search_result_location" {
                guard let url = citation["url"] as? String else { throw ChatServiceError.invalidResponse }
                try add(url: url, title: citation["title"] as? String)
            }
        }
    }
    private mutating func add(url raw: String, title: String?) throws {
        guard raw.utf8.count <= 8192, raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.init(charactersIn: "()<>\\"))) == nil,
              let url = URLComponents(string: raw), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw ChatServiceError.invalidResponse }
        guard seen.insert(raw).inserted else { return }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        sources.append((raw, name?.isEmpty == false ? name! : host))
    }
    private static func escape(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

/// Joins public streamed inputs with their exact invocation. Terminal updates
/// enrich the same record and never manufacture another tool action.
public struct NativeWebSearchTracker: Sendable {
    private var indexes: [Int: String] = [:]
    private var fragments: [Int: String] = [:]
    private var values: [String: NativeWebSearchActivity] = [:]
    public init() {}
    public mutating func consume(_ payload: String, provider: ChatProvider) -> [NativeWebSearchActivity] {
        var updates = NativeWebSearchRules.activities(payload, provider: provider)
        if provider == .anthropic,
           let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           let index = root["index"] as? Int {
            if let block = root["content_block"] as? [String: Any], block["type"] as? String == "server_tool_use",
               block["name"] as? String == "web_search", let id = block["id"] as? String { indexes[index] = id; fragments[index] = "" }
            if let id = indexes[index], let delta = root["delta"] as? [String: Any],
               delta["type"] as? String == "input_json_delta", let part = delta["partial_json"] as? String {
                let text = (fragments[index] ?? "") + part
                if text.utf8.count <= 16_384 {
                    fragments[index] = text
                    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let query = object["query"] as? String {
                        updates.append(.init(id: id, status: .running, input: ConversationAction.redact(query)))
                    }
                } else { fragments[index] = nil; indexes[index] = nil }
            }
        }
        return updates.map { incoming in
            var value = incoming
            if let previous = values[value.id] {
                value.input = value.input ?? previous.input; value.output = value.output ?? previous.output
                if previous.status != .running && value.status == .running { value.status = previous.status }
            }
            values[value.id] = value; return value
        }
    }
}
