@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

@MainActor
final class ChatRegenerationTests: XCTestCase {
    func testRegenerationBranchesWithoutRepeatingUserMessageOrChangingOriginal() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Original", mode: .chat, provider: .openAI, modelID: "fixture")
        try await repository.save(source)
        let first = ConversationMessage(conversationID: source.id, role: .user, content: "First question", sequence: 0)
        let answer = ConversationMessage(conversationID: source.id, role: .assistant, content: "Old answer", sequence: 1)
        let later = ConversationMessage(conversationID: source.id, role: .user, content: "Later question", sequence: 2)
        for message in [first, answer, later] { try await repository.append(message) }
        let recorder = RegenerationRecorder()
        let captured = expectation(description: "new branch request")
        let model = AppModel(database: database, turnRunner: RegenerationRunner { request in
            recorder.record(request)
            captured.fulfill()
        })
        model.connectedProviders = [.openAI]
        await model.selectConversation(source.id)
        await model.regenerateChatResponse(after: answer)
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.requests.first)
        let branchID = try XCTUnwrap(model.selectedConversationID)
        XCTAssertNotEqual(branchID, source.id)
        XCTAssertEqual(request.conversationID, branchID)
        XCTAssertEqual(request.mode, .chat)
        XCTAssertEqual(request.provider, .openAI)
        XCTAssertEqual(request.modelID, "fixture")
        XCTAssertEqual(request.text, "First question")
        let initialBranch = try await repository.messages(conversationID: branchID)
        let initialSource = try await repository.messages(conversationID: source.id)
        XCTAssertEqual(initialBranch.map(\.content), ["First question"])
        XCTAssertEqual(initialSource.map(\.content), ["First question", "Old answer", "Later question"])
        await model.handle(.textDelta(conversationID: branchID, text: "New answer"))
        await model.handle(.completed(conversationID: branchID))
        let finalBranch = try await repository.messages(conversationID: branchID)
        let finalSource = try await repository.messages(conversationID: source.id)
        XCTAssertEqual(finalBranch.map(\.content), ["First question", "New answer"])
        XCTAssertEqual(finalSource.map(\.content), ["First question", "Old answer", "Later question"])
        _ = await model.prepareForTermination()
    }

    func testAttachmentOnlyPromptIsCopiedAndRequestTextStaysEmpty() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Image", mode: .chat, provider: .anthropic, modelID: "fixture")
        try await repository.save(source)
        let prompt = ConversationMessage(conversationID: source.id, role: .user, content: "", sequence: 0,
                                         attachments: [TextAttachment(name: "notes.txt", content: "Context")])
        let answer = ConversationMessage(conversationID: source.id, role: .assistant, content: "Old answer", sequence: 1)
        try await repository.append(prompt)
        try await repository.append(answer)
        let recorder = RegenerationRecorder()
        let captured = expectation(description: "attachment request")
        let model = AppModel(database: database, turnRunner: RegenerationRunner { request in
            recorder.record(request)
            captured.fulfill()
        })
        model.connectedProviders = [.anthropic]
        await model.selectConversation(source.id)
        await model.regenerateChatResponse(after: answer)
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.text, "")
        let branchID = try XCTUnwrap(model.selectedConversationID)
        let copied = try await repository.messages(conversationID: branchID)
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied[0].attachments?.first?.content, "Context")
        await model.handle(.completed(conversationID: branchID))
        _ = await model.prepareForTermination()
    }

    func testDraftMissingKeyAndCodeModeDoNotRegenerate() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Original", mode: .chat, provider: .openAI, modelID: "fixture")
        try await repository.save(source)
        let prompt = ConversationMessage(conversationID: source.id, role: .user, content: "Prompt", sequence: 0)
        let answer = ConversationMessage(conversationID: source.id, role: .assistant, content: "Answer", sequence: 1)
        try await repository.append(prompt)
        try await repository.append(answer)
        let recorder = RegenerationRecorder()
        let model = AppModel(database: database, turnRunner: RegenerationRunner { recorder.record($0) })
        await model.selectConversation(source.id)
        XCTAssertFalse(model.canRegenerateChatResponse)
        await model.regenerateChatResponse(after: answer)
        model.connectedProviders = [.openAI]
        model.composerText = "Keep this draft"
        XCTAssertFalse(model.canRegenerateChatResponse)
        await model.regenerateChatResponse(after: answer)
        XCTAssertEqual(model.composerText, "Keep this draft")
        let stored = try await repository.list(includeArchived: true)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(recorder.requests.isEmpty)
        model.composerText = ""
        let code = Conversation(title: "Code", mode: .code, provider: .openAI, modelID: "fixture")
        try await repository.save(code)
        let codePrompt = ConversationMessage(conversationID: code.id, role: .user, content: "Run this", sequence: 0)
        let codeAnswer = ConversationMessage(conversationID: code.id, role: .assistant, content: "Done", sequence: 1)
        try await repository.append(codePrompt)
        try await repository.append(codeAnswer)
        await model.selectConversation(code.id)
        XCTAssertFalse(model.canRegenerateChatResponse)
        await model.regenerateChatResponse(after: codeAnswer)
        XCTAssertEqual(model.selectedConversationID, code.id)
        XCTAssertTrue(recorder.requests.isEmpty)
        _ = await model.prepareForTermination()
    }

    func testRegenerationCanUseNewlySelectedBYOKProviderAndModel() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Original", mode: .chat, provider: .openAI, modelID: "original")
        try await repository.save(source)
        let prompt = ConversationMessage(conversationID: source.id, role: .user, content: "Prompt", sequence: 0)
        let answer = ConversationMessage(conversationID: source.id, role: .assistant, content: "Answer", sequence: 1)
        try await repository.append(prompt)
        try await repository.append(answer)
        let recorder = RegenerationRecorder()
        let captured = expectation(description: "new provider request")
        let model = AppModel(database: database, turnRunner: RegenerationRunner { request in
            recorder.record(request)
            captured.fulfill()
        })
        model.connectedProviders = [.openAI, .anthropic]
        await model.selectConversation(source.id)
        model.selectProvider(.anthropic)
        model.selectModel("replacement")
        await model.regenerateChatResponse(after: answer)
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.requests.first)
        let branchID = try XCTUnwrap(model.selectedConversationID)
        XCTAssertEqual(request.provider, .anthropic)
        XCTAssertEqual(request.modelID, "replacement")
        let branch = try await repository.conversation(id: branchID)
        XCTAssertEqual(branch?.provider, .anthropic)
        XCTAssertEqual(branch?.modelID, "replacement")
        let unchanged = try await repository.conversation(id: source.id)
        XCTAssertEqual(unchanged?.provider, .openAI)
        XCTAssertEqual(unchanged?.modelID, "original")
        await model.handle(.completed(conversationID: branchID))
        _ = await model.prepareForTermination()
    }
}

private struct RegenerationRunner: NativeAgentTurnRunning {
    let capture: @Sendable (AgentRequest) -> Void
    func cancel(conversationID: UUID) async {}
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        capture(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class RegenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentRequest] = []
    var requests: [AgentRequest] { lock.withLock { storage } }
    func record(_ request: AgentRequest) { lock.withLock { storage.append(request) } }
}
