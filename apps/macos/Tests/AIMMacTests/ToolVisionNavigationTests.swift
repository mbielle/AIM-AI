@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

@MainActor
final class ToolVisionNavigationTests: XCTestCase {
    func testOpenRouterTextToolProtocolIsExplicitAndResetsWithWorkspaceAccess() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Text tool request captured")
        let recorder = VisionRequestRecorder()
        let model = AppModel(database: database, turnRunner: VisionRequestRunner { request in
            recorder.set(request)
            captured.fulfill()
        })
        model.selectMode(.code)
        model.connectedProviders = [.openRouter]
        model.selectedProvider = .openRouter
        model.selectedModelID = "text-only-fixture"
        model.workspacePath = FileManager.default.temporaryDirectory.path
        model.workspaceToolsEnabled = true
        model.workspaceTextToolProtocol = true
        model.composerText = "Inspect README"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertEqual(recorder.get()?.workspaceToolsEnabled, true)
        XCTAssertEqual(recorder.get()?.workspaceTextToolProtocol, true)
        model.workspaceToolsEnabled = false
        XCTAssertFalse(model.workspaceTextToolProtocol)
        _ = await model.prepareForTermination()
    }

    func testCodeComposerCanSubmitImageWithWorkspaceToolsEnabled() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Workspace turn captured")
        let recorder = VisionRequestRecorder()
        let model = AppModel(database: database, turnRunner: VisionRequestRunner { request in
            recorder.set(request)
            captured.fulfill()
        })
        model.selectMode(.code)
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "vision-fixture"
        model.availableModels = [ChatModel(id: "vision-fixture", name: "Vision fixture", inputModalities: ["text", "image"])]
        model.workspacePath = FileManager.default.temporaryDirectory.path
        model.workspaceToolsEnabled = true
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        model.pendingImages = [try ImageAttachment(name: "pixel.png", mimeType: "image/png", data: png)]
        model.composerText = "Inspect this and the project"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.get())
        XCTAssertEqual(request.mode, .code)
        XCTAssertEqual(request.workspaceToolsEnabled, true)
        let messages = try await SQLiteConversationRepository(database: database).messages(conversationID: request.conversationID)
        XCTAssertEqual(messages.first?.images?.first?.data, png)
        XCTAssertTrue(model.pendingImages.isEmpty)
        _ = await model.prepareForTermination()
    }

    func testImageOnlyDraftCanStartConversationWithoutFabricatedPrompt() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Image-only turn captured")
        let recorder = VisionRequestRecorder()
        let model = AppModel(database: database, turnRunner: VisionRequestRunner { request in
            recorder.set(request)
            captured.fulfill()
        })
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "vision-fixture"
        model.availableModels = [ChatModel(id: "vision-fixture", name: "Vision fixture", inputModalities: ["text", "image"])]
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        model.pendingImages = [try ImageAttachment(name: "pixel.png", mimeType: "image/png", data: png)]
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.get())
        XCTAssertEqual(request.text, "")
        let conversation = try await SQLiteConversationRepository(database: database).conversation(id: request.conversationID)
        XCTAssertEqual(conversation?.title, "pixel.png")
        let messages = try await SQLiteConversationRepository(database: database).messages(conversationID: request.conversationID)
        XCTAssertEqual(messages.first?.content, "")
        XCTAssertEqual(messages.first?.images?.first?.data, png)
        XCTAssertTrue(model.pendingImages.isEmpty)
        _ = await model.prepareForTermination()
    }

    func testUnknownVisionCapabilityKeepsDraftWithoutSilentModelSwitch() async throws {
        let recorder = VisionRequestRecorder()
        let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: VisionRequestRunner {
            recorder.set($0)
        })
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "unknown-vision-fixture"
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let image = try ImageAttachment(name: "pixel.png", mimeType: "image/png", data: png)
        model.pendingImages = [image]
        await model.sendComposer()
        XCTAssertNil(recorder.get())
        XCTAssertEqual(model.pendingImages, [image])
        XCTAssertEqual(model.selectedModelID, "unknown-vision-fixture")
        let approval = try XCTUnwrap(model.pendingVisualApproval, "Unknown image capability must request explicit visual delegation")
        XCTAssertEqual(approval.primaryProvider, .openAI)
        XCTAssertEqual(approval.primaryModel, "unknown-vision-fixture")
        XCTAssertEqual(approval.ownerID, model.account.identity?.storageID)
        XCTAssertEqual(approval.sources.map(\.id), [image.id])
        XCTAssertFalse(model.isAnalysingVisualInput)
        model.refuseVisualInput(approval.id)
        XCTAssertNil(model.pendingVisualApproval)
        XCTAssertEqual(model.pendingImages, [image])
        _ = await model.prepareForTermination()
    }

    func testTextAttachmentOnlyDraftCanStartConversation() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "File-only turn captured")
        let recorder = VisionRequestRecorder()
        let model = AppModel(database: database, turnRunner: VisionRequestRunner { request in
            recorder.set(request)
            captured.fulfill()
        })
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "text-fixture"
        model.pendingAttachments = [TextAttachment(name: "notes.txt", content: "Reference material")]
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        let request = try XCTUnwrap(recorder.get())
        XCTAssertEqual(request.text, "")
        let repository = SQLiteConversationRepository(database: database)
        let conversation = try await repository.conversation(id: request.conversationID)
        XCTAssertEqual(conversation?.title, "notes.txt")
        let messages = try await repository.messages(conversationID: request.conversationID)
        XCTAssertEqual(messages.first?.content, "")
        XCTAssertEqual(messages.first?.attachments?.first?.content, "Reference material")
        let expanded = try AttachmentContext.expand(messages)
        XCTAssertTrue(expanded.first?.content.contains("Reference material") == true)
        _ = await model.prepareForTermination()
    }
}

private struct VisionRequestRunner: NativeAgentTurnRunning {
    let capture: @Sendable (AgentRequest) -> Void
    func cancel(conversationID: UUID) async { }
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        capture(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class VisionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: AgentRequest?
    func set(_ value: AgentRequest) { lock.withLock { request = value } }
    func get() -> AgentRequest? { lock.withLock { request } }
}
