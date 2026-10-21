import Foundation

public struct ToolArtifactPage: Codable, Sendable {
    public let id: String
    public let text: String
    public let offset: Int
    public let nextOffset: Int?
    public let totalBytes: Int

    public init(id: String, content: Data, offset: Int, limit: Int) throws {
        guard offset >= 0, offset <= content.count, (1...65_536).contains(limit) else {
            throw WorkspaceHistoryError.invalidRecord
        }
        var end = min(content.count, offset + limit)
        // Do not split UTF-8 continuation bytes between pages.
        if offset < content.count, content[offset] & 0xc0 == 0x80 { throw WorkspaceHistoryError.invalidRecord }
        while end < content.count && end > offset && content[end] & 0xc0 == 0x80 { end -= 1 }
        guard end > offset || offset == content.count else { throw WorkspaceHistoryError.invalidRecord }
        self.id = id; self.text = String(decoding: content[offset..<end], as: UTF8.self)
        self.offset = offset; self.nextOffset = end < content.count ? end : nil; self.totalBytes = content.count
    }

    /// `window` starts at `offset` and includes up to four lookahead bytes.
    /// A database can therefore serve a page without loading the whole blob.
    public init(id: String, window: Data, totalBytes: Int, offset: Int, limit: Int) throws {
        guard totalBytes >= 0, offset >= 0, offset <= totalBytes,
              (1...65_536).contains(limit),
              window.count >= min(totalBytes - offset, limit + 4) else {
            throw WorkspaceHistoryError.invalidRecord
        }
        if offset < totalBytes, window[0] & 0xc0 == 0x80 {
            throw WorkspaceHistoryError.invalidRecord
        }
        var end = min(totalBytes - offset, limit)
        while offset + end < totalBytes && end > 0 && window[end] & 0xc0 == 0x80 {
            end -= 1
        }
        guard end > 0 || offset == totalBytes else { throw WorkspaceHistoryError.invalidRecord }
        self.id = id
        self.text = String(decoding: window.prefix(end), as: UTF8.self)
        self.offset = offset
        self.nextOffset = offset + end < totalBytes ? offset + end : nil
        self.totalBytes = totalBytes
    }
}

public struct ToolArtifactSummary: Codable, Sendable {
    public let id: String
    public let runID: String
    public let byteCount: Int
    public let runStartedAt: Date

    public init(id: String, runID: String, byteCount: Int, runStartedAt: Date) {
        self.id = id; self.runID = runID; self.byteCount = byteCount; self.runStartedAt = runStartedAt
    }
}

public struct ToolArtifactListing: Codable, Sendable {
    public let artifacts: [ToolArtifactSummary]
    public let nextOffset: Int?

    public init(artifacts: [ToolArtifactSummary], nextOffset: Int?) {
        self.artifacts = artifacts; self.nextOffset = nextOffset
    }
}

public protocol ToolArtifactRepository: Sendable {
    func saveToolArtifact(id: String, runID: String, content: Data) async throws
    func readToolArtifact(id: String, runID: String, offset: Int, limit: Int) async throws -> ToolArtifactPage
    func readToolArtifact(id: String, conversationID: UUID, workspacePath: String,
                          offset: Int, limit: Int) async throws -> ToolArtifactPage
    func listToolArtifacts(conversationID: UUID, workspacePath: String,
                           offset: Int, limit: Int) async throws -> ToolArtifactListing
}
