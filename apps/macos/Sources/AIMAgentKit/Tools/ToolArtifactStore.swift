import AIMApplication
import Foundation

/// Text only. Screenshot pixels are never written to this store.
public actor ToolArtifactStore: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["read_tool_artifact", "list_tool_artifacts"]
    private let repository: (any ToolArtifactRepository)?
    private let runID: String
    private let conversationID: UUID?
    private let workspacePath: String?
    private var ephemeral: [String: Data] = [:]

    public init(runID: String = UUID().uuidString, repository: (any ToolArtifactRepository)? = nil,
                conversationID: UUID? = nil, workspacePath: String? = nil) {
        self.runID = runID; self.repository = repository
        self.conversationID = conversationID; self.workspacePath = workspacePath
    }

    public func save(_ text: String) async throws -> String {
        let data = Data(text.utf8)
        guard data.count <= 32 * 1_024 * 1_024 else { throw ModelToolError.limitReached }
        let id = UUID().uuidString
        if let repository { try await repository.saveToolArtifact(id: id, runID: runID, content: data) }
        else { ephemeral[id] = data }
        return id
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            if request.name == "list_tool_artifacts" {
                guard let repository, let conversationID, let workspacePath,
                      let offset = Int(request.arguments["offset"] ?? "0"),
                      let limit = Int(request.arguments["limit"] ?? "20") else {
                    throw WorkspaceHistoryError.invalidRecord
                }
                let listing = try await repository.listToolArtifacts(
                    conversationID: conversationID, workspacePath: workspacePath,
                    offset: offset, limit: limit)
                let data = try JSONEncoder().encode(listing)
                return ToolResult(requestID: request.id, content: String(decoding: data, as: UTF8.self))
            }
            guard request.name == "read_tool_artifact", let id = request.arguments["artifact_id"],
                  let offset = Int(request.arguments["offset"] ?? "0"),
                  let limit = Int(request.arguments["limit"] ?? "32768") else { throw WorkspaceHistoryError.invalidRecord }
            let page: ToolArtifactPage
            if let repository, let conversationID, let workspacePath {
                page = try await repository.readToolArtifact(id: id, conversationID: conversationID,
                                                              workspacePath: workspacePath,
                                                              offset: offset, limit: limit)
            } else if let repository {
                page = try await repository.readToolArtifact(id: id, runID: runID, offset: offset, limit: limit)
            }
            else {
                guard let data = ephemeral[id] else { throw WorkspaceHistoryError.invalidRecord }
                page = try ToolArtifactPage(id: id, content: data, offset: offset, limit: limit)
            }
            return ToolResult(requestID: request.id, content: page.text,
                metadata: ["artifact_id": page.id, "offset": String(page.offset),
                           "next_offset": page.nextOffset.map(String.init) ?? "end", "total_bytes": String(page.totalBytes)])
        } catch { return ToolResult(requestID: request.id, content: "Artifact unavailable or invalid byte range.", isError: true) }
    }
    public func cancel(requestID: String) {}
}
