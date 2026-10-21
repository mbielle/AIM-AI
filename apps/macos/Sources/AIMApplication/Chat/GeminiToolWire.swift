import Foundation

enum GeminiToolWire {
    struct CallReference: Codable, Sendable {
        let localID: String
        let name: String
        let wireID: String?
    }

    static func endpoint(modelID: String) throws -> String {
        let name = modelID.hasPrefix("models/") ? String(modelID.dropFirst(7)) : modelID
        guard !name.isEmpty, !name.contains(".."), name.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }) else { throw ModelToolError.invalidConfiguration }
        return "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent"
    }

    static func schema(_ tool: ModelToolDefinition) -> [String: Any] {
        let properties = Dictionary(uniqueKeysWithValues: tool.requiredArguments.union(tool.optionalArguments).map {
            ($0, (tool.argumentKinds[$0] ?? .string).schema())
        })
        return ["name": tool.name, "description": tool.description,
            "parametersJsonSchema": ["type": "object", "properties": properties,
                "required": tool.requiredArguments.sorted(), "additionalProperties": false]]
    }

    static func result(_ output: ModelToolOutput, reference: CallReference) -> [String: Any] {
        var response: [String: Any] = ["name": reference.name,
            "response": [output.isError ? "error" : "output": output.providerContent]]
        if let id = reference.wireID { response["id"] = id }
        return ["functionResponse": response]
    }

    static func decode(_ data: Data, tools: [ModelToolDefinition] = []) throws -> (turn: ModelToolTurn, content: [String: Any], references: [CallReference]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              (root["promptFeedback"] as? [String: Any])?["blockReason"] == nil,
              let candidates = root["candidates"] as? [[String: Any]], candidates.count == 1,
              candidates[0]["finishReason"] as? String == "STOP",
              let content = candidates[0]["content"] as? [String: Any], content["role"] as? String == "model",
              let parts = content["parts"] as? [[String: Any]] else { throw ModelToolError.invalidProtocol }
        var texts: [String] = []
        var calls: [ModelToolCall] = []
        var references: [CallReference] = []
        for part in parts {
            // A Part is a union. Do not treat unknown code/media/server tools as harmless text.
            guard Set(part.keys).isSubset(of: ["text", "functionCall", "thought", "thoughtSignature"]),
                  !(part["text"] != nil && part["functionCall"] != nil),
                  part["text"] == nil || part["text"] is String,
                  part["functionCall"] == nil || part["functionCall"] is [String: Any],
                  part["thought"] == nil || part["thought"] is Bool,
                  part["thoughtSignature"] == nil || part["thoughtSignature"] is String else { throw ModelToolError.invalidProtocol }
            if let function = part["functionCall"] as? [String: Any] {
                guard part["thought"] as? Bool != true,
                      let name = function["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      function["args"] == nil || function["args"] is [String: Any] else { throw ModelToolError.invalidProtocol }
                let arguments = try ToolJSONValue.decodeObject(function["args"] ?? [String: String]())
                if tools.isEmpty, arguments.values.contains(where: { if case .string = $0 { false } else { true } }) {
                    throw ModelToolError.invalidProtocol
                }
                let normalized = try tools.first(where: { $0.name == name })?.normalized(arguments) ?? arguments
                let wireID = function["id"] as? String
                if function["id"] != nil {
                    guard let wireID, !wireID.isEmpty, wireID.utf8.count <= 256, !wireID.contains("\0") else { throw ModelToolError.invalidProtocol }
                }
                // Older Gemini models omit IDs. Local correlation must never alter signed model content.
                let localID = wireID ?? "local-gemini-\(UUID().uuidString)"
                references.append(CallReference(localID: localID, name: name, wireID: wireID))
                calls.append(ModelToolCall(id: localID, name: name, jsonArguments: normalized))
            } else if let text = part["text"] as? String {
                if part["thought"] as? Bool != true { texts.append(text) }
            } else if part["thoughtSignature"] as? String == nil {
                throw ModelToolError.invalidProtocol
            }
        }
        let text = texts.joined(separator: "\n\n")
        guard Set(calls.map(\.id)).count == calls.count,
              !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelToolError.invalidProtocol }
        return (ModelToolTurn(text: text, calls: calls), content, references)
    }
}
