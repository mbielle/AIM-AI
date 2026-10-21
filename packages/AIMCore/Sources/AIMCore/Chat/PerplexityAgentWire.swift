import Foundation

/// The Agent API is Responses-shaped, but its hosted search results are not local tool calls.
/// Keep citations in the persisted message so export and reopened conversations retain them.
public enum PerplexityAgentWire {
    public static func decode(_ json: [String: Any]) throws -> ProviderStreamChunk {
        switch json["type"] as? String {
        case "response.output_text.delta":
            guard let delta = json["delta"] as? String else { throw ChatServiceError.invalidResponse }
            return .init(text: delta)
        case "response.output_item.added", "response.output_item.done":
            guard let item = json["item"] as? [String: Any],
                  let type = item["type"] as? String,
                  ["message", "reasoning", "web_search_call", "search_results"].contains(type) else {
                throw ChatServiceError.unsupportedTools
            }
            return .init()
        case "response.completed":
            guard let response = json["response"] as? [String: Any],
                  response["object"] as? String == "response",
                  response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull,
                  let items = response["output"] as? [[String: Any]] else {
                throw ChatServiceError.incompleteResponse
            }
            var hasAnswer = false
            var sources: [Int: (title: String, url: String)] = [:]
            for item in items {
                if let status = item["status"] as? String, status != "completed" {
                    throw ChatServiceError.incompleteResponse
                }
                switch item["type"] as? String {
                case "message":
                    guard item["role"] as? String == "assistant",
                          let parts = item["content"] as? [[String: Any]] else {
                        throw ChatServiceError.invalidResponse
                    }
                    for part in parts {
                        guard part["type"] as? String == "output_text",
                              let text = part["text"] as? String else {
                            throw ChatServiceError.invalidResponse
                        }
                        hasAnswer = hasAnswer || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                case "search_results":
                    guard let results = item["results"] as? [[String: Any]], results.count <= 100 else {
                        throw ChatServiceError.invalidResponse
                    }
                    for result in results {
                        guard let id = result["id"] as? Int, (1...100).contains(id),
                              let rawURL = result["url"] as? String,
                              rawURL.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()<>"))) == nil,
                              let url = URLComponents(string: rawURL), url.scheme == "https",
                              let host = url.host, !host.isEmpty,
                              url.user == nil, url.password == nil,
                              let title = result["title"] as? String,
                              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              sources[id] == nil else {
                            throw ChatServiceError.invalidResponse
                        }
                        sources[id] = (title, rawURL)
                    }
                case "reasoning", "web_search_call": break
                default: throw ChatServiceError.unsupportedTools
                }
            }
            guard hasAnswer else { throw ChatServiceError.emptyResponse }
            let citations = sources.keys.sorted().compactMap { id in
                ConversationSource(url: sources[id]!.url, title: sources[id]!.title, references: [id])
            }
            return .init(isComplete: true, sources: citations)
        case "response.failed", "response.incomplete", "response.cancelled":
            throw ChatServiceError.incompleteResponse
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            throw ChatServiceError.unsupportedTools
        default: return .init()
        }
    }
}
