import AIMAgentKit
import Foundation

/// What another AI app on this Mac has that AIM can import: global instructions, skills
/// and MCP servers. Reading only; nothing is changed in the other app.
public struct AIImportSource: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case claudeCode, claudeDesktop, codex, cursor }

    public struct Server: Sendable, Equatable {
        public let name: String
        public let command: String?
        public let arguments: [String]
        public let url: String?
        /// Environment values from the other app's file (kept locally, moved to the Keychain on import).
        public let environment: [String: String]
    }

    public let kind: Kind
    public var instructions: (path: String, text: String)?
    public var skillDirectories: [URL]
    public var servers: [Server]

    public var id: String { kind.rawValue }
    public var name: String {
        switch kind {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
    public var isEmpty: Bool { instructions == nil && skillDirectories.isEmpty && servers.isEmpty }

    public static func == (lhs: AIImportSource, rhs: AIImportSource) -> Bool {
        lhs.kind == rhs.kind && lhs.instructions?.text == rhs.instructions?.text
            && lhs.skillDirectories == rhs.skillDirectories && lhs.servers == rhs.servers
    }
}

public enum AIImportScanner {
    /// Sources found under a home folder (the real one by default).
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AIImportSource] {
        let support = home.appending(path: "Library/Application Support")
        var sources: [AIImportSource] = []

        var claude = AIImportSource(kind: .claudeCode, instructions: nil, skillDirectories: [], servers: [])
        claude.instructions = text(home.appending(path: ".claude/CLAUDE.md"))
        claude.skillDirectories = skills(in: home.appending(path: ".claude/skills"))
        claude.servers = jsonServers(home.appending(path: ".claude.json"))
        sources.append(claude)

        var desktop = AIImportSource(kind: .claudeDesktop, instructions: nil, skillDirectories: [], servers: [])
        desktop.servers = jsonServers(support.appending(path: "Claude/claude_desktop_config.json"))
        sources.append(desktop)

        var codex = AIImportSource(kind: .codex, instructions: nil, skillDirectories: [], servers: [])
        codex.instructions = text(home.appending(path: ".codex/AGENTS.md"))
        codex.skillDirectories = skills(in: home.appending(path: ".codex/skills"))
        if let config = try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8) {
            codex.servers = codexServers(config)
        }
        sources.append(codex)

        var cursor = AIImportSource(kind: .cursor, instructions: nil, skillDirectories: [], servers: [])
        cursor.servers = jsonServers(home.appending(path: ".cursor/mcp.json"))
        sources.append(cursor)

        return sources.filter { !$0.isEmpty }
    }

    static func text(_ url: URL) -> (path: String, text: String)? {
        guard let data = try? Data(contentsOf: url), data.count <= 64_000, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (url.path, text)
    }

    static func skills(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `{"mcpServers": {"name": {"command", "args", "env"} | {"url"}}}` (Claude, Cursor).
    static func jsonServers(_ url: URL) -> [AIImportSource.Server] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return jsonServers(data)
    }

    public static func jsonServers(_ data: Data) -> [AIImportSource.Server] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, value -> AIImportSource.Server? in
            guard let entry = value as? [String: Any] else { return nil }
            let command = entry["command"] as? String
            let url = (entry["url"] as? String) ?? (entry["serverUrl"] as? String)
            guard command != nil || url != nil else { return nil }
            return .init(name: name, command: command, arguments: entry["args"] as? [String] ?? [], url: url,
                         environment: (entry["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String })
        }
        .sorted { $0.name < $1.name }
    }

    /// `[mcp_servers.name]` tables of Codex's config.toml (command, args, url, and `[mcp_servers.name.env]`).
    public static func codexServers(_ toml: String) -> [AIImportSource.Server] {
        var order: [String] = []
        var fields: [String: [String: String]] = [:]
        var env: [String: [String: String]] = [:]
        var current: (name: String, isEnv: Bool)?
        for raw in toml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                guard header.hasPrefix("mcp_servers.") else { current = nil; continue }
                var name = String(header.dropFirst("mcp_servers.".count))
                let isEnv = name.hasSuffix(".env")
                if isEnv { name = String(name.dropLast(4)) }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !order.contains(name) { order.append(name) }
                current = (name, isEnv)
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = stripComment(String(line[line.index(after: equals)...])).trimmingCharacters(in: .whitespaces)
            if current.isEnv { env[current.name, default: [:]][key] = unquote(value) }
            else { fields[current.name, default: [:]][key] = value }
        }
        return order.compactMap { name in
            let entry = fields[name] ?? [:]
            let command = entry["command"].map(unquote)
            let url = entry["url"].map(unquote)
            guard command != nil || url != nil else { return nil }
            return .init(name: name, command: command, arguments: entry["args"].map(array) ?? [], url: url, environment: env[name] ?? [:])
        }
    }

    /// Removes a `# comment` that is not inside a quoted string.
    static func stripComment(_ value: String) -> String {
        var quote: Character?
        for (offset, character) in value.enumerated() {
            if let open = quote { if character == open { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(value.prefix(offset)) }
        }
        return value
    }

    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    static func array(_ value: String) -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        let body = value.dropFirst().dropLast()
        var items: [String] = [], current = "", quote: Character?
        for character in body {
            if let open = quote {
                if character == open { quote = nil; items.append(current); current = "" } else { current.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
        }
        return items
    }
}

/// Conversations exported from ChatGPT (`conversations.json`, with a `mapping` tree) or
/// Claude (`chat_messages`), possibly inside the export's `.zip`.
public enum ChatExportReader {
    public struct Message: Sendable, Equatable {
        public let isUser: Bool
        public let text: String
    }

    public struct Conversation: Sendable, Equatable {
        public let title: String
        public let createdAt: Date?
        public let messages: [Message]
    }

    /// Reads a `.json` file, or `conversations.json` inside a `.zip`.
    public static func read(_ url: URL) throws -> [Conversation] {
        let data: Data
        if url.pathExtension.lowercased() == "zip" {
            let staging = try ConfinedProcessStaging(source: url)
            guard let archive = staging.input else { throw ChatExportError.unreadable }
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-p", archive.path, "conversations.json"], workingDirectory: staging.root,
                environment: ["LANG": "C"], timeout: .seconds(30), inheritsEnvironment: false)
            let confined = try OSProcessConfinement.prepare(command, readRoots: [staging.root], writeRoots: [staging.home], privateHome: staging.home)
            data = try ConfinedBinaryProcess.runSynchronously(confined, maximumOutputBytes: 64 * 1_024 * 1_024)
        } else {
            data = try Data(contentsOf: url)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [Conversation] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw ChatExportError.unreadable }
        return items.compactMap { item in
            if item["mapping"] != nil { return chatGPT(item) }
            if item["chat_messages"] != nil { return claude(item) }
            return nil
        }
    }

    static func chatGPT(_ item: [String: Any]) -> Conversation? {
        guard let mapping = item["mapping"] as? [String: [String: Any]] else { return nil }
        // The visible branch: from the current node up to the root.
        var nodeID = item["current_node"] as? String ?? mapping.first { ($0.value["children"] as? [Any])?.isEmpty ?? true }?.key
        var chain: [[String: Any]] = []
        var guardCount = 0
        while let id = nodeID, let node = mapping[id], guardCount < 10_000 {
            chain.append(node)
            nodeID = node["parent"] as? String
            guardCount += 1
        }
        let messages: [Message] = chain.reversed().compactMap { node in
            guard let message = node["message"] as? [String: Any],
                  let role = (message["author"] as? [String: Any])?["role"] as? String, role == "user" || role == "assistant",
                  let content = message["content"] as? [String: Any] else { return nil }
            let parts = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Message(isUser: role == "user", text: text)
        }
        guard !messages.isEmpty else { return nil }
        let created = (item["create_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Conversation(title: (item["title"] as? String) ?? "Imported conversation", createdAt: created, messages: messages)
    }

    static func claude(_ item: [String: Any]) -> Conversation? {
        let messages: [Message] = (item["chat_messages"] as? [[String: Any]] ?? []).compactMap { message in
            let sender = message["sender"] as? String
            var text = (message["text"] as? String) ?? ""
            if text.isEmpty, let content = message["content"] as? [[String: Any]] {
                text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sender == "human" || sender == "assistant", !text.isEmpty else { return nil }
            return Message(isUser: sender == "human", text: text)
        }
        guard !messages.isEmpty else { return nil }
        let created = (item["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let title = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Imported conversation"
        return Conversation(title: title, createdAt: created, messages: messages)
    }
}

public enum ChatExportError: LocalizedError {
    case unreadable
    public var errorDescription: String? { "This file is not a ChatGPT or Claude conversation export (conversations.json)." }
}
