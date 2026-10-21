import AIMAgentKit
import AIMApplication
import GRDB
import XCTest

final class AgentMemoryToolTests: XCTestCase {
    func testSearchHonorsProjectAndGlobalMemoryChoice() async throws {
        let database = try AIMDatabase(inMemory: true)
        let memories = SQLiteMemoryRepository(database: database)
        let projectA = UUID()
        let projectB = UUID()
        try await memories.save(MemoryItem(kind: .fact, scope: "global", scopeKey: "self",
                                           subjectKey: "language", content: "Prefers keyword in French"))
        try await memories.save(MemoryItem(kind: .fact, scope: "project", scopeKey: projectA.uuidString,
                                           subjectKey: "project A", content: "keyword in first project"))
        try await memories.save(MemoryItem(kind: .fact, scope: "project", scopeKey: projectB.uuidString,
                                           subjectKey: "project B", content: "keyword in second project"))
        let request = ToolRequest(name: "search_memory", arguments: ["query": "keyword"], risk: .sensitiveRead)

        let projectOnly = AgentMemoryToolService(repository: memories, projectID: projectA, includeGlobal: false)
        let projectResult = await projectOnly.execute(request)
        XCTAssertTrue(projectResult.content.contains("first project"))
        XCTAssertFalse(projectResult.content.contains("second project"))
        XCTAssertFalse(projectResult.content.contains("French"))

        let withGlobal = AgentMemoryToolService(repository: memories, projectID: projectA, includeGlobal: true)
        let globalResult = await withGlobal.execute(request)
        XCTAssertTrue(globalResult.content.contains("first project"))
        XCTAssertTrue(globalResult.content.contains("French"))
        XCTAssertFalse(globalResult.content.contains("second project"))
    }

    func testArchivedAndQuarantinedMemoriesAreNotExposed() async throws {
        let database = try AIMDatabase(inMemory: true)
        let memories = SQLiteMemoryRepository(database: database)
        try await memories.save(MemoryItem(kind: .fact, scope: "global", scopeKey: "self",
                                           subjectKey: "archived", content: "keyword archived", status: .archived))
        try await memories.save(MemoryItem(kind: .fact, scope: "global", scopeKey: "self",
                                           subjectKey: "quarantined", content: "keyword quarantined", status: .quarantined))
        let tool = AgentMemoryToolService(repository: memories, projectID: nil, includeGlobal: true)
        let result = await tool.execute(ToolRequest(name: "search_memory", arguments: ["query": "keyword"], risk: .sensitiveRead))
        XCTAssertFalse(result.content.contains("keyword archived"))
        XCTAssertFalse(result.content.contains("keyword quarantined"))
    }

    func testScopedIndexFindsSubjectAndSeparatedTermsWithoutLeakingOtherProjects() async throws {
        let database = try AIMDatabase(inMemory: true)
        let memories = SQLiteMemoryRepository(database: database)
        let project = UUID()
        for index in 0..<120 {
            try await memories.save(MemoryItem(kind: .fact, scope: "project",
                scopeKey: UUID().uuidString, subjectKey: "willow \(index)",
                content: "Unrelated private project detail"))
        }
        try await memories.save(MemoryItem(kind: .fact, scope: "project",
            scopeKey: project.uuidString, subjectKey: "Willow deployment",
            content: "The rollout uses a staged release."))
        let tool = AgentMemoryToolService(repository: memories, projectID: project, includeGlobal: false)
        let result = await tool.execute(ToolRequest(name: "search_memory",
            arguments: ["query": "willow: rollout (status)"], risk: .sensitiveRead))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("staged release"))
        XCTAssertFalse(result.content.contains("Unrelated private"))
    }

    func testExistingMemorySubjectsBecomeSearchableAfterIndexMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("memory.sqlite").path
        let project = UUID()
        var database: AIMDatabase? = try AIMDatabase(path: path)
        let repository = SQLiteMemoryRepository(database: try XCTUnwrap(database))
        try await repository.save(MemoryItem(kind: .fact, scope: "project",
            scopeKey: project.uuidString, subjectKey: "Willow migration",
            content: "A legacy saved preference."))
        try await database?.pool.write { db in
            try db.execute(sql: "UPDATE memorySearch SET content = 'A legacy saved preference.'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v22-memory-subject-index'")
        }
        database = nil
        let reopened = try AIMDatabase(path: path)
        let found = try await SQLiteMemoryRepository(database: reopened)
            .searchScoped("Willow", projectID: project, includeGlobal: false, limit: 8)
        XCTAssertEqual(found.count, 1)
    }
}
