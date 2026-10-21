import Foundation
import CryptoKit

public enum ChatImportParser {
    public static func parse(_ data: Data) throws -> [NativeChatConversation] {
        guard data.count <= 32_000_000 else { throw ChatServiceError.invalidResponse }
        if let native = try? JSONDecoder().decode([NativeChatConversation].self, from: data) { return native }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 10_000 else { throw ChatServiceError.invalidResponse }
        return try rows.compactMap { row in
            let sourceID = (row["uuid"] ?? row["id"] ?? row["conversation_id"]) as? String
            guard let sourceID, !sourceID.isEmpty else { throw ChatServiceError.invalidResponse }
            var messages: [NativeChatMessage] = []
            if let mapping = row["mapping"] as? [String: [String: Any]] {
                guard mapping.count <= 100_000 else { throw ChatServiceError.invalidResponse }
                // Import the selected branch, never concatenate mutually exclusive alternatives.
                guard var node = row["current_node"] as? String else { throw ChatServiceError.invalidResponse }
                var seen = Set<String>(); var selected: [[String: Any]] = []
                while let item = mapping[node] {
                    guard seen.insert(node).inserted else { throw ChatServiceError.invalidResponse }
                    if let message = item["message"] as? [String: Any] { selected.append(message) }
                    guard let parent = item["parent"] as? String else { break }; node = parent
                }
                for item in selected.reversed() {
                    guard let author = item["author"] as? [String: Any], let raw = author["role"] as? String,
                          let role = NativeChatMessage.Role(rawValue: raw), let id = item["id"] as? String,
                          let content = item["content"] as? [String: Any], let parts = content["parts"] as? [Any] else { continue }
                    let text = parts.compactMap { $0 as? String }.joined(separator: "\n")
                    if !text.isEmpty { messages.append(.init(id: stableID("chatgpt:" + id), role: role, text: text,
                        createdAt: Date(timeIntervalSince1970: item["create_time"] as? Double ?? 0))) }
                }
            } else if let items = row["chat_messages"] as? [[String: Any]] {
                for item in items {
                    guard let raw = item["sender"] as? String, let role = NativeChatMessage.Role(rawValue: raw == "human" ? "user" : raw),
                          let id = item["uuid"] as? String else { continue }
                    let text = item["text"] as? String ?? ""
                    let date = ISO8601DateFormatter().date(from: item["created_at"] as? String ?? "") ?? Date(timeIntervalSince1970: 0)
                    if !text.isEmpty { messages.append(.init(id: stableID("claude:" + id), role: role, text: text, createdAt: date)) }
                }
            } else { throw ChatServiceError.invalidResponse }
            guard !messages.isEmpty else { return nil }
            // Imported history records no synthetic usage or supplier charges.
            return NativeChatConversation(id: stableID("import:" + sourceID), title: (row["title"] ?? row["name"]) as? String ?? "Imported conversation",
                provider: .openRouter, modelID: "", messages: messages, updatedAt: messages.last!.createdAt)
        }
    }
    private static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
