import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Session and tool commands run without selecting a SwiftUI conversation.
/// Relay identity, pairing, unlock and revocation checks remain upstream.
package actor RuntimeRemoteSessionBridge {
    package static let commands: Set<String> = ["request_history", "request_detail", "rename_session", "archive_session", "delete_session",
        "request_diff", "run_command", "stop_command", "start_preview", "stop_preview"]
    private let dependencies: AgentRuntimeDependencies
    private let coordinator: RunCoordinator
    private let authorizeOperation: @Sendable () throws -> Void
    private var terminals: [UUID: Task<ProcessOutput, Error>] = [:]
    private var browsers: [UUID: AgentBrowserToolService] = [:]
    package init(dependencies: AgentRuntimeDependencies, coordinator: RunCoordinator,
                 authorizeOperation: @escaping @Sendable () throws -> Void = {}) {
        self.dependencies = dependencies; self.coordinator = coordinator; self.authorizeOperation = authorizeOperation
    }
    package func stop(conversationIDs: Set<UUID>) async {
        for id in conversationIDs {
            if let task = terminals.removeValue(forKey: id) { task.cancel(); _ = try? await task.value }
            if let browser = browsers.removeValue(forKey: id) { await browser.closeSession() }
        }
    }
    package func execute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue) async throws -> RemoteJSONValue? {
        try authorizeOperation()
        guard let raw = sessionID, let id = UUID(uuidString: raw),
              let conversation = try await dependencies.conversations.conversation(id: id) else {
            // A repeated deletion is successful; it must never create a session.
            if type == "delete_session", sessionID.flatMap(UUID.init(uuidString:)) != nil { return .object(["deleted": .bool(true)]) }
            throw RemoteHostCommandFailure("session_introuvable")
        }
        let object = payload.objectValue ?? [:]
        switch type {
        case "request_history": return try await history(conversation, object)
        case "request_detail":
            guard let detail = object["detail_id"]?.stringValue, detail.utf8.count <= 512 else { throw RemoteHostCommandFailure("detail_introuvable") }
            if let separator = detail.firstIndex(of: ":"), UUID(uuidString: String(detail[..<separator])) != nil {
                let runID = String(detail[..<separator]), callID = String(detail[detail.index(after: separator)...])
                guard let history = try await dependencies.runs.run(id: runID),
                      history.run.conversationID.lowercased() == id.uuidString.lowercased(),
                      let call = history.calls.first(where: { $0.id == callID }) else { throw RemoteHostCommandFailure("detail_introuvable") }
                let rawOffset = object["offset"]?.numberValue ?? 0
                guard rawOffset.isFinite, rawOffset.rounded() == rawOffset, (0...1_000_000).contains(rawOffset),
                      let page = ConversationAction.detailPage(call.result ?? "Action details are no longer available.", offset: Int(rawOffset))?.objectValue else { throw RemoteHostCommandFailure("curseur_invalide") }
                let arguments = ConversationAction.redact(String(decoding: call.argumentsJSON, as: UTF8.self))
                return .object(["id": .string(detail), "output": page["output"] ?? .null, "next_offset": page["next_offset"] ?? .null, "source_truncated": page["source_truncated"] ?? .null, "arguments": .string(arguments),
                    "status": .string(call.state.rawValue), "duration": call.endedAt.map { .number(max(0, $0.timeIntervalSince(call.startedAt))) } ?? .null,
                    "truncated": .bool((call.result?.utf8.count ?? 0) > 16_384)])
            }
            guard let messageID = UUID(uuidString: detail),
                  let message = try await dependencies.conversations.messages(conversationID: id).first(where: { $0.id == messageID }) else { throw RemoteHostCommandFailure("detail_introuvable") }
            return .object(["content": .string(ConversationAction.redact(message.content)), "id": .string(message.id.uuidString)])
        case "rename_session":
            guard let rawTitle = object["title"]?.stringValue,
                  !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteHostCommandFailure("titre_invalide") }
            let title = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            let repository = dependencies.conversations
            let authorizeOperation = self.authorizeOperation
            return try await coordinator.withRemoteResources(workspace: nil, desktop: false,
                conversationID: id, mutatingSession: true) {
                try authorizeOperation()
                guard var saved = try await repository.conversation(id: id) else { throw RemoteHostCommandFailure("session_introuvable") }
                saved.title = title; saved.updatedAt = .now
                try await repository.save(saved)
                return .object(["title": .string(title)])
            }
        case "archive_session", "delete_session":
            return try await mutateSession(conversation, type: type, object: object)
        case "stop_command":
            guard let task = terminals[id] else { throw RemoteHostCommandFailure("aucune_commande_en_cours") }
            task.cancel()
            _ = try? await task.value
            return .object(["stopped": .bool(true)])
        case "run_command": return try await terminal(conversation, commandID: commandID, object: object)
        case "request_diff": return try await diff(conversation)
        case "start_preview": return try await browser(conversation, commandID: commandID, object: object)
        case "stop_preview":
            if let browser = browsers.removeValue(forKey: id) { await browser.closeSession() }
            return .object(["stopped": .bool(true)])
        default: throw RemoteHostCommandFailure("commande_non_prise_en_charge")
        }
    }
    private func history(_ conversation: Conversation, _ object: [String: RemoteJSONValue]) async throws -> RemoteJSONValue {
        let rawLimit = object["limit"]?.numberValue ?? 100
        guard rawLimit.isFinite, rawLimit.rounded() == rawLimit else { throw RemoteHostCommandFailure("limite_invalide") }
        let limit = Int(min(100, max(1, rawLimit)))
        var cursor: Int?
        if let raw = object["cursor"]?.stringValue {
            let components = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 3, components[0] == "v1", components[1].lowercased() == conversation.id.uuidString.lowercased(),
                  let sequence = Int(components[2]), sequence >= 0 else { throw RemoteHostCommandFailure("curseur_invalide") }
            cursor = sequence
        }
        let messages = try await dependencies.conversations.messages(conversationID: conversation.id)
            .filter { ($0.role == .user || $0.role == .assistant) && $0.sequence >= 0 }
            .sorted { $0.sequence < $1.sequence }
        let projected = ConversationActionProjection.apply(try await dependencies.runs.history(conversationID: conversation.id, limit: 100), to: try await coordinator.projectActivity(messages))
        let eligible = projected.filter { cursor == nil || $0.sequence < cursor! }
        let page = Array(eligible.suffix(limit))
        let hasMore = page.count < eligible.count
        return .object(["messages": .array(page.map(Self.message)), "has_more": .bool(hasMore),
            "next_cursor": hasMore ? .string("v1:\(conversation.id.uuidString.lowercased()):\(page[0].sequence)") : .null])
    }
    private static func message(_ message: ConversationMessage) -> RemoteJSONValue {
        .object(["id": .string(message.id.uuidString.lowercased()), "seq": .number(Double(message.sequence)),
                 "role": .string(message.role.rawValue), "content": .string(message.content),
                 "timeline": ConversationAction.remoteTimeline(message.actions, content: message.content, sources: message.sources, turn: message.timeline) ?? .null])
    }
    private func workspace(_ conversation: Conversation) throws -> URL {
        guard conversation.mode != .chat, let raw = conversation.workspacePath,
              let folder = RemoteHostFolders.allowed(raw),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw RemoteHostCommandFailure("chemin_refuse")
        }
        return folder
    }
    private func mutateSession(_ conversation: Conversation, type: String, object: [String: RemoteJSONValue]) async throws -> RemoteJSONValue {
        if type == "archive_session", object["archived"]?.boolValue == nil { throw RemoteHostCommandFailure("archive_invalide") }
        let repository = dependencies.conversations
        let authorizeOperation = self.authorizeOperation
        return try await coordinator.withRemoteResources(workspace: conversation.workspacePath, desktop: false,
            conversationID: conversation.id, mutatingSession: true) {
            try authorizeOperation()
            if type == "delete_session" {
                try await repository.delete(id: conversation.id)
                return .object(["deleted": .bool(true)])
            }
            // Re-read under reservation so a concurrent rename cannot be lost.
            guard var saved = try await repository.conversation(id: conversation.id) else { throw RemoteHostCommandFailure("session_introuvable") }
            saved.isArchived = object["archived"] == .bool(true); saved.updatedAt = .now
            try await repository.save(saved)
            return .object(["archived": .bool(saved.isArchived)])
        }
    }
    private func terminal(_ conversation: Conversation, commandID: String, object: [String: RemoteJSONValue]) async throws -> RemoteJSONValue {
        // Arbitrary shell can hide network access; it cannot be attested local.
        if RuntimePrivacyPolicy.isEnabled { throw RemoteHostCommandFailure("commande_bloquee_mode_prive") }
        let folder = try workspace(conversation)
        guard let command = object["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 16_384, !command.contains("\0") else { throw RemoteHostCommandFailure("commande_invalide") }
        guard terminals[conversation.id] == nil else { throw RemoteHostCommandFailure("commande_deja_en_cours") }
        let coordinator = self.coordinator
        let authorizeOperation = self.authorizeOperation
        let task = Task<ProcessOutput, Error> {
            try await coordinator.withRemoteResources(workspace: folder.path, desktop: false,
                conversationID: conversation.id, mutatingSession: true) {
                try authorizeOperation()
                return try await MacProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-c", command], workingDirectory: folder, timeout: .seconds(110)))
            }
        }
        terminals[conversation.id] = task
        defer { terminals.removeValue(forKey: conversation.id) }
        do {
            let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            let text = output.stdout + (output.stderr.isEmpty ? "" : "\n" + output.stderr)
            let truncated = output.wasTruncated || text.utf8.count > 256 * 1_024
            return .object(["output": .string(String(decoding: text.utf8.suffix(256 * 1_024), as: UTF8.self)),
                "exitCode": .number(Double(output.exitCode)), "truncated": .bool(truncated), "stopped": .bool(false)])
        } catch is CancellationError { return .object(["output": .string(""), "stopped": .bool(true)]) }
        catch is ProcessExecutionError { throw RemoteHostCommandFailure("commande_delai_depasse") }
    }
    private func diff(_ conversation: Conversation) async throws -> RemoteJSONValue {
        let folder = try workspace(conversation)
        let runner = MacProcessRunner()
        let output = try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "diff", "HEAD", "--no-ext-diff", "--no-textconv", "--no-color", "--", "."],
            workingDirectory: folder, environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"], timeout: .seconds(15)))
        guard output.exitCode == 0 else { throw RemoteHostCommandFailure("diff_indisponible") }
        guard !output.wasTruncated else { throw RemoteHostCommandFailure("diff_trop_volumineux") }
        let files = RemoteUnifiedDiffParser.files(in: output.stdout)
        return .object(["diff": .string(output.stdout), "base": .string("HEAD"), "dir": .string(folder.path),
            "files": .array(files.map { .object(["path": .string($0.path), "additions": .number(Double($0.additions)),
                "deletions": .number(Double($0.deletions)), "status": .string($0.status ?? "modified")]) })])
    }
    private func browser(_ conversation: Conversation, commandID: String, object: [String: RemoteJSONValue]) async throws -> RemoteJSONValue {
        guard AgentBrowserToolService.isBundled else { throw RemoteHostCommandFailure("navigateur_indisponible") }
        let folder = try workspace(conversation)
        let browserValue = object["browser"]?.objectValue
        if browserValue != nil, browserValue?["version"]?.numberValue != 1 { throw RemoteHostCommandFailure("contrat_navigateur_incompatible") }
        let name = browserValue?["name"]?.stringValue ?? "browser_snapshot"
        let supported: Set<String> = ["browser_snapshot", "browser_navigate", "browser_navigate_back", "browser_click", "browser_type", "browser_press_key"]
        guard supported.contains(name) else { throw RemoteHostCommandFailure("action_navigateur_refusee") }
        if name != "browser_snapshot" {
            do { try RuntimePrivacyPolicy.requireNetwork() }
            catch { throw RemoteHostCommandFailure("navigateur_bloque_mode_prive") }
        }
        var arguments: [String: String] = [:]
        for (key, value) in browserValue?["arguments"]?.objectValue ?? [:] {
            guard let text = value.stringValue, text.utf8.count <= 16_384 else { throw RemoteHostCommandFailure("arguments_navigateur_invalides") }
            arguments[key] = text
        }
        let service: AgentBrowserToolService
        if let existing = browsers[conversation.id] { service = existing }
        else {
            service = AgentBrowserToolService(configuration: AgentBrowserPreferences.configuration(workspace: folder.path))
            browsers[conversation.id] = service
        }
        let request = ToolRequest(id: commandID, name: name, arguments: arguments,
            risk: name == "browser_snapshot" ? .computerRead : .computerAction, workspacePath: folder.path)
        let authorizeOperation = self.authorizeOperation
        return try await coordinator.withRemoteResources(workspace: folder.path, desktop: true,
            conversationID: conversation.id, mutatingSession: true) {
            try authorizeOperation()
            let result = await service.execute(request)
            if result.isError {
                return .object(["preview_kind": .string("browser_snapshot_v1"), "browser_error": .string(result.content)])
            }
            if name != "browser_snapshot" {
                // The service invalidates target leases before the action; always
                // observe afterwards before offering another targeted operation.
                let observed = await service.execute(ToolRequest(name: "browser_snapshot", arguments: [:], risk: .computerRead, workspacePath: folder.path))
                return .object(["preview_kind": .string("browser_snapshot_v1"), "browser_snapshot": .string(observed.content),
                    "browser_error": observed.isError ? .string(observed.content) : .null,
                    "observation_id": observed.metadata["observation_id"].map(RemoteJSONValue.string) ?? .null])
            }
            return .object(["preview_kind": .string("browser_snapshot_v1"), "browser_snapshot": .string(result.content),
                "observation_id": result.metadata["observation_id"].map(RemoteJSONValue.string) ?? .null])
        }
    }
}
