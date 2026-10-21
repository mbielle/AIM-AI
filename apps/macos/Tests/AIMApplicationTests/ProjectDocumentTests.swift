import AIMApplication
import XCTest

final class ProjectDocumentTests: XCTestCase {
    func testFileCountLimitAndExplicitCopyRemoval() async throws {
        let db = try AIMDatabase(inMemory: true), project = AIMProject(name: "Count")
        try await SQLiteProjectRepository(database: db).save(project)
        let repository = SQLiteProjectDocumentRepository(database: db)
        for index in 0..<8 {
            try await repository.add(ProjectDocument(projectID: project.id, name: "file-\(index)", content: ""))
        }
        do { try await repository.add(ProjectDocument(projectID: project.id, name: "ninth", content: "")); XCTFail() } catch {}
        let saved = try await repository.list(projectID: project.id)
        try await repository.remove(id: saved[0].id, projectID: project.id)
        try await repository.add(ProjectDocument(projectID: project.id, name: "replacement", content: ""))
        let reloaded = try await SQLiteProjectDocumentRepository(database: db).list(projectID: project.id)
        XCTAssertEqual(reloaded.count, 8)
        XCTAssertFalse(reloaded.contains { $0.id == saved[0].id })
    }

    func testImportStoresSnapshotAndDeletingProjectCascadesCopies() async throws {
        let db = try AIMDatabase(inMemory: true), project = AIMProject(name: "Documents")
        let projects = SQLiteProjectRepository(database: db)
        try await projects.save(project)
        let repository = SQLiteProjectDocumentRepository(database: db)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("First snapshot".utf8).write(to: file)
        try await repository.importFile(file, projectID: project.id)
        try Data("Changed original".utf8).write(to: file)
        let saved = try await repository.list(projectID: project.id)
        XCTAssertEqual(saved.first?.content, "First snapshot")
        let context = ProjectContext.messages([], project: project, conversationID: UUID(), documents: saved)
        XCTAssertTrue(context.first?.content.contains("First snapshot") == true)
        XCTAssertFalse(context.first?.content.contains(file.deletingLastPathComponent().path) == true)
        try await projects.delete(id: project.id)
        let removed = try await repository.list(projectID: project.id)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Changed original")
    }

    func testLimitsAndProjectIsolation() async throws {
        let db = try AIMDatabase(inMemory: true), project = AIMProject(name: "Limits")
        try await SQLiteProjectRepository(database: db).save(project)
        let repository = SQLiteProjectDocumentRepository(database: db)
        for name in ["one", "two"] {
            try await repository.add(ProjectDocument(projectID: project.id, name: name, content: String(repeating: "x", count: 64_000)))
        }
        do { try await repository.add(ProjectDocument(projectID: project.id, name: "overflow", content: "x")); XCTFail() } catch {}
        let foreign = ProjectDocument(projectID: UUID(), name: "foreign", content: "Must not leak")
        let context = ProjectContext.messages([], project: project, conversationID: UUID(), documents: [foreign])
        XCTAssertTrue(context.isEmpty)
        let saved = try await repository.list(projectID: project.id)
        try await repository.remove(id: saved[0].id, projectID: UUID())
        let retained = try await repository.list(projectID: project.id)
        XCTAssertEqual(retained.count, 2)
    }

    func testBinaryAndOversizedImportsAreRejected() async throws {
        let db = try AIMDatabase(inMemory: true), project = AIMProject(name: "Import")
        try await SQLiteProjectRepository(database: db).save(project)
        let repository = SQLiteProjectDocumentRepository(database: db)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for bytes in [Data([0, 1, 2]), Data([0xff, 0xfe]), Data(repeating: 65, count: 64_001)] {
            try bytes.write(to: file)
            do { try await repository.importFile(file, projectID: project.id); XCTFail() } catch {}
        }
        let saved = try await repository.list(projectID: project.id)
        XCTAssertTrue(saved.isEmpty)
    }
}
