import AIMApplication
import AIMMacPlatform
import Foundation

/// Settings actions that change files or records: imports, worktrees, agent instructions.
extension AppModel {
    // MARK: Agent instructions (global AGENTS.md)

    var agentInstructions: String {
        (try? String(contentsOf: ProjectInstructionsContext.globalFile, encoding: .utf8)) ?? ""
    }

    func saveAgentInstructions(_ text: String) throws {
        let file = ProjectInstructionsContext.globalFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? FileManager.default.removeItem(at: file); return }
        guard trimmed.count <= 16_000 else { throw PersonalizationError.tooLarge }
        try Data(trimmed.utf8).write(to: file, options: .atomic)
    }

    // MARK: Import from other AI apps

    struct ImportSummary: Equatable {
        var instructions = false
        var skills: [String] = []
        var servers: [String] = []
        var skippedServers: [String] = []

        var text: String {
            var parts: [String] = []
            if instructions { parts.append("instructions added to your AGENTS.md") }
            if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
            if !servers.isEmpty { parts.append("\(servers.count) MCP server\(servers.count == 1 ? "" : "s")") }
            var result = parts.isEmpty ? "Nothing new to import." : "Imported " + parts.joined(separator: ", ") + "."
            if !skippedServers.isEmpty { result += " Not imported (command not found): " + skippedServers.joined(separator: ", ") + "." }
            return result
        }
    }

    /// Adds what was chosen; existing skills and servers with the same name are kept.
    func importSetup(_ source: AIImportSource, instructions: Bool, skills: Bool, servers: Bool) async throws -> ImportSummary {
        var summary = ImportSummary()
        if instructions, let found = source.instructions {
            let current = agentInstructions
            let marker = "<!-- Imported from \(source.name) -->"
            if !current.contains(marker) {
                let addition = "\(marker)\n\(found.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                try saveAgentInstructions(current.isEmpty ? addition : current + "\n\n" + addition)
                summary.instructions = true
            }
        }
        if skills, !source.skillDirectories.isEmpty {
            for directory in source.skillDirectories {
                let imported = (try? SkillCatalog.importSkills(from: directory)) ?? []
                summary.skills += imported
            }
        }
        if servers, !source.servers.isEmpty {
            var existing = try await mcpServerRepository.list()
            for server in source.servers where !existing.contains(where: { $0.name == server.name || ($0.url != nil && $0.url == server.url) }) {
                let name = connectorName(server.name, existing: existing)
                var configuration: MCPServerConfiguration
                if let url = server.url {
                    configuration = MCPServerConfiguration(name: name, transport: url.hasSuffix("/sse") ? .sse : .http, url: url)
                } else if let command = server.command, let executable = await Self.resolveExecutable(command) {
                    configuration = MCPServerConfiguration(name: name, transport: .stdio, command: executable, arguments: server.arguments,
                                                           secretNames: server.environment.keys.sorted())
                    for (key, value) in server.environment { try MCPSecretStore.save(value, name: key, serverID: configuration.id) }
                } else {
                    summary.skippedServers.append(server.name)
                    continue
                }
                // Imported servers start untrusted: every tool call asks first.
                configuration.trusted = false
                try await mcpServerRepository.save(configuration)
                existing.append(configuration)
                summary.servers.append(name)
            }
        }
        return summary
    }

    /// Resolve binaries without executing the user's shell startup files.
    static func resolveExecutable(_ command: String) async -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        guard command.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = inherited + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url.path }
        }
        return nil
    }

    // MARK: Worktrees

    func subagentWorktrees() async -> [SubagentWorkspaceRecord] {
        (try? await subagentWorkspaceRepository.list(states: [.active, .merged, .discarded, .conflict])) ?? []
    }

    /// Removes a finished or abandoned sub-agent worktree (an active job keeps its own).
    func removeSubagentWorktree(_ record: SubagentWorkspaceRecord) async throws {
        try await SubagentWorkspaceService().remove(record)
    }
}
