import Foundation
import SQLite3

public enum ProjectSourceError: LocalizedError {
    case invalidSource, invalidName, quota, unreadable, missing, queryLimit
    public var errorDescription: String? {
        switch self {
        case .invalidSource: "This source is invalid. Choose a readable file up to 100 MB with at most 8 MB of extracted text."
        case .invalidName: "Use a source title of 1–255 characters and at most 1 KB, without slashes or control characters."
        case .quota: "Project sources are limited to 1,000 per project and 500 MB per device profile, including their search index. Remove sources before importing more. Nothing was truncated."
        case .unreadable: "The local source library could not be read safely. Its existing files have been preserved."
        case .missing: "This local source is no longer available."
        case .queryLimit: "The source query is too large. Use at most 8 KB of text."
        }
    }
}

public struct ProjectSourceRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let name: String
    public let mimeType: String
    public let sourceBytes: Int
    public let textBytes: Int
    public let importedAt: Date
    public let useInChat: Bool
    public let hasOriginal: Bool
    public let preview: String
}

public struct ProjectSourceExcerpt: Equatable, Sendable {
    public let sourceID: UUID
    public let name: String
    public let chunkIndex: Int
    public let text: String
    public var citation: String { "source:\(sourceID.uuidString.lowercased())#\(chunkIndex + 1)" }
}

/// A profile-scoped, device-only library. The caller supplies its own profile directory.
/// SQLite indexes bounded excerpts; immutable payloads retain the complete imported text/original.
/// No authentication, network, embeddings or model capability exists in this type.
public final class ProjectSourceStore: @unchecked Sendable {
    public static let maximumSourceBytes = 100_000_000
    public static let maximumTextBytes = 8_000_000
    public static let maximumProfileBytes = 500_000_000
    public static let maximumSourcesPerProject = 1_000
    public static let maximumContextBytes = 24_000
    public static let maximumLegacyBytes = 8_000_000
    private let lock = NSRecursiveLock()
    private let root: URL
    private var database: OpaquePointer?
    private let quotaBytes: Int
    private let projectLimit: Int
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, quotaBytes: Int = maximumProfileBytes, projectLimit: Int = maximumSourcesPerProject) throws {
        root = directory.appendingPathComponent("project-sources-v2", isDirectory: true)
        self.quotaBytes = min(max(1, quotaBytes), Self.maximumProfileBytes)
        self.projectLimit = min(max(1, projectLimit), Self.maximumSourcesPerProject)
        do {
            try Self.regularDirectory(directory)
            try Self.regularDirectory(root)
            try Self.regularDirectory(root.appendingPathComponent("payloads", isDirectory: true))
            let file = root.appendingPathComponent("index.sqlite")
            if FileManager.default.fileExists(atPath: file.path) { try Self.regularFile(file) }
            guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ProjectSourceError.unreadable }
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            let pageSize = Int(try scalar("PRAGMA page_size")) ?? 4096
            try execute("PRAGMA max_page_count=\(Self.maximumProfileBytes / max(1, pageSize))")
            guard try scalar("PRAGMA quick_check") == "ok" else { throw ProjectSourceError.unreadable }
            let version = try scalar("PRAGMA user_version")
            guard version == "0" || version == "2" else { throw ProjectSourceError.unreadable }
            try execute("CREATE TABLE IF NOT EXISTS sources (id TEXT PRIMARY KEY, project TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, sourceBytes INTEGER NOT NULL, textBytes INTEGER NOT NULL, imported REAL NOT NULL, enabled INTEGER NOT NULL, original INTEGER NOT NULL, preview TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS sources_project ON sources(project, enabled)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(tokens, text UNINDEXED, source UNINDEXED, ordinal UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("PRAGMA user_version=2")
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            #endif
            try migrateLegacy(directory.appendingPathComponent("project-documents.json"))
            try recoverRemovedPayloads()
            try validatePayloads()
        } catch {
            if let database { sqlite3_close(database); self.database = nil }
            throw (error as? CancellationError) ?? ProjectSourceError.unreadable
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    public func records(projectID: UUID? = nil, sourceID: UUID? = nil) throws -> [ProjectSourceRecord] {
        try locked {
            var conditions: [String] = [], values: [Value] = []
            if let projectID { conditions.append("project=?"); values.append(.text(projectID.uuidString)) }
            if let sourceID { conditions.append("id=?"); values.append(.text(sourceID.uuidString)) }
            let sql = "SELECT id,project,name,mime,sourceBytes,textBytes,imported,enabled,original,preview FROM sources" + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")) + " ORDER BY imported,id"
            return try rows(sql, values) { statement in
                guard let id = UUID(uuidString: self.string(statement, 0)), let project = UUID(uuidString: self.string(statement, 1)) else { throw ProjectSourceError.unreadable }
                return ProjectSourceRecord(id: id, projectID: project, name: self.string(statement, 2), mimeType: self.string(statement, 3), sourceBytes: Int(sqlite3_column_int64(statement, 4)), textBytes: Int(sqlite3_column_int64(statement, 5)), importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), useInChat: sqlite3_column_int(statement, 7) != 0, hasOriginal: sqlite3_column_int(statement, 8) != 0, preview: self.string(statement, 9))
            }
        }
    }

    @discardableResult public func add(projectID: UUID, name: String, mimeType: String, text: String, original: Data?, enabled: Bool = true) throws -> ProjectSourceRecord {
        try locked {
            let id = UUID(), imported = Date()
            do {
                try transaction {
                    try insert(id: id, project: projectID, name: name, mime: mimeType, text: text, original: original, sourceBytes: original?.count ?? text.utf8.count, imported: imported, enabled: enabled)
                    try checkDiskQuota()
                }
            } catch { try? FileManager.default.removeItem(at: payload(id)); throw error }
            // Never throw cancellation after a successful COMMIT: callers must be able to
            // distinguish a retained source from an import that actually rolled back.
            return ProjectSourceRecord(id: id, projectID: projectID, name: name, mimeType: mimeType, sourceBytes: original?.count ?? text.utf8.count, textBytes: text.utf8.count, importedAt: imported, useInChat: enabled, hasOriginal: original != nil, preview: Self.prefix(text, bytes: 4_000))
        }
    }

    public func setEnabled(_ id: UUID, enabled: Bool) throws {
        try locked { try execute("UPDATE sources SET enabled=? WHERE id=?", [.integer(enabled ? 1 : 0), .text(id.uuidString)]) }
    }

    /// Renames display metadata and matching tokens atomically. Payloads, chunk identities,
    /// import dates and the source's inclusion choice remain unchanged.
    public func rename(_ id: UUID, projectID: UUID, name: String) throws {
        try locked {
            try Task.checkCancellation()
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 255, title.utf8.count <= 1_024,
                  !title.contains("/"), !title.contains("\\"),
                  title.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProjectSourceError.invalidName }
            try transaction {
                guard let record = try records(projectID: projectID, sourceID: id).first else { throw ProjectSourceError.missing }
                guard record.name != title else { return }
                let chunks: [(Int, String)] = try rows("SELECT rowid,text FROM chunks WHERE source=? ORDER BY CAST(ordinal AS INTEGER)", [.text(id.uuidString)]) {
                    (Int(sqlite3_column_int64($0, 0)), self.string($0, 1))
                }
                try execute("UPDATE sources SET name=? WHERE id=? AND project=?", [.text(title), .text(id.uuidString), .text(projectID.uuidString)])
                for (rowID, text) in chunks {
                    try Task.checkCancellation()
                    try execute("UPDATE chunks SET tokens=? WHERE rowid=? AND source=?", [.text(Self.tokens(title + " " + text).joined(separator: " ")), .integer(rowID), .text(id.uuidString)])
                }
                try checkDiskQuota()
            }
        }
    }

    public func remove(_ id: UUID) throws {
        try locked {
            // Payloads are removed before metadata commits. A failed transaction leaves missing data
            // and is detected fail-closed on reopening; it never substitutes another profile's files.
            // Rename into a private tombstone permits rollback without deleting the only copy.
            let folder = payload(id), tombstone = root.appendingPathComponent("removed-\(id.uuidString)")
            guard FileManager.default.fileExists(atPath: folder.path) else { throw ProjectSourceError.missing }
            try FileManager.default.moveItem(at: folder, to: tombstone)
            do {
                try transaction {
                    try execute("DELETE FROM chunks WHERE source=?", [.text(id.uuidString)])
                    try execute("DELETE FROM sources WHERE id=?", [.text(id.uuidString)])
                }
            } catch { try? FileManager.default.moveItem(at: tombstone, to: folder); throw error }
            try FileManager.default.removeItem(at: tombstone)
        }
    }

    public func readText(_ id: UUID) throws -> String {
        try locked {
            guard let record = try records(sourceID: id).first else { throw ProjectSourceError.missing }
            try Self.checkDirectory(payload(id))
            let data = try Self.read(payload(id).appendingPathComponent("text.utf8"), limit: Self.maximumTextBytes)
            guard data.count == record.textBytes, let text = String(data: data, encoding: .utf8) else { throw ProjectSourceError.unreadable }
            return text
        }
    }
    public func readOriginal(_ id: UUID) throws -> Data {
        try locked {
            guard let record = try records(sourceID: id).first, record.hasOriginal else { throw ProjectSourceError.missing }
            try Self.checkDirectory(payload(id))
            let data = try Self.read(payload(id).appendingPathComponent("original"), limit: Self.maximumSourceBytes)
            guard data.count == record.sourceBytes else { throw ProjectSourceError.unreadable }
            return data
        }
    }

    /// Empty/no-match queries return no excerpts. The source text can never authorize a tool.
    /// At most eight 2-KB chunks, four sources and 24 KB including citation headers are returned.
    public func search(projectID: UUID, query: String) throws -> [ProjectSourceExcerpt] {
        try locked {
            try Task.checkCancellation()
            guard query.utf8.count <= 8_000 else { throw ProjectSourceError.queryLimit }
            let terms = Array(Set(Self.tokens(query))).sorted().prefix(64)
            guard !terms.isEmpty else { return [] }
            let expression = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
            let candidates = try rows("SELECT chunks.source,sources.name,chunks.ordinal,chunks.text FROM chunks JOIN sources ON sources.id=chunks.source WHERE chunks MATCH ? AND sources.project=? AND sources.enabled=1 ORDER BY bm25(chunks), sources.id, CAST(chunks.ordinal AS INTEGER) LIMIT 64", [.text(expression), .text(projectID.uuidString)]) { statement in
                guard let id = UUID(uuidString: self.string(statement, 0)) else { throw ProjectSourceError.unreadable }
                return ProjectSourceExcerpt(sourceID: id, name: self.string(statement, 1), chunkIndex: Int(sqlite3_column_int(statement, 2)), text: self.string(statement, 3))
            }
            var result: [ProjectSourceExcerpt] = [], sources: Set<UUID> = [], bytes = 0
            for item in candidates {
                try Task.checkCancellation()
                if !sources.contains(item.sourceID), sources.count >= 4 { continue }
                let cost = item.text.utf8.count + item.name.utf8.count + item.citation.utf8.count + 128
                guard result.count < 8, bytes + cost <= Self.maximumContextBytes else { continue }
                result.append(item); sources.insert(item.sourceID); bytes += cost
            }
            return result
        }
    }

    /// A tool can request one cited chunk only within the active project and enabled sources.
    public func readChunk(sourceID: UUID, chunkIndex: Int, projectID: UUID) throws -> ProjectSourceExcerpt {
        try locked {
            guard chunkIndex >= 0 else { throw ProjectSourceError.missing }
            return try rows("SELECT sources.name,chunks.text FROM chunks JOIN sources ON sources.id=chunks.source WHERE sources.id=? AND sources.project=? AND sources.enabled=1 AND chunks.ordinal=? LIMIT 1", [.text(sourceID.uuidString), .text(projectID.uuidString), .integer(chunkIndex)]) { statement in
                ProjectSourceExcerpt(sourceID: sourceID, name: self.string(statement, 0), chunkIndex: chunkIndex, text: self.string(statement, 1))
            }.first.unwrap()
        }
    }

    private func insert(id: UUID, project: UUID, name: String, mime: String, text: String, original: Data?, sourceBytes: Int, imported: Date, enabled: Bool) throws {
        try Task.checkCancellation()
        let bytes = Data(text.utf8)
        guard !name.isEmpty, name.count <= 255, mime.count <= 255, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0"), bytes.count <= Self.maximumTextBytes, sourceBytes > 0, sourceBytes <= Self.maximumSourceBytes else { throw ProjectSourceError.invalidSource }
        let current = Int(try scalar("SELECT coalesce(sum(textBytes + CASE WHEN original=1 THEN sourceBytes ELSE 0 END),0) FROM sources")) ?? quotaBytes
        let count = Int(try scalar("SELECT count(*) FROM sources WHERE project=?", [.text(project.uuidString)])) ?? projectLimit
        let allCount = Int(try scalar("SELECT count(*) FROM sources")) ?? 10_000
        guard count < projectLimit, allCount < 10_000, bytes.count + (original?.count ?? 0) <= quotaBytes - current else { throw ProjectSourceError.quota }
        let folder = payload(id)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ProjectSourceError.unreadable }
        try Self.regularDirectory(folder)
        do {
            try bytes.write(to: folder.appendingPathComponent("text.utf8"), options: [.atomic, .completeFileProtection])
            if let original { try original.write(to: folder.appendingPathComponent("original"), options: [.atomic, .completeFileProtection]) }
            try execute("INSERT INTO sources VALUES (?,?,?,?,?,?,?,?,?,?)", [.text(id.uuidString), .text(project.uuidString), .text(name), .text(mime), .integer(sourceBytes), .integer(bytes.count), .real(imported.timeIntervalSince1970), .integer(enabled ? 1 : 0), .integer(original == nil ? 0 : 1), .text(Self.prefix(text, bytes: 4_000))])
            for (index, chunk) in Self.chunks(text).enumerated() {
                try Task.checkCancellation()
                try execute("INSERT INTO chunks(tokens,text,source,ordinal) VALUES (?,?,?,?)", [.text(Self.tokens(name + " " + chunk).joined(separator: " ")), .text(chunk), .text(id.uuidString), .integer(index)])
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    private struct Legacy: Decodable {
        let id: UUID, projectID: UUID, name: String, mimeType: String, sourceBytes: Int, text: String, importedAt: Date, useInChat: Bool
    }
    private func migrateLegacy(_ url: URL) throws {
        guard try scalar("SELECT count(*) FROM metadata WHERE key='legacy-migrated'") == "0" else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bytes = try Self.read(url, limit: Self.maximumLegacyBytes)
        let old = try JSONDecoder().decode([Legacy].self, from: bytes)
        guard old.count <= 1_000, Set(old.map(\.id)).count == old.count else { throw ProjectSourceError.unreadable }
        var created: [UUID] = []
        do {
            try transaction {
                // A second process can have migrated while this connection waited for its lock.
                guard try scalar("SELECT count(*) FROM metadata WHERE key='legacy-migrated'") == "0" else { return }
                for item in old {
                    try insert(id: item.id, project: item.projectID, name: item.name, mime: item.mimeType, text: item.text, original: nil, sourceBytes: item.sourceBytes, imported: item.importedAt, enabled: item.useInChat)
                    created.append(item.id)
                }
                try execute("INSERT INTO metadata VALUES ('legacy-migrated','1')")
                try checkDiskQuota()
            }
        } catch { for id in created { try? FileManager.default.removeItem(at: payload(id)) }; throw error }
        // Never modify/delete the legacy JSON: it remains an explicit compatibility backup.
    }
    private func validatePayloads() throws {
        let records = try records()
        guard records.count <= 10_000 else { throw ProjectSourceError.unreadable }
        for record in records {
            try Task.checkCancellation()
            try Self.checkDirectory(payload(record.id))
            for (name, expected) in [("text.utf8", record.textBytes)] + (record.hasOriginal ? [("original", record.sourceBytes)] : []) {
                let url = payload(record.id).appendingPathComponent(name)
                try Self.regularFile(url)
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == expected else { throw ProjectSourceError.unreadable }
            }
        }
    }
    private func recoverRemovedPayloads() throws {
        let referenced = Set(try records().map(\.id))
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("removed-") {
            guard let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) else { throw ProjectSourceError.unreadable }
            try Self.checkDirectory(url)
            if referenced.contains(id) {
                guard !FileManager.default.fileExists(atPath: payload(id).path) else { throw ProjectSourceError.unreadable }
                try FileManager.default.moveItem(at: url, to: payload(id))
            } else { try FileManager.default.removeItem(at: url) }
        }
    }
    private func checkDiskQuota() throws {
        // Include index pages and every retained payload, including interrupted-import orphans.
        // SQLite's rollback journal is transient and may require an additional index-sized reserve.
        let pageCount = Int(try scalar("PRAGMA page_count")) ?? Self.maximumProfileBytes
        let pageSize = Int(try scalar("PRAGMA page_size")) ?? 4096
        var total = pageCount * pageSize
        guard let iterator = FileManager.default.enumerator(at: root.appendingPathComponent("payloads"), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw ProjectSourceError.unreadable }
        for case let file as URL in iterator {
            try Task.checkCancellation()
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard value.isSymbolicLink != true else { throw ProjectSourceError.unreadable }
            if value.isRegularFile == true { total += value.fileSize ?? quotaBytes }
            guard total <= quotaBytes else { throw ProjectSourceError.quota }
        }
        guard total <= quotaBytes else { throw ProjectSourceError.quota }
    }
    private func payload(_ id: UUID) -> URL { root.appendingPathComponent("payloads/" + id.uuidString, isDirectory: true) }
    private static func regularDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try checkDirectory(url)
    }
    private static func checkDirectory(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard value.isDirectory == true, value.isSymbolicLink != true else { throw ProjectSourceError.unreadable }
    }
    private static func regularFile(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true else { throw ProjectSourceError.unreadable }
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        try regularFile(url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ProjectSourceError.unreadable }; return data
    }
    private static func prefix(_ text: String, bytes: Int) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self).dropLastWhileReplacement
    }
    private static func chunks(_ text: String) -> [String] {
        var result: [String] = [], current = "", size = 0
        for character in text.unicodeScalars {
            let count = String(character).utf8.count
            if size + count > 2_000, !current.isEmpty {
                result.append(current)
                // Overlap preserves ordinary query words that straddle a chunk boundary.
                var overlap: [Unicode.Scalar] = [], overlapBytes = 0
                for scalar in current.unicodeScalars.reversed() {
                    let scalarBytes = String(scalar).utf8.count
                    if overlapBytes + scalarBytes > 384 { break }
                    overlap.append(scalar); overlapBytes += scalarBytes
                }
                current = String(String.UnicodeScalarView(overlap.reversed())); size = overlapBytes
            }
            current.unicodeScalars.append(character); size += count
        }
        if !current.isEmpty { result.append(current) }; return result
    }
    private static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = [], word = "", previousCJK: Unicode.Scalar?
        func flush() { if !word.isEmpty { words.append(word); word = "" } }
        for scalar in folded.unicodeScalars {
            let cjk = (0x3040...0x30ff).contains(scalar.value) || (0x3400...0x9fff).contains(scalar.value) || (0xac00...0xd7af).contains(scalar.value)
            if cjk {
                flush(); words.append(String(scalar))
                if let previousCJK { words.append(String(previousCJK) + String(scalar)) }
                previousCJK = scalar
            } else {
                previousCJK = nil
                if CharacterSet.alphanumerics.contains(scalar) { word.unicodeScalars.append(scalar) }
                else { flush() }
            }
        }
        flush()
        let stop: Set<String> = ["a", "an", "the", "and", "or", "is", "are", "of", "to", "in", "it", "my", "me", "what", "which", "please", "for", "with", "from", "on", "le", "la", "les", "de", "des", "du", "un", "une", "et", "ou", "est", "dans", "pour", "avec", "mon", "ma", "mes", "quel", "quelle", "quels", "quelles"]
        return words.filter { $0.utf8.count <= 256 && !stop.contains($0) }
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private enum Value { case text(String), integer(Int), real(Double) }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw ProjectSourceError.unreadable }
        for (index, value) in values.enumerated() {
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(result, Int32(index + 1), text, -1, transient)
            case .integer(let number): status = sqlite3_bind_int64(result, Int32(index + 1), Int64(number))
            case .real(let number): status = sqlite3_bind_double(result, Int32(index + 1), number)
            }
            guard status == SQLITE_OK else { sqlite3_finalize(result); throw ProjectSourceError.unreadable }
        }
        return result
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let result = try statement(sql, values); defer { sqlite3_finalize(result) }
        var status = sqlite3_step(result)
        while status == SQLITE_ROW { status = sqlite3_step(result) }
        guard status == SQLITE_DONE else { throw ProjectSourceError.unreadable }
    }
    private func rows<T>(_ sql: String, _ values: [Value] = [], transform: (OpaquePointer) throws -> T) throws -> [T] {
        let result = try statement(sql, values); defer { sqlite3_finalize(result) }
        var output: [T] = [], status = sqlite3_step(result)
        while status == SQLITE_ROW { try Task.checkCancellation(); output.append(try transform(result)); status = sqlite3_step(result) }
        guard status == SQLITE_DONE else { throw ProjectSourceError.unreadable }; return output
    }
    private func scalar(_ sql: String, _ values: [Value] = []) throws -> String { try rows(sql, values) { self.string($0, 0) }.first ?? "" }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try Task.checkCancellation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let self else { throw ProjectSourceError.missing }; return self }
}
private extension String {
    var dropLastWhileReplacement: String { var copy = self; while copy.last == "\u{fffd}" { copy.removeLast() }; return copy }
}
