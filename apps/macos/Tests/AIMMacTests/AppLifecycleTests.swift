@testable import AIMAgentRuntime
@testable import AIMMac
@testable import AIMMacPlatform
import AIMApplication
import AppKit
import XCTest

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testReopenRoutesToExistingSceneActionOnlyWhenNoWindowsAreVisible() {
        let delegate = AppLifecycleDelegate(supervisor: ProcessSupervisor())
        XCTAssertTrue(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        var openings = 0
        delegate.reopenMainWindow = { openings += 1 }
        XCTAssertTrue(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: true))
        XCTAssertEqual(openings, 0)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertEqual(openings, 1)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testReopenDoesNotCreateWindowDuringTermination() async {
        let supervisor = ProcessSupervisor()
        let delegate = AppLifecycleDelegate(supervisor: supervisor)
        var openings = 0
        delegate.reopenMainWindow = { openings += 1 }
        let replied = expectation(description: "Termination reply")
        delegate.reply = { _, _ in replied.fulfill() }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertEqual(openings, 0)
        await fulfillment(of: [replied], timeout: 2)
    }

    func testQuitWaitsForPreparationAndProcessCleanup() async throws {
        let supervisor = ProcessSupervisor()
        let delegate = AppLifecycleDelegate(supervisor: supervisor)
        let lease = UUID()
        try supervisor.register(id: lease) { }
        let prepared = expectation(description: "Preparation called")
        let replied = expectation(description: "Reply after cleanup")
        var replies: [Bool] = []
        delegate.prepare = { prepared.fulfill(); return true }
        delegate.reply = { _, success in replies.append(success); replied.fulfill() }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(supervisor.isShuttingDown)
        await fulfillment(of: [prepared], timeout: 2)
        XCTAssertTrue(replies.isEmpty)
        supervisor.finish(id: lease)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testFailedSaveCancelsQuitAndReopensAdmission() async {
        let supervisor = ProcessSupervisor()
        let delegate = AppLifecycleDelegate(supervisor: supervisor)
        let replied = expectation(description: "Quit cancelled")
        delegate.prepare = { false }
        delegate.reply = { _, success in XCTAssertFalse(success); replied.fulfill() }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertFalse(supervisor.isShuttingDown)
        let retry = expectation(description: "Quit retry")
        delegate.prepare = { true }
        delegate.reply = { _, success in XCTAssertTrue(success); retry.fulfill() }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        await fulfillment(of: [retry], timeout: 2)
    }

    func testModelRefusesComposerDuringShutdown() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let ready = await model.prepareForTermination()
        XCTAssertTrue(ready)
        model.composerText = "must remain unsent"
        await model.sendComposer()
        XCTAssertEqual(model.composerText, "must remain unsent")
        XCTAssertFalse(model.showProviderSetup)
        XCTAssertTrue(model.isShuttingDown)
    }

    func testQuitWaitsForSubmittedMessagePersistenceWithoutStartingProvider() async throws {
        let repository = PausedSaveRepository()
        let model = AppModel(database: try AIMDatabase(inMemory: true), conversationRepository: repository)
        model.selectedProvider = .anthropic
        model.connectedProviders = [.anthropic]
        model.selectedModelID = "offline-test"
        model.composerText = "Keep this submitted message"
        let send = Task { await model.sendComposer() }
        await repository.waitForSave()
        let shutdown = Task { await model.prepareForTermination() }
        while !model.isShuttingDown { await Task.yield() }
        XCTAssertTrue(model.isSending)
        await repository.releaseSave()
        await send.value
        let result = await shutdown.value
        XCTAssertTrue(result)
        let saved = await repository.messages(conversationID: UUID())
        XCTAssertEqual(saved.map(\.content), ["Keep this submitted message"])
        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.alertMessage)
    }
}

private actor PausedSaveRepository: ConversationRepository {
    private var saving = false
    private var began: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var rows: [ConversationMessage] = []
    func waitForSave() async {
        if saving { return }
        await withCheckedContinuation { began = $0 }
    }
    func releaseSave() { release?.resume(); release = nil }
    func save(_ conversation: Conversation) async {
        await withCheckedContinuation {
            release = $0; saving = true; began?.resume(); began = nil
        }
    }
    func list(includeArchived: Bool) -> [Conversation] { [] }
    func conversation(id: UUID) -> Conversation? { nil }
    func delete(id: UUID) { }
    func append(_ message: ConversationMessage) { rows.append(message) }
    func messages(conversationID: UUID) -> [ConversationMessage] { rows }
    func search(_ query: String, limit: Int) -> [Conversation] { [] }
}
