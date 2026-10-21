import Foundation

/// A piece of a model's answer as it arrives, for the live view.
public enum ToolStreamDelta: Sendable, Equatable {
    case text(String)
    case reasoning(String)
}

/// Conversations that can report their answer while it is written.
public protocol StreamingToolConversation: Sendable {
    func setStreamHandler(_ handler: (@Sendable (ToolStreamDelta) -> Void)?) async
}

/// Turns a streamed tool-capable response (server-sent events) back into the exact JSON a
/// non-streamed call returns, so decoding, history replay and receipts stay unchanged, while
/// reporting text and reasoning as they arrive. A body that is not a stream passes through.
public struct ToolStreamAssembler: @unchecked Sendable {
    public enum Wire: Sendable { case chatCompletions, anthropic, responses }

    private let wire: Wire
    private var buffer = ""
    private var sawEvent = false
    // Chat completions
    private var role = "assistant"
    private var content = ""
    private var reasoning = ""
    private var reasoningDetails: [Int: [String: Any]] = [:]
    private var detailOrder: [Int] = []
    private var toolCalls: [Int: [String: Any]] = [:]
    private var arguments: [Int: String] = [:]
    private var finishReason: Any = NSNull()
    private var usage: Any?
    private var topLevel: [String: Any] = [:]
    private var choiceError: Any?
    private var streamError: Any?
    // Anthropic
    private var message: [String: Any] = [:]
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    // Responses
    private var completed: [String: Any]?
    /// The provider's charge exactly as written: a parsed number becomes binary floating point
    /// and a cost like 0.000489 would come back as 0.00048899999999999996, which no receipt accepts.
    private var costText: String?

    public init(wire: Wire) { self.wire = wire }

    /// Feeds raw bytes; returns the deltas found in complete events.
    public mutating func feed(_ data: Data) -> [ToolStreamDelta] {
        buffer += String(decoding: data, as: UTF8.self)
        var deltas: [ToolStreamDelta] = []
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[range.upperBound...])
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            sawEvent = true
            if payload.contains("\"cost\""), let text = Self.costText(in: payload) { costText = text }
            deltas += handle(object)
        }
        return deltas
    }

    /// The equivalent non-streamed body, or the raw bytes when the answer was not a stream.
    public func response(raw: Data) throws -> Data {
        guard sawEvent else { return raw }
        switch wire {
        case .chatCompletions:
            var root = topLevel
            if let streamError { root["error"] = streamError }
            var message: [String: Any] = ["role": role]
            message["content"] = content.isEmpty && !toolCalls.isEmpty ? NSNull() : content
            if !reasoning.isEmpty { message["reasoning"] = reasoning }
            if !detailOrder.isEmpty { message["reasoning_details"] = detailOrder.compactMap { reasoningDetails[$0] } }
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.keys.sorted().map { index -> [String: Any] in
                    var call = toolCalls[index] ?? [:]
                    var function = call["function"] as? [String: Any] ?? [:]
                    function["arguments"] = arguments[index] ?? ""
                    call["function"] = function
                    if call["type"] == nil { call["type"] = "function" }
                    return call
                }
            }
            var choice: [String: Any] = ["index": 0, "message": message, "finish_reason": finishReason]
            if let choiceError { choice["error"] = choiceError }
            root["choices"] = [choice]
            if let usage { root["usage"] = exactCost(usage) }
            return try JSONSerialization.data(withJSONObject: root)
        case .anthropic:
            var root = message
            if let streamError { root["error"] = streamError }
            if let usage = root["usage"] { root["usage"] = exactCost(usage) }
            root["content"] = blocks.keys.sorted().compactMap { index -> [String: Any]? in
                guard var block = blocks[index] else { return nil }
                if block["type"] as? String == "tool_use" {
                    let text = partialJSON[index] ?? ""
                    block["input"] = text.isEmpty ? [String: Any]() : ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]())
                }
                return block
            }
            return try JSONSerialization.data(withJSONObject: root)
        case .responses:
            guard var completed else { return raw }
            if let usage = completed["usage"] { completed["usage"] = exactCost(usage) }
            return try JSONSerialization.data(withJSONObject: completed)
        }
    }

    private func exactCost(_ usage: Any) -> Any {
        guard var fields = usage as? [String: Any], fields["cost"] is NSNumber, let costText else { return usage }
        let exact = NSDecimalNumber(string: costText, locale: Locale(identifier: "en_US_POSIX"))
        guard exact != .notANumber else { return usage }
        fields["cost"] = exact
        return fields
    }

    /// The top-level `"cost": <number>` of a usage object, as text (nested costs have other names).
    static func costText(in payload: String) -> String? {
        var found: String?
        var searchRange = payload.startIndex..<payload.endIndex
        while let key = payload.range(of: "\"cost\"", range: searchRange) {
            searchRange = key.upperBound..<payload.endIndex
            guard key.lowerBound == payload.startIndex || payload[payload.index(before: key.lowerBound)] != "\\" else { continue }
            var index = key.upperBound
            while index < payload.endIndex, payload[index] == " " { index = payload.index(after: index) }
            guard index < payload.endIndex, payload[index] == ":" else { continue }
            index = payload.index(after: index)
            while index < payload.endIndex, payload[index] == " " { index = payload.index(after: index) }
            let number = payload[index...].prefix { "0123456789.eE+-".contains($0) }
            if !number.isEmpty { found = String(number) }
        }
        return found
    }

    private mutating func handle(_ object: [String: Any]) -> [ToolStreamDelta] {
        switch wire {
        case .chatCompletions: return chatChunk(object)
        case .anthropic: return anthropicEvent(object)
        case .responses: return responsesEvent(object)
        }
    }

    private mutating func chatChunk(_ object: [String: Any]) -> [ToolStreamDelta] {
        if let error = object["error"] { streamError = error; return [] }
        for key in ["id", "model", "provider", "object", "created", "system_fingerprint"] where object[key] != nil { topLevel[key] = object[key] }
        if let value = object["usage"], !(value is NSNull) { usage = value }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        if let error = choice["error"] { choiceError = error }
        if let reason = choice["finish_reason"], !(reason is NSNull) { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] else { return [] }
        var out: [ToolStreamDelta] = []
        if let value = delta["role"] as? String { role = value }
        if let text = delta["content"] as? String, !text.isEmpty { content += text; out.append(.text(text)) }
        for key in ["reasoning", "reasoning_content"] {
            if let text = delta[key] as? String, !text.isEmpty { reasoning += text; out.append(.reasoning(text)) }
        }
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            for (position, detail) in details.enumerated() {
                let index = detail["index"] as? Int ?? position
                if reasoningDetails[index] == nil { detailOrder.append(index) }
                var merged = reasoningDetails[index] ?? [:]
                for (key, value) in detail {
                    // Text pieces add up; every other field (type, format, signature, id) is the latest.
                    if ["text", "summary", "data"].contains(key), let piece = value as? String {
                        merged[key] = ((merged[key] as? String) ?? "") + piece
                    } else { merged[key] = value }
                }
                reasoningDetails[index] = merged
            }
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for (position, call) in calls.enumerated() {
                let index = call["index"] as? Int ?? position
                var current = toolCalls[index] ?? [:]
                if let id = call["id"] as? String, !id.isEmpty { current["id"] = id }
                if let type = call["type"] { current["type"] = type }
                if let function = call["function"] as? [String: Any] {
                    var stored = current["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String, !name.isEmpty { stored["name"] = name }
                    if let piece = function["arguments"] as? String { arguments[index, default: ""] += piece }
                    current["function"] = stored
                }
                toolCalls[index] = current
            }
        }
        return out
    }

    private mutating func anthropicEvent(_ object: [String: Any]) -> [ToolStreamDelta] {
        switch object["type"] as? String {
        case "message_start":
            message = object["message"] as? [String: Any] ?? [:]
            message.removeValue(forKey: "content")
        case "content_block_start":
            if let index = object["index"] as? Int, let block = object["content_block"] as? [String: Any] { blocks[index] = block }
        case "content_block_delta":
            guard let index = object["index"] as? Int, let delta = object["delta"] as? [String: Any], var block = blocks[index] else { return [] }
            defer { blocks[index] = block }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block["text"] = ((block["text"] as? String) ?? "") + text
                return text.isEmpty ? [] : [.text(text)]
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                block["thinking"] = ((block["thinking"] as? String) ?? "") + text
                return text.isEmpty ? [] : [.reasoning(text)]
            case "signature_delta":
                block["signature"] = ((block["signature"] as? String) ?? "") + (delta["signature"] as? String ?? "")
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any] {
                for (key, value) in delta { message[key] = value }
            }
            if let more = object["usage"] as? [String: Any] {
                var current = message["usage"] as? [String: Any] ?? [:]
                for (key, value) in more { current[key] = value }
                message["usage"] = current
            }
        case "error":
            streamError = object["error"] ?? object
        default: break
        }
        return []
    }

    private mutating func responsesEvent(_ object: [String: Any]) -> [ToolStreamDelta] {
        switch object["type"] as? String {
        case "response.output_text.delta":
            if let text = object["delta"] as? String, !text.isEmpty { return [.text(text)] }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let text = object["delta"] as? String, !text.isEmpty { return [.reasoning(text)] }
        case "response.completed", "response.incomplete", "response.failed":
            completed = object["response"] as? [String: Any]
        default: break
        }
        return []
    }
}
