@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMCore
import Foundation
import XCTest

@MainActor
final class ProviderKeyAccessTests: XCTestCase {
    func testLocalHistoryLoadsBeforeKeychainAuthorizationCompletes() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Local history fixture")
        try await SQLiteConversationRepository(database: database).save(conversation)
        try await SQLiteConversationRepository(database: database).append(ConversationMessage(
            conversationID: conversation.id, role: .user, content: "fixture", sequence: 0))
        let store = BlockingReadStore()
        let model = AppModel(database: database, providerStore: store)
        let startup = Task { await model.start() }
        defer { store.release() }
        for _ in 0..<200 {
            if store.hasStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.hasStarted)
        XCTAssertEqual(model.conversations.first?.id, conversation.id)
        store.release()
        await startup.value
        _ = await model.prepareForTermination()
    }

    func testStartupKeychainReadsDoNotBlockMainThread() async throws {
        let store = ThreadRecordingStore()
        let model = AppModel(database: try AIMDatabase(inMemory: true), providerStore: store)
        await model.start()
        let reads = store.readThreads
        XCTAssertEqual(reads.count, ChatProvider.allCases.count)
        XCTAssertTrue(reads.allSatisfy { !$0 }, "Keychain may wait for a dialog; never block the UI thread")
        _ = await model.prepareForTermination()
    }
}

private final class ThreadRecordingStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var readThreads: [Bool] { lock.withLock { recorded } }
    func store(_ data: Data, forKey key: String) throws {}
    func removeData(forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? {
        lock.withLock { recorded.append(Thread.isMainThread) }
        return nil
    }
}

private final class BlockingReadStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func release() { gate.signal() }
    func store(_ data: Data, forKey key: String) throws {}
    func removeData(forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? {
        let first = lock.withLock { let first = !started; started = true; return first }
        if first { gate.wait() }
        return nil
    }
}
