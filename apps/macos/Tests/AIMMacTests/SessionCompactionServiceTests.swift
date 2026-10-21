@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

private final class SummaryRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func reset() { lock.withLock { value = 0 } }
    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

private final class SummaryFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let counter = SummaryRequestCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.increment()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let empty = request.value(forHTTPHeaderField: "Authorization") == "Bearer empty"
        let body = empty ? "data: [DONE]\n\n" : "data: {\"choices\":[{\"delta\":{\"content\":\"Decisions: use SQLite.\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SessionCompactionServiceTests: XCTestCase {
    private func fixture() -> ProviderChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryFixtureProtocol.self]
        return ProviderChatService(session: URLSession(configuration: configuration))
    }

    func testCatalogContextLengthStartsCompactionBeforeLegacyThreshold() async throws {
        SummaryFixtureProtocol.counter.reset()
        let database = try AIMDatabase(inMemory: true)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let id = UUID()
        let conversations = SQLiteConversationRepository(database: database)
        try await conversations.save(Conversation(id: id, title: "Short context"))
        let history = (0..<12).map { index in
            ConversationMessage(conversationID: id, role: .user,
                                content: String(repeating: "x", count: 2_000), sequence: index)
        }
        for message in history { try await conversations.append(message) }
        let selected = try await SessionCompactionService(repository: checkpoints, chatService: fixture())
            .prepare(history, conversationID: id, provider: .openRouter,
                     modelID: "fixture", apiKey: "test", contextLength: 4_096)
        XCTAssertEqual(SummaryFixtureProtocol.counter.read(), 3)
        XCTAssertEqual(selected.dropFirst().map(\.id), Array(history.suffix(3)).map(\.id))
        let checkpoint = try await checkpoints.load(conversationID: id)
        XCTAssertEqual(checkpoint?.throughSequence, 8)
    }

    func testReservedRequestContextCompactsHistoryThatOtherwiseFits() async throws {
        SummaryFixtureProtocol.counter.reset()
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let id = UUID()
        try await conversations.save(Conversation(id: id, title: "Auxiliary context"))
        let history = (0..<9).map { index in
            ConversationMessage(conversationID: id, role: .user,
                                content: String(repeating: "x", count: 1_000), sequence: index)
        }
        for message in history { try await conversations.append(message) }
        let selected = try await SessionCompactionService(repository: checkpoints, chatService: fixture())
            .prepare(history, conversationID: id, provider: .openRouter,
                     modelID: "fixture", apiKey: "test", contextLength: 4_096,
                     reservedRequestBytes: 5_000)
        XCTAssertEqual(SummaryFixtureProtocol.counter.read(), 1)
        XCTAssertEqual(selected.dropFirst().map(\.id), Array(history.suffix(3)).map(\.id))
        let checkpoint = try await checkpoints.load(conversationID: id)
        XCTAssertEqual(checkpoint?.throughSequence, 5)
    }

    func testUncompactableFixedContextFailsBeforeProviderCall() async throws {
        SummaryFixtureProtocol.counter.reset()
        let database = try AIMDatabase(inMemory: true)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let id = UUID()
        let message = ConversationMessage(conversationID: id, role: .user, content: "Task", sequence: 0)
        do {
            _ = try await SessionCompactionService(repository: checkpoints, chatService: fixture())
                .prepare([message], conversationID: id, provider: .openRouter,
                         modelID: "fixture", apiKey: "test", contextLength: 4_096,
                         reservedRequestBytes: 100_000)
            XCTFail("Fixed context cannot be compacted")
        } catch SessionCompactionError.uncompactableContext { }
        XCTAssertEqual(SummaryFixtureProtocol.counter.read(), 0)
    }

    func testLongConversationSummarizesIncrementallyAndReusesCheckpoint() async throws {
        SummaryFixtureProtocol.counter.reset()
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let conversation = Conversation(title: "Long", provider: .openRouter, modelID: "fixture")
        try await conversations.save(conversation)
        let original = (0..<20).map { index in
            ConversationMessage(conversationID: conversation.id, role: index.isMultiple(of: 2) ? .user : .assistant,
                                content: "Turn \(index) " + String(repeating: "x", count: 20_000), sequence: index)
        }
        for message in original { try await conversations.append(message) }
        let service = SessionCompactionService(repository: checkpoints, chatService: fixture())
        let selected = try await service.prepare(original, conversationID: conversation.id,
                                                 provider: .openRouter, modelID: "fixture", apiKey: "test", contextLength: 50_000)
        let count = SummaryFixtureProtocol.counter.read()
        XCTAssertGreaterThan(count, 1)
        XCTAssertLessThan(count, 8)
        XCTAssertTrue(selected.first!.content.contains("Decisions: use SQLite"))
        XCTAssertEqual(selected.last?.id, original.last?.id)
        // A smaller window keeps a shorter verbatim tail (here the three newest turns).
        XCTAssertEqual(selected.suffix(3).map(\.id), original.suffix(3).map(\.id))
        let firstCheckpoint = try await checkpoints.load(conversationID: conversation.id)
        XCTAssertNotNil(firstCheckpoint)
        let selectedAgain = try await service.prepare(original, conversationID: conversation.id,
                                                      provider: .openRouter, modelID: "fixture", apiKey: "test", contextLength: 50_000)
        XCTAssertEqual(selectedAgain.map(\.content), selected.map(\.content))
        XCTAssertEqual(selectedAgain.dropFirst().map(\.id), selected.dropFirst().map(\.id))
        XCTAssertEqual(SummaryFixtureProtocol.counter.read(), count)
        let reloadedCheckpoint = try await checkpoints.load(conversationID: conversation.id)
        XCTAssertEqual(reloadedCheckpoint, firstCheckpoint)
        let retained = try await conversations.messages(conversationID: conversation.id)
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        XCTAssertEqual(retained.map(\.sequence), original.map(\.sequence))
    }

    func testEmptySummaryCannotAdvanceCheckpoint() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let conversation = Conversation(title: "Long", provider: .openRouter, modelID: "fixture")
        try await conversations.save(conversation)
        let original = (0..<14).map { index in
            ConversationMessage(conversationID: conversation.id, role: .user,
                                content: String(repeating: "x", count: 20_000), sequence: index)
        }
        let service = SessionCompactionService(repository: checkpoints, chatService: fixture())
        do {
            _ = try await service.prepare(original, conversationID: conversation.id,
                                          provider: .openRouter, modelID: "fixture", apiKey: "empty", contextLength: 50_000)
            XCTFail("An empty summary must not replace any context")
        } catch { XCTAssertTrue(error is ChatServiceError || error is SessionCompactionError) }
        let checkpoint = try await checkpoints.load(conversationID: conversation.id)
        XCTAssertNil(checkpoint)
    }
}

@MainActor
final class SessionCompactionNavigationTests: XCTestCase {
    func testSavedSummaryNoticeLoadsWithoutHidingTranscript() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let checkpoints = SQLiteSessionCompactionRepository(database: database)
        let conversation = Conversation(title: "Saved")
        let old = ConversationMessage(conversationID: conversation.id, role: .user, content: "Original text", sequence: 0)
        try await conversations.save(conversation)
        try await conversations.append(old)
        try await checkpoints.save(SessionCompaction(conversationID: conversation.id,
                                                     throughMessageID: old.id, throughSequence: 0,
                                                     summary: "Original context"))
        let model = AppModel(database: database)
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.messages.map(\.content), ["Original text"])
        XCTAssertEqual(model.compactedThroughSequence, 0)
        await model.selectConversation(nil)
        XCTAssertNil(model.compactedThroughSequence)
    }
}
