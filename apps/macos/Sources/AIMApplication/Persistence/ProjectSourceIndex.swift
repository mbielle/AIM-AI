import Foundation
import GRDB

public struct ProjectSourceChunk: Sendable, Equatable {
    public let relativePath: String
    public let startLine: Int
    public let content: String

    public init(relativePath: String, startLine: Int, content: String) {
        self.relativePath = relativePath
        self.startLine = startLine
        self.content = content
    }
}

public enum ProjectSourceIndexError: LocalizedError {
    case invalidChunk

    public var errorDescription: String? { "A project source contains an invalid text passage." }
}

/// Local lexical retrieval. File content stays in SQLite on this Mac until a
/// relevant passage is selected for a particular request to the user's BYOK model.
public actor SQLiteProjectSourceIndex {
    private let database: AIMDatabase

    private static let questionWords: Set<String> = [
        "about", "avec", "can", "comment", "could", "dans", "des", "does", "explain", "expliquer",
        "file", "fichier", "files", "fix", "for", "from", "how", "improve", "les", "please", "pour",
        "project", "projet", "que", "qui", "the", "this", "une", "what", "where", "which", "with",
        "you", "your"
    ]

    public init(database: AIMDatabase) { self.database = database }

    public func replace(source: ProjectSource, chunks: [ProjectSourceChunk], scanStartedAt: Date = .now) throws {
        guard chunks.allSatisfy({ !$0.relativePath.isEmpty && !$0.relativePath.hasPrefix("/") && !$0.relativePath.contains("..") && $0.startLine > 0 && !$0.content.isEmpty && $0.content.utf8.count <= 4_096 }) else {
            throw ProjectSourceIndexError.invalidChunk
        }
        try database.pool.write { db in
            let belongs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectSources WHERE id = ? AND projectID = ?", arguments: [source.id.uuidString, source.projectID.uuidString]) ?? 0
            guard belongs == 1 else { throw ProjectSourceIndexError.invalidChunk }
            try db.execute(sql: "DELETE FROM projectSourceChunks WHERE sourceID = ?", arguments: [source.id.uuidString])
            for chunk in chunks {
                try db.execute(sql: "INSERT INTO projectSourceChunks (sourceID, projectID, relativePath, startLine, content) VALUES (?, ?, ?, ?, ?)",
                               arguments: [source.id.uuidString, source.projectID.uuidString, chunk.relativePath, chunk.startLine, chunk.content])
            }
            // Record the start, not completion: a file changed during a scan
            // must still appear newer on the next freshness check.
            try db.execute(sql: "UPDATE projectSources SET lastScannedAt = ? WHERE id = ?", arguments: [scanStartedAt, source.id.uuidString])
        }
    }

    public func passages(projectID: UUID, query: String, limit: Int = 8) throws -> [ProjectSourceChunk] {
        let terms = Self.retrievalTerms(query)
        guard !terms.isEmpty else { return [] }
        let resultLimit = min(max(limit, 0), 20)
        guard resultLimit > 0 else { return [] }
        let expression = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.relativePath, c.startLine, c.content
                FROM projectSourceSearch s
                JOIN projectSourceChunks c ON c.id = s.rowid
                WHERE projectSourceSearch MATCH ? AND c.projectID = ?
                ORDER BY bm25(projectSourceSearch, 2.0, 1.0), c.relativePath, c.startLine
                LIMIT ?
                """, arguments: [expression, projectID.uuidString, min(200, max(40, resultLimit * 12))])
            let candidates = rows.map { ProjectSourceChunk(relativePath: $0["relativePath"], startLine: $0["startLine"], content: $0["content"]) }
            // First include the best passage from each matching file. If the
            // question is concentrated in one file, fill the remaining slots
            // with its next-best passages in the original FTS order.
            var selected: [ProjectSourceChunk] = []
            var paths = Set<String>()
            for chunk in candidates where paths.insert(chunk.relativePath).inserted {
                selected.append(chunk)
                if selected.count == resultLimit { return selected }
            }
            for chunk in candidates where !selected.contains(where: { $0.relativePath == chunk.relativePath && $0.startLine == chunk.startLine }) {
                selected.append(chunk)
                if selected.count == resultLimit { break }
            }
            return selected
        }
    }

    private static func retrievalTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        for token in query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let term = String(token)
            guard term.count >= 3, term.count <= 64, !questionWords.contains(term), seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == 256 { break }
        }
        // Long prompts often name the concrete file or feature at the end.
        // Retaining both ends avoids losing that clue behind introductory text.
        guard terms.count > 16 else { return terms }
        return Array(terms.prefix(8)) + Array(terms.suffix(8))
    }

    public func chunkCount(sourceID: UUID) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectSourceChunks WHERE sourceID = ?", arguments: [sourceID.uuidString]) ?? 0
        }
    }
}
