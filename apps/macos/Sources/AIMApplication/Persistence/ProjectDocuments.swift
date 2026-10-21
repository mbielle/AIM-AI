import Foundation
import GRDB

public struct ProjectDocument: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "projectDocuments"
    public let id: String
    public let projectID: String
    public let name: String
    public let content: String
    public let importedAt: Date
    public init(projectID: UUID, name: String, content: String) {
        id = UUID().uuidString; self.projectID = projectID.uuidString
        self.name = name; self.content = content; importedAt = .now
    }
}

public enum ProjectDocumentError: LocalizedError {
    case invalidText, limit, busy
    public var errorDescription: String? {
        switch self {
        case .invalidText: "Choose a regular UTF-8 text file without binary content (maximum 64 KB)."
        case .limit: "A project supports up to 8 text files and 128 KB of combined text. Remove a file before adding more."
        case .busy: "Wait for the active run to finish before changing project files."
        }
    }
}

public actor SQLiteProjectDocumentRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }
    public func list(projectID: UUID) throws -> [ProjectDocument] {
        try database.pool.read { db in
            try ProjectDocument.filter(Column("projectID") == projectID.uuidString).order(Column("importedAt"), Column("id")).fetchAll(db)
        }
    }
    public func importFile(_ url: URL, projectID: UUID) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ProjectDocumentError.invalidText }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 64_001) ?? Data()
        guard data.count <= 64_000, !data.contains(0), let content = String(data: data, encoding: .utf8) else { throw ProjectDocumentError.invalidText }
        try add(ProjectDocument(projectID: projectID, name: url.lastPathComponent, content: content))
    }
    public func add(_ document: ProjectDocument) throws {
        guard !document.name.isEmpty, document.name.count <= 255,
              document.content.utf8.count <= 64_000, !document.content.contains("\0") else { throw ProjectDocumentError.invalidText }
        try database.pool.write { db in
            let existing = try ProjectDocument.filter(Column("projectID") == document.projectID).fetchAll(db)
            guard existing.count < 8, existing.reduce(0, { $0 + $1.content.utf8.count }) + document.content.utf8.count <= 128_000 else { throw ProjectDocumentError.limit }
            try document.insert(db)
        }
    }
    public func remove(id: String, projectID: UUID) throws {
        try database.pool.write { db in
            _ = try ProjectDocument.filter(Column("id") == id && Column("projectID") == projectID.uuidString).deleteAll(db)
        }
    }
}
