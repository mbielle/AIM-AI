@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMAgentKit
import AIMCore
import XCTest

@MainActor
final class LocalModeTests: XCTestCase {
    func testChatCodeAndAgentDispatchWithoutAccountOrBackend() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for mode in [AIMMode.chat, .code, .agent] {
            let received = expectation(description: "local \(mode.rawValue) request")
            let runner = LocalModeRunner { request in
                XCTAssertEqual(request.mode, mode)
                received.fulfill()
            }
            let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: runner)
            XCTAssertTrue(model.account.identity?.isLocal == true)
            XCTAssertNil(model.account.accessUser)
            XCTAssertNil(model.account.supabaseClient)
            model.selectMode(mode)
            model.workspacePath = mode == .code ? folder.path : nil
            model.connectedProviders = [.openRouter]
            model.selectedProvider = .openRouter
            model.selectedModelID = "fixture-local-access"
            model.composerText = "Local test request"
            await model.sendComposer()
            await fulfillment(of: [received], timeout: 2)
            let conversationID = try XCTUnwrap(model.selectedConversationID)
            let messages = try await model.conversationRepository.messages(conversationID: conversationID)
            XCTAssertEqual(messages.first?.content, "Local test request")
            await model.handle(.completed(conversationID: conversationID))
            _ = await model.prepareForTermination()
        }
    }

    func testLocalVisualDelegationStillRequiresExplicitConsentWithoutAnAccountGate() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: LocalModeRunner { _ in XCTFail("Consent must be collected before dispatch") })
        model.connectedProviders = [.openRouter]
        model.selectedProvider = .openRouter
        model.selectedModelID = "fixture-without-vision"
        model.composerText = "Describe this image"
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jM1kAAAAASUVORK5CYII=")!
        model.pendingImages = [try ImageAttachment(name: "fixture.png", mimeType: "image/png", data: pixel)]
        await model.sendComposer()
        let pending = try XCTUnwrap(model.pendingVisualApproval)
        XCTAssertEqual(pending.ownerID, model.account.identity?.storageID)
        XCTAssertNil(model.account.accessUser)
        XCTAssertEqual(model.composerText, "Describe this image")
        model.refuseVisualInput(pending.id)
        XCTAssertNil(model.pendingVisualApproval)
        XCTAssertEqual(model.pendingImages.count, 1)
        _ = await model.prepareForTermination()
    }

    func testLocalProfileWithoutPersistentIdentityCannotDispatch() async throws {
        let account = MacAccountController(service: nil, localProfileStore: UnavailableProfileStore())
        let model = AppModel(database: try AIMDatabase(inMemory: true), account: account)
        XCTAssertNil(account.identity)
        XCTAssertFalse(model.hasAccess)
        let allowed = await model.authorizesComposerDispatch(owner: nil, expectedMode: .chat)
        XCTAssertFalse(allowed)
    }

    func testEditingTheDraftInvalidatesItsPreviousVisualApprovalBeforeCatalogOrKeyAccess() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database, turnRunner: LocalModeRunner { _ in XCTFail("A changed draft must not dispatch") })
        model.connectedProviders = [.openRouter]
        model.selectedProvider = .openRouter
        model.selectedModelID = "fixture-without-vision"
        model.composerText = "Original draft"
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jM1kAAAAASUVORK5CYII=")!
        model.pendingImages = [try ImageAttachment(name: "fixture.png", mimeType: "image/png", data: pixel)]
        await model.sendComposer()
        let pending = try XCTUnwrap(model.pendingVisualApproval)
        model.composerText = "Changed draft"
        // This choice cannot resolve to a real model: stale admission must
        // return before any local catalog, credentials or provider is touched.
        let sent = await model.analyseVisualInput(pending, choice: .init(provider: .local, modelID: "fixture-not-installed"), remember: true)
        XCTAssertFalse(sent)
        XCTAssertFalse(model.isAnalysingVisualInput)
        XCTAssertNil(model.visualDraftReport)
        XCTAssertEqual(model.composerText, "Changed draft")
        XCTAssertEqual(model.pendingImages.count, 1)
        XCTAssertTrue(model.alertMessage?.contains("draft") == true)
        XCTAssertTrue(model.flushComposer())
        let saved = try ComposerDraftStore(database: database).load(key: pending.ownerID.uuidString + ":" + pending.scope)
        XCTAssertEqual(saved.text, "Changed draft")
        XCTAssertNil(saved.visualApproval, "A stale approval must not be rebound to edited media after restoring the draft")
        _ = await model.prepareForTermination()
    }
}

private struct LocalModeRunner: NativeAgentTurnRunning {
    let observe: @Sendable (AgentRequest) -> Void
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        observe(request)
        return AsyncThrowingStream { $0.finish() }
    }
    func cancel(conversationID: UUID) async {}
}

private struct UnavailableProfileStore: SecureStoring {
    func readData(forKey key: String) throws -> Data? { throw URLError(.cannotOpenFile) }
    func store(_ data: Data, forKey key: String) throws { throw URLError(.cannotWriteToFile) }
    func removeData(forKey key: String) throws {}
}
