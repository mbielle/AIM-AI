import AIMAgentKit
import AIMApplication
import Foundation

/// One instance per run: model-supplied IDs cannot access proposals from another run.
public actor WorkspaceEditToolService: ToolReviewProviding, MissionIntentProviding, DurableToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["propose_edit", "propose_file", "propose_patch", "apply_edit", "undo_edit"]
    private let service = WorkspaceEditService()
    private struct Entry: Codable {
        let workspace: String
        let proposal: WorkspaceEditService.Proposal
        var applied = false
    }
    private var proposals: [UUID: Entry] = [:]
    /// Multi-file patches prepared in this run (workspace per patch).
    private var patchWorkspaces: [UUID: String] = [:]
    public init() {}

    private struct DurableState: Codable {
        var version = 1
        var service: Data
        var proposals: [UUID: Entry]
        var patches: [UUID: String]
    }
    public func exportToolState() async throws -> Data {
        try await JSONEncoder().encode(DurableState(service: service.exportState(), proposals: proposals, patches: patchWorkspaces))
    }
    public func restoreToolState(_ data: Data, workspacePath: String?) async throws {
        guard let workspacePath else { throw ExecutionStoreError.incompatibleCheckpoint }
        let state = try JSONDecoder().decode(DurableState.self, from: data)
        guard state.version == 1, state.proposals.values.allSatisfy({ $0.workspace == workspacePath }),
              state.patches.values.allSatisfy({ $0 == workspacePath }) else { throw ExecutionStoreError.incompatibleCheckpoint }
        try await service.restoreState(state.service, workspace: workspacePath)
        proposals = state.proposals; patchWorkspaces = state.patches
    }
    public nonisolated func recoveryPolicy(for name: String) -> ToolRecoveryPolicy {
        if name.hasPrefix("propose_") { return .readOnly }
        return name == "apply_edit" ? .reconcile : .neverReplay
    }
    public func reconcile(_ call: ModelToolCall, workspacePath: String?) async throws -> ModelToolOutput? {
        guard call.name == "apply_edit", let workspacePath, let raw = call.arguments["proposal_id"],
              let id = UUID(uuidString: raw),
              proposals[id]?.workspace == workspacePath || patchWorkspaces[id] == workspacePath,
              try await service.reconcileApplied(id) else { return nil }
        if var entry = proposals[id] { entry.applied = true; proposals[id] = entry }
        return ModelToolOutput(id: call.id, content: "Recovered effect: every target currently matches the approved after-state. No write was replayed.", isError: false,
                               metadata: ["action_outcome": "confirmed", "reconciled_by": "host_file_observation"])
    }

    public func review(_ request: ToolRequest) async throws -> ToolReview? {
        guard ["apply_edit", "undo_edit"].contains(request.name) else { return nil }
        if let id = patchID(request), let patch = await service.patchProposal(id) {
            let applied = await service.isPatchApplied(id)
            guard applied == (request.name == "undo_edit") else { throw WorkspaceEditService.EditError.unknownProposal }
            func section(_ file: WorkspaceEditService.Proposal, _ text: String) -> String { "=== \(file.path) ===\n\(text)" }
            let before = patch.files.map { section($0, $0.isCreation ? "(new file)" : $0.before) }.joined(separator: "\n")
            let after = patch.files.map { section($0, $0.isDeletion ? "(deleted, moved to Trash)" : $0.after) }.joined(separator: "\n")
            return ToolReview(path: patch.files.map(\.path).joined(separator: ", "),
                              before: applied ? after : before, after: applied ? before : after,
                              beforeExists: true, afterExists: !patch.files.contains { $0.isDeletion })
        }
        let entry = try entry(request)
        guard entry.applied == (request.name == "undo_edit") else { throw WorkspaceEditService.EditError.unknownProposal }
        return ToolReview(path: entry.proposal.path,
                          before: entry.applied ? entry.proposal.after : entry.proposal.before,
                          after: entry.applied ? entry.proposal.before : entry.proposal.after,
                          beforeExists: !entry.proposal.isCreation || entry.applied,
                          afterExists: !entry.proposal.isCreation || !entry.applied)
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard let workspace = request.workspacePath else { throw WorkspaceError.missingWorkspace }
            switch request.name {
            case "propose_file":
                guard let path = request.arguments["path"], let content = request.arguments["content"] else { throw WorkspaceError.missingPath }
                let proposal = try await service.prepareCreation(workspace: workspace, path: path, content: content)
                proposals[proposal.id] = Entry(workspace: workspace, proposal: proposal)
                return ToolResult(requestID: request.id, content: "Prepared new file \(path), proposal_id \(proposal.id.uuidString). Nothing was written. Call apply_edit to request approval.", metadata: ["proposal_id": proposal.id.uuidString])
            case "propose_patch":
                guard let text = request.arguments["patch"], text.utf8.count <= 2_000_000 else { throw WorkspaceError.missingPath }
                let patch = try await service.preparePatch(workspace: workspace, changes: try WorkspacePatch.parse(text))
                patchWorkspaces[patch.id] = workspace
                let summary = patch.files.map { "\($0.isCreation ? "add" : $0.isDeletion ? "delete" : "update") \($0.path)" }
                return ToolResult(requestID: request.id, content: "Prepared patch \(patch.id.uuidString) (\(summary.joined(separator: ", "))). No file was changed. Call apply_edit with this proposal_id to request approval; all files are written together or not at all.",
                                  metadata: ["proposal_id": patch.id.uuidString])
            case "propose_edit":
                guard let path = request.arguments["path"] else { throw WorkspaceError.missingPath }
                var edits: [(old: String, new: String)] = []
                if let raw = request.arguments["edits"] {
                    struct Pair: Decodable { let old: String; let new: String }
                    guard let pairs = try? JSONDecoder().decode([Pair].self, from: Data(raw.utf8)) else {
                        throw WorkspaceEditService.EditError.ambiguousMatch
                    }
                    edits = pairs.map { ($0.old, $0.new) }
                } else if let old = request.arguments["old"], let new = request.arguments["new"] {
                    edits = [(old, new)]
                } else { throw WorkspaceError.missingPath }
                let proposal = try await service.prepare(workspace: workspace, path: path, edits: edits)
                proposals[proposal.id] = Entry(workspace: workspace, proposal: proposal)
                return ToolResult(requestID: request.id, content: "Prepared edit \(proposal.id.uuidString) for \(path). No file was changed. Call apply_edit with proposal_id to request the user's before/after approval.", metadata: ["proposal_id": proposal.id.uuidString])
            case "apply_edit", "undo_edit":
                if let id = patchID(request) {
                    if request.name == "apply_edit" {
                        try await service.applyPatch(id)
                        return ToolResult(requestID: request.id, content: "Applied patch \(id.uuidString). undo_edit with the same proposal_id reverts every file in this run (deleted files are in the Trash).")
                    }
                    try await service.undoPatch(id)
                    patchWorkspaces.removeValue(forKey: id)
                    return ToolResult(requestID: request.id, content: "Reverted every file of patch \(id.uuidString).")
                }
                var entry = try entry(request)
                let id = entry.proposal.id
                guard entry.applied == (request.name == "undo_edit") else { throw WorkspaceEditService.EditError.unknownProposal }
                if request.name == "apply_edit" {
                    try await service.apply(id)
                    entry.applied = true; proposals[id] = entry
                } else {
                    try await service.undo(id); proposals.removeValue(forKey: id)
                }
                let outcome = request.name == "apply_edit"
                    ? "Applied edit \(id.uuidString) for \(entry.proposal.path). Undo is available only within this run and refuses subsequent file changes."
                    : (entry.proposal.isCreation
                        ? "Moved created file \(entry.proposal.path) to Trash. It can be recovered from Trash."
                        : "Restored the original contents of \(entry.proposal.path).")
                return ToolResult(requestID: request.id, content: outcome)
            default: throw WorkspaceEditService.EditError.unknownProposal
            }
        } catch { return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true) }
    }

    public func cancel(requestID: String) {}

    public func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        guard request.name == "apply_edit" || request.name == "undo_edit" else { return nil }
        if let id = patchID(request), let workspace = patchWorkspaces[id] {
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            return MissionToolIntent(operation: .edit, target: try MissionResource(kind: .directory, identifier: root.path))
        }
        let entry = try entry(request)
        let root = URL(fileURLWithPath: entry.workspace, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let path = entry.proposal.path
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw WorkspaceEditService.EditError.invalidPath }
        return MissionToolIntent(operation: .edit,
            target: try MissionResource(kind: .directory, identifier: target.path))
    }

    private func patchID(_ request: ToolRequest) -> UUID? {
        guard let value = request.arguments["proposal_id"], let id = UUID(uuidString: value),
              patchWorkspaces[id] == request.workspacePath else { return nil }
        return id
    }

    private func entry(_ request: ToolRequest) throws -> Entry {
        guard let value = request.arguments["proposal_id"], let id = UUID(uuidString: value),
              let entry = proposals[id], entry.workspace == request.workspacePath else { throw WorkspaceEditService.EditError.unknownProposal }
        return entry
    }
}
