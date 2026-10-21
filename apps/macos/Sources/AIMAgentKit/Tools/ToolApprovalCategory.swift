import AIMApplication
import AIMCore
import Foundation

/// The kind of action an approval is about, as the person reads it ("Sub-agent", "Command"…),
/// and the key a standing decision applies to: every sub-agent, `npm` commands, control of one app.
public struct ToolApprovalCategory: Codable, Hashable, Sendable {
    /// Stable identity of a standing decision, e.g. "subagent", "command:npm", "app:com.apple.mail".
    public var key: String
    /// The card's header: "Sub-agent", "Command", "File change", "Web", "Computer use"…
    public var title: String
    /// What "Always allow" covers, completing "Always allow …": "starting and steering sub-agents".
    public var scope: String

    public init(key: String, title: String, scope: String) { self.key = key; self.title = title; self.scope = scope }

    /// The category from the tool name and arguments alone. Executors that know more (the app
    /// behind a window) refine it through `ToolApprovalCategorizing`.
    public static func of(_ request: ToolRequest) -> ToolApprovalCategory {
        let name = request.name
        switch name {
        case "delegate_task", "message_subagent", "cancel_subagent", "retry_subagent", "merge_subagent_changes", "discard_subagent_changes":
            return .init(key: "subagent", title: "Sub-agent", scope: "starting and steering sub-agents")
        case "run_command", "start_command":
            if let program = program(of: request.arguments["command"] ?? "") {
                return .init(key: "command:" + program, title: "Command", scope: "“\(program)” commands")
            }
            return .init(key: "command", title: "Command", scope: "commands")
        case "write_command", "close_command_input", "stop_command":
            return .init(key: "command-input", title: "Command", scope: "input to running commands")
        case "verify_project":
            return .init(key: "command:verify", title: "Command", scope: "project checks")
        case "apply_edit", "copy_file", "create_dir", "move_file", "undo_edit", "trash_file":
            return .init(key: "files", title: "File change", scope: "file changes in the chosen folders")
        case "web_search", "web_fetch":
            return .init(key: "web", title: "Web", scope: "web searches and page reads")
        case "web_download":
            return .init(key: "download", title: "Download", scope: "downloads")
        case "open_url":
            return .init(key: "open-url", title: "Open link", scope: "opening links")
        case "open_app", "open_file":
            return .init(key: "open", title: "Open", scope: "opening apps and files")
        case "run_applescript":
            return .init(key: "applescript", title: "AppleScript", scope: "AppleScript")
        case "mcp_call":
            let server = request.arguments["server"].map(sanitized) ?? ""
            return .init(key: "mcp:" + server, title: "Connector", scope: server.isEmpty ? "connector actions" : "\(server) actions")
        case "read_memory", "search_memory", "search_history", "search_activity":
            return .init(key: "memory", title: "Memory", scope: "reading memory and history")
        case "memory_save":
            return .init(key: "memory-save", title: "Memory", scope: "saving memories")
        case "restore_checkpoint":
            return .init(key: "checkpoint", title: "Restore", scope: "restoring checkpoints")
        default: break
        }
        for (prefix, app, title) in [("mail_", "Mail", "Mail"), ("notes_", "Notes", "Notes"), ("calendar_", "Calendar", "Calendar"),
                                     ("reminders_", "Reminders", "Reminders"), ("messages_", "Messages", "Messages"),
                                     ("contacts_", "Contacts", "Contacts")] where name.hasPrefix(prefix) {
            return .init(key: "app:" + app.lowercased(), title: title, scope: "\(app) actions")
        }
        if name.hasPrefix("browser_") { return .init(key: "browser", title: "Browser", scope: "browser control") }
        if name.hasPrefix("desktop_") { return .init(key: "computer", title: "Computer use", scope: "controlling apps") }
        if name.hasPrefix("mission_") || name == "schedule_task" || name == "create_mcp_server" {
            return .init(key: "mission", title: "Mission", scope: "mission definitions")
        }
        if name.hasPrefix("plugin_") { return .init(key: "tool:" + name, title: "Extension", scope: "this extension tool") }
        return .init(key: "tool:" + name, title: "Action", scope: "this tool")
    }

    /// The program a shell command starts, after `sudo`, `env` and variable assignments;
    /// nil when it chains several programs (a standing grant must name what it covers).
    public static func program(of command: String) -> String? {
        let segments = ShellCommandClassifier.segments(command)
        var programs: Set<String> = []
        for segment in segments {
            var words = ShellCommandClassifier.tokens(segment)
            while let first = words.first, ["sudo", "doas", "nohup", "time", "command", "exec", "nice", "env"].contains(first)
                    || (first.contains("=") && !first.hasPrefix("-")) { words.removeFirst() }
            guard let first = words.first else { continue }
            programs.insert((first as NSString).lastPathComponent)
        }
        guard programs.count == 1, let only = programs.first, !only.isEmpty, only.count <= 64 else { return nil }
        return only
    }

    private static func sanitized(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }.prefix(64))
    }
}

/// An executor that can name the category of a request more precisely (the app a window belongs to).
public protocol ToolApprovalCategorizing: Sendable {
    func approvalCategory(for request: ToolRequest) async -> ToolApprovalCategory?
}

/// Action types the person allowed everywhere ("Always allow"). Kept in the installation's shared
/// preferences so the app and the agent host read the same list; revocable in Settings › Permissions.
public enum AlwaysAllowedActions {
    public static let preferenceKey = "aim.approvals.alwaysAllowed"
    /// Tests point this at a scratch domain so they never touch an installation's preferences.
    nonisolated(unsafe) public static var defaults: () -> UserDefaults = { AIMInstallationContext.sharedPreferences }

    public static func all() -> [ToolApprovalCategory] {
        let defaults = Self.defaults()
        defaults.synchronize()
        guard let data = defaults.data(forKey: preferenceKey),
              let values = try? JSONDecoder().decode([ToolApprovalCategory].self, from: data) else { return [] }
        return values
    }

    public static func contains(_ key: String) -> Bool { all().contains { $0.key == key } }

    public static func add(_ category: ToolApprovalCategory) {
        var values = all().filter { $0.key != category.key }
        values.append(category)
        save(values)
    }

    public static func remove(key: String) { save(all().filter { $0.key != key }) }

    private static func save(_ values: [ToolApprovalCategory]) {
        let defaults = Self.defaults()
        defaults.set(try? JSONEncoder().encode(values), forKey: preferenceKey)
        defaults.synchronize()
    }
}
