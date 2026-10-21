import Foundation

/// The files AIM changed in earlier runs of a conversation, rebuilt from the
/// run journal and given to the model each turn (as OpenClaw/JCode keep a
/// file-operations manifest), so the knowledge survives compaction and turns.
public enum WorkspaceChangeManifest {
    /// Paths in the order they were last changed (oldest first), at most `limit`.
    public static func changedPaths(_ runs: [WorkspaceRunHistory], limit: Int = 40) -> [String] {
        var ordered: [String] = []
        func touch(_ path: String) {
            let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 512 else { return }
            ordered.removeAll { $0 == clean }
            ordered.append(clean)
        }
        for run in runs.sorted(by: { $0.run.startedAt < $1.run.startedAt }) {
            var proposals: [String: [String]] = [:]
            for call in run.calls where call.state == .succeeded {
                let arguments = (try? JSONDecoder().decode([String: ToolJSONValue].self, from: call.argumentsJSON)) ?? [:]
                let metadata = call.resultMetadataJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                func argument(_ key: String) -> String? { arguments[key]?.legacyString }
                switch call.name {
                case "propose_file", "propose_edit":
                    if let id = metadata["proposal_id"], let path = argument("path") { proposals[id] = [path] }
                case "propose_patch":
                    if let id = metadata["proposal_id"], let result = call.result,
                       let open = result.firstIndex(of: "("), let close = result[open...].firstIndex(of: ")") {
                        proposals[id] = result[result.index(after: open)..<close].split(separator: ",").compactMap { item in
                            item.split(separator: " ", maxSplits: 1).last.map(String.init)
                        }
                    }
                case "apply_edit":
                    if let id = argument("proposal_id") { proposals[id]?.forEach(touch) }
                case "copy_file", "move_file":
                    if let destination = argument("destination") { touch(destination) }
                case "create_dir", "trash_file":
                    if let path = argument("path") { touch(path) }
                default:
                    break
                }
            }
        }
        return Array(ordered.suffix(limit))
    }

    public static func message(_ runs: [WorkspaceRunHistory], conversationID: UUID) -> ConversationMessage? {
        let paths = changedPaths(runs)
        guard !paths.isEmpty else { return nil }
        return ConversationMessage(conversationID: conversationID, role: .user,
            content: "Files AIM changed earlier in this conversation (least to most recent): \(paths.joined(separator: ", ")). Their current contents may have changed since; read a file again before editing it.",
            sequence: -6)
    }
}
