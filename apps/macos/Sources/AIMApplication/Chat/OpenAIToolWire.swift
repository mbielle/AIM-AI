import Foundation

/// Responses has output items, not a Chat Completions assistant message.
/// The shared transport owns bounds and state; this codec only maps the native wire format.
/// Also used by xAI's Responses endpoint; provider hosts and credentials remain separate.
enum OpenAIToolWire {
    static func schema(_ tool: ModelToolDefinition) -> [String: Any] {
        var properties: [String: Any] = [:]
        for key in tool.requiredArguments { properties[key] = (tool.argumentKinds[key] ?? .string).schema() }
        for key in tool.optionalArguments { properties[key] = (tool.argumentKinds[key] ?? .string).schema(optional: true) }
        return ["type": "function", "name": tool.name, "description": tool.description, "strict": true,
            "parameters": ["type": "object", "properties": properties,
                "required": tool.requiredArguments.union(tool.optionalArguments).sorted(), "additionalProperties": false]]
    }

    static func decode(_ data: Data, tools: [ModelToolDefinition]) throws -> (turn: ModelToolTurn, items: [[String: Any]]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["object"] as? String == "response", root["status"] as? String == "completed",
              root["error"] == nil || root["error"] is NSNull,
              let items = root["output"] as? [[String: Any]] else { throw ModelToolError.invalidProtocol }
        var texts: [String] = []
        var calls: [ModelToolCall] = []
        var summaries: [String] = []
        for item in items {
            if let status = item["status"] as? String, status != "completed" { throw ModelToolError.invalidProtocol }
            switch item["type"] as? String {
            case "reasoning":
                // Replay the item unchanged; only its readable summary is shown.
                summaries += (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            case "function_call":
                guard let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 256, !id.contains("\0"),
                      let name = item["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let raw = item["arguments"] as? String else { throw ModelToolError.invalidProtocol }
                let arguments = try ToolJSONValue.decodeObject(Data(raw.utf8))
                let normalized = try tools.first(where: { $0.name == name })?.normalized(arguments) ?? arguments
                calls.append(ModelToolCall(id: id, name: name, jsonArguments: normalized))
            case "message":
                guard item["role"] as? String == "assistant", let content = item["content"] as? [[String: Any]] else { throw ModelToolError.invalidProtocol }
                for part in content {
                    let key: String
                    switch part["type"] as? String {
                    case "output_text": key = "text"
                    case "refusal": key = "refusal"
                    default: throw ModelToolError.invalidProtocol
                    }
                    guard let text = part[key] as? String else { throw ModelToolError.invalidProtocol }
                    texts.append(text)
                }
            default: throw ModelToolError.invalidProtocol // No hosted shell, browser, MCP or other server tools registered.
            }
        }
        let text = texts.joined(separator: "\n\n")
        guard Set(calls.map(\.id)).count == calls.count,
              !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelToolError.invalidProtocol }
        return (ModelToolTurn(text: text, calls: calls, reasoning: summaries.joined(separator: "\n\n")), items)
    }
}
