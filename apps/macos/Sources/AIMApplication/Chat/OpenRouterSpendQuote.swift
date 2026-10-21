import Foundation

/// Native, pre-send pricing for text/tool requests. The input bound is the request's
/// own byte size (a token is never shorter than a byte), including tool schemas and
/// reasoning replay, capped by the model's context. Routing enforces these prices.
struct OpenRouterSpendQuote: Sendable {
    let inputUSD: Decimal
    let outputUSD: Decimal
    let contextTokens: Int
    let outputTokens: Int

    struct BoundedBody: Sendable { let data: Data; let maximumUSD: String? }

    /// An unknown quote never grants an exception. The original request and a
    /// nil bound go to the existing ledger/broker, which can refuse admission.
    static func prepare(_ body: Data, modelID: String, session: URLSession, allowEstimatedWebSearch: Bool = false) async throws -> BoundedBody {
        try await prepare(body, modelID: modelID, allowEstimatedWebSearch: allowEstimatedWebSearch, quote: { try await fetch(modelID: modelID, session: session) })
    }

    static func prepare(_ body: Data, modelID: String, allowEstimatedWebSearch: Bool = false,
                        quote: @Sendable () async throws -> Self) async throws -> BoundedBody {
        do { return try await quote().bound(body, modelID: modelID, allowEstimatedWebSearch: allowEstimatedWebSearch) }
        catch SpendAdmissionError.unknownBound {
            try Task.checkCancellation()
            return BoundedBody(data: body, maximumUSD: nil)
        } catch let error as URLError where error.code != .cancelled {
            try Task.checkCancellation()
            try RuntimePrivacyPolicy.requireNetwork()
            return BoundedBody(data: body, maximumUSD: nil)
        }
    }

    static func fetch(modelID: String, session: URLSession) async throws -> Self {
        try RuntimePrivacyPolicy.requireNetwork()
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        try RuntimePrivacyPolicy.requireEndpoint(url)
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpendAdmissionError.unknownBound }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_777_216 else { throw SpendAdmissionError.unknownBound }
            data.append(byte)
        }
        return try decode(data, modelID: modelID)
    }

    static func decode(_ data: Data, modelID: String) throws -> Self {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["data"] as? [[String: Any]],
              let row = rows.first(where: { $0["id"] as? String == modelID }),
              let pricing = row["pricing"] as? [String: Any],
              let context = row["context_length"] as? Int, context > 0, context <= 10_000_000,
              (row["supported_parameters"] as? [String])?.contains("max_tokens") == true else {
            throw SpendAdmissionError.unknownBound
        }
        // Prices can vary by prompt-size tier ("overrides"); the bound takes the highest of every tier.
        let tiers = [pricing] + ((pricing["overrides"] as? [[String: Any]]) ?? [])
        var input: Decimal = 0, output: Decimal = 0
        for tier in tiers {
            for (key, raw) in tier where key != "overrides" && !["min_prompt_tokens", "max_prompt_tokens"].contains(key) {
                guard let text = raw as? String, let value = decimal(text) else { throw SpendAdmissionError.unknownBound }
                switch key {
                // Writing the prompt to the provider's cache can cost more than reading it: the input
                // bound uses the highest of the three, so caching never exceeds the admitted amount.
                case "prompt", "input_cache_write", "input_cache_write_1h", "input_cache_read": input = max(input, value)
                case "completion": output = max(output, value)
                // Fees of hosted options AIM never enables in these requests (web plugin): the body
                // check below refuses plugins, so they cannot apply.
                case "web_search": continue
                // Fixed or media fees (request, image, audio…) cannot be bounded by token prices.
                default: guard value == 0 else { throw SpendAdmissionError.unknownBound }
                }
            }
        }
        guard pricing["prompt"] is String, pricing["completion"] is String else { throw SpendAdmissionError.unknownBound }
        let top = row["top_provider"] as? [String: Any]
        guard let maximum = top?["max_completion_tokens"] as? Int else { throw SpendAdmissionError.unknownBound }
        let outputLimit = min(maximum, context)
        guard outputLimit > 0 else { throw SpendAdmissionError.unknownBound }
        return Self(inputUSD: input, outputUSD: output, contextTokens: context, outputTokens: outputLimit)
    }

    static let defaultOutputTokens = 32_000

    func bound(_ data: Data, modelID: String, allowEstimatedWebSearch: Bool = false) throws -> BoundedBody {
        guard var body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              body["model"] as? String == modelID,
              var messages = body["messages"] as? [[String: Any]], !messages.isEmpty else { throw SpendAdmissionError.unknownBound }
        let fields: Set<String> = ["model", "messages", "stream", "stream_options", "tools", "tool_choice", "parallel_tool_calls", "reasoning", "provider", "usage", "temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "stop", "seed", "max_tokens", "max_completion_tokens"]
        guard Set(body.keys).isSubset(of: fields) else { throw SpendAdmissionError.unknownBound }
        if body["tools"] != nil {
            guard let tools = body["tools"] as? [[String: Any]] else { throw SpendAdmissionError.unknownBound }
            for tool in tools {
                if tool["type"] as? String == "function" { continue }
                // Only AIM's supported hosted tool is estimated. Unknown tools,
                // engines or extensions never acquire a false verified bound.
                guard allowEstimatedWebSearch, Set(tool.keys) == ["type", "parameters"],
                      tool["type"] as? String == "openrouter:web_search",
                      let parameters = tool["parameters"] as? [String: Any],
                      Set(parameters.keys) == ["engine"], parameters["engine"] as? String == "exa" else {
                    throw SpendAdmissionError.unknownBound
                }
            }
        }
        let messageFields: Set<String> = ["role", "content", "name", "tool_calls", "tool_call_id", "reasoning", "reasoning_content", "reasoning_details", "refusal", "annotations", "model"]
        for index in messages.indices {
            var message = messages[index]
            guard Set(message.keys).isSubset(of: messageFields) else { throw SpendAdmissionError.unknownBound }
            // Echoed assistant response metadata is still text input covered by
            // the whole-context bound. This does not enable web plugins/media.
            if let model = message["model"] {
                guard message["role"] as? String == "assistant", model is String else { throw SpendAdmissionError.unknownBound }
            }
            if let refusal = message["refusal"] {
                guard message["role"] as? String == "assistant", refusal is String || refusal is NSNull else { throw SpendAdmissionError.unknownBound }
            }
            if let annotations = message["annotations"] {
                guard message["role"] as? String == "assistant" else { throw SpendAdmissionError.unknownBound }
                if !(annotations is NSNull) {
                    guard let citations = annotations as? [[String: Any]], citations.allSatisfy(Self.isTextCitation) else {
                        throw SpendAdmissionError.unknownBound
                    }
                }
            }
            if message["content"] == nil {
                // OpenRouter permits a tool-call-only assistant message. Do not
                // generalize omitted content to user/tool or malformed messages.
                guard message["role"] as? String == "assistant",
                      let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty,
                      calls.allSatisfy({ call in
                          guard call["type"] as? String == "function", let id = call["id"] as? String, !id.isEmpty,
                                let function = call["function"] as? [String: Any],
                                let name = function["name"] as? String, !name.isEmpty else { return false }
                          return function["arguments"] is String
                      }) else { throw SpendAdmissionError.unknownBound }
                message["content"] = NSNull()
                messages[index] = message
            }
            guard let content = message["content"] else { throw SpendAdmissionError.unknownBound }
            if content is String || content is NSNull { continue }
            guard let parts = content as? [[String: Any]], !parts.isEmpty,
                  parts.allSatisfy({ Set($0.keys).isSubset(of: ["type", "text", "cache_control"]) && $0["type"] as? String == "text" && $0["text"] is String }) else {
                throw SpendAdmissionError.unknownBound
            }
        }
        body["messages"] = messages
        var requestedLimit: Int?
        for key in ["max_tokens", "max_completion_tokens"] where body[key] != nil {
            guard let requested = body[key] as? Int, requested > 0, requested <= outputTokens else { throw SpendAdmissionError.unknownBound }
            requestedLimit = min(requestedLimit ?? requested, requested)
        }
        // Without an explicit limit, one request may write up to 32k tokens (long answers continue
        // in a follow-up request), so a spending limit reserves a realistic amount, not the
        // model's whole output capacity.
        let limit = requestedLimit ?? min(outputTokens, Self.defaultOutputTokens)
        body.removeValue(forKey: "max_completion_tokens"); body["max_tokens"] = limit
        body["provider"] = ["require_parameters": true, "allow_fallbacks": false,
            "max_price": ["prompt": NSDecimalNumber(decimal: inputUSD * 1_000_000),
                          "completion": NSDecimalNumber(decimal: outputUSD * 1_000_000), "request": 0, "image": 0]]
        body["usage"] = ["include": true]
        if body["stream"] as? Bool == true { body["stream_options"] = ["include_usage": true] }
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // Every token stands for at least one byte of the text sent, so the request's own size
        // bounds its input tokens (plus the chat template's markers per message); never more
        // than the model's context. Media, the only exception, is refused above.
        let inputTokens = min(contextTokens, encoded.count + 1_024 + 64 * messages.count)
        let bound = inputUSD * Decimal(inputTokens) + outputUSD * Decimal(limit)
        guard !bound.isNaN, bound >= 0, bound <= 1_000_000 else { throw SpendAdmissionError.unknownBound }
        return BoundedBody(data: encoded, maximumUSD: NSDecimalNumber(decimal: bound).stringValue)
    }

    /// Only the documented URL-citation metadata shape is priced as text.
    /// Unknown annotation types/extensions remain unknown, like message media.
    private static func isTextCitation(_ annotation: [String: Any]) -> Bool {
        guard Set(annotation.keys).isSubset(of: ["type", "url_citation"]), annotation["type"] as? String == "url_citation",
              let citation = annotation["url_citation"] as? [String: Any],
              Set(citation.keys).isSubset(of: ["url", "title", "content", "start_index", "end_index"]),
              citation["url"] is String, citation["title"] is String else { return false }
        for key in ["content"] where citation[key] != nil { guard citation[key] is String else { return false } }
        for key in ["start_index", "end_index"] where citation[key] != nil { guard citation[key] is Int else { return false } }
        return true
    }

    private static func decimal(_ text: String?) -> Decimal? {
        guard let text, text.range(of: "^[0-9]+(?:\\.[0-9]{1,18})?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0, value <= 1 else { return nil }
        return value
    }
}
