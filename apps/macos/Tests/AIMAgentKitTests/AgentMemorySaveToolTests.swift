import AIMAgentKit
import AIMApplication
import XCTest

final class AgentMemorySaveToolTests: XCTestCase {
    func testAgentSavesUpdatesAndRefusesSecretsAndTheMemorySurvivesAReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "aim.sqlite").path
        let project = UUID()
        do {
            let repository = SQLiteMemoryRepository(database: try AIMDatabase(path: path))
            let tool = AgentMemoryToolService(repository: repository, projectID: project, includeGlobal: true)
            func save(_ arguments: [String: String]) async -> ToolResult {
                await tool.execute(ToolRequest(name: "memory_save", arguments: arguments, risk: .localMutation))
            }
            let first = await save(["subject": "Editor", "content": "Mathieu codes in Zed.", "kind": "preference"])
            XCTAssertFalse(first.isError); XCTAssertTrue(first.content.hasPrefix("Saved to memory (global)"))
            let update = await save(["subject": "editor", "content": "Mathieu codes in Xcode now.", "kind": "preference"])
            XCTAssertTrue(update.content.hasPrefix("Memory updated"))
            let scoped = await save(["subject": "Stack", "content": "The project uses SwiftUI.", "scope": "project"])
            XCTAssertFalse(scoped.isError)
            let secret = await save(["subject": "OpenRouter", "content": "The api key is sk-abcdefghijklmnopqrstu"])
            XCTAssertTrue(secret.isError)
            let empty = await save(["subject": "", "content": "x"])
            XCTAssertTrue(empty.isError)
        }
        // A new conversation after AIM restarts: the memory is read back from disk and offered.
        let reopened = SQLiteMemoryRepository(database: try AIMDatabase(path: path))
        let items = try await reopened.list(status: nil)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first { $0.subjectKey == "Editor" }?.content, "Mathieu codes in Xcode now.")
        XCTAssertEqual(items.first { $0.subjectKey == "Stack" }?.scopeKey, project.uuidString)
        let context = try await reopened.contextCandidates("Bonjour", projectID: nil, includeGlobal: true)
        XCTAssertTrue(context.contains { $0.subjectKey == "Editor" }, "a preference is part of the profile")
        XCTAssertFalse(context.contains { $0.subjectKey == "Stack" }, "another project's memory stays there")
    }
}
