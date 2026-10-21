import AIMApplication
import XCTest

final class SubagentJobPersistenceTests: XCTestCase {
    func testCompletedResultsSurviveReopenAndInterruptedChildrenAreNotReportedDone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("children.sqlite").path
        let db = try AIMDatabase(path: path)
        let chat = Conversation(title: "Children", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let jobs = SQLiteSubagentJobRepository(database: db)
        let completed = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
                                          title: "Completed", prompt: "Inspect file")
        let interrupted = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
                                            title: "Interrupted", prompt: "Inspect branch")
        let queued = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
                                       title: "Queued", prompt: "Inspect tests")
        for job in [completed, interrupted, queued] { try await jobs.enqueue(job) }
        try await jobs.markRunning(id: completed.id)
        try await jobs.finish(id: completed.id, state: .done, result: "Verified finding")
        try await jobs.markRunning(id: interrupted.id)
        let recovered = SQLiteSubagentJobRepository(database: try AIMDatabase(path: path))
        let recoveredCount = try await recovered.recoverInterrupted()
        XCTAssertEqual(recoveredCount, 2)
        let page = try await recovered.list(conversationID: chat.id, workspacePath: "/fixture",
                                            offset: 0, limit: 20)
        XCTAssertEqual(page.totalJobs, 3)
        XCTAssertEqual(page.activeJobs, 0)
        XCTAssertEqual(page.jobs.first(where: { $0.id == completed.id })?.result, "Verified finding")
        XCTAssertEqual(page.jobs.first(where: { $0.id == interrupted.id })?.state, .interrupted)
        XCTAssertEqual(page.jobs.first(where: { $0.id == queued.id })?.state, .interrupted)
        let retry = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
            title: interrupted.title, prompt: interrupted.prompt, retryOf: interrupted.id)
        try await recovered.enqueue(retry)
        do {
            try await recovered.enqueue(SubagentJobRecord(conversationID: chat.id,
                workspacePath: "/fixture", title: interrupted.title,
                prompt: interrupted.prompt, retryOf: interrupted.id))
            XCTFail("A second retry of the same uncertain attempt must not start")
        } catch {}
        do {
            try await recovered.enqueue(SubagentJobRecord(conversationID: chat.id,
                workspacePath: "/fixture", title: completed.title,
                prompt: completed.prompt, retryOf: completed.id))
            XCTFail("A completed child must not be retried as interrupted")
        } catch {}
        do {
            try await recovered.finish(id: interrupted.id, state: .done, result: "Late success")
            XCTFail("An interrupted child must not be promoted by a late result")
        } catch {}
        try await SQLiteConversationRepository(database: db).delete(id: chat.id)
        let deleted = try await recovered.list(conversationID: chat.id, workspacePath: "/fixture",
                                               offset: 0, limit: 20)
        XCTAssertTrue(deleted.jobs.isEmpty)
    }

    func testCancelledChildRejectsLateSuccess() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Cancel", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let jobs = SQLiteSubagentJobRepository(database: db)
        let child = SubagentJobRecord(conversationID: chat.id, workspacePath: "/fixture",
                                      title: "Cancel me", prompt: "Inspect")
        try await jobs.enqueue(child)
        try await jobs.markRunning(id: child.id)
        try await jobs.cancel(id: child.id)
        do {
            try await jobs.finish(id: child.id, state: .done, result: "Late result")
            XCTFail("Cancellation must win over a late model result")
        } catch {}
        let page = try await jobs.list(conversationID: chat.id, workspacePath: "/fixture",
                                       offset: 0, limit: 20)
        XCTAssertEqual(page.jobs.first?.state, .cancelled)
    }
}
