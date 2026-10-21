import AIMCore
import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import AIM

private final class AccountStoreTestSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { nil }
    func removeData(forKey key: String) throws {}
}

private final class CatalogStoreTestSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { Data("fixture-provider-key".utf8) }
    func removeData(forKey key: String) throws {}
}

private final class CatalogHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var failingReference = false
    private var holdingReference = false
    func reset(failReference: Bool = false, holdReference: Bool = false) { lock.lock(); recorded = []; failingReference = failReference; holdingReference = holdReference; lock.unlock() }
    func record(_ request: URLRequest) -> (fail: Bool, hold: Bool) { lock.lock(); defer { lock.unlock() }; recorded.append(request); return (failingReference, holdingReference) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// Every URL is intercepted. Catalog validation performs only fixture GETs;
/// the optional response fixture also prevents a paid request in budget tests.
private final class CatalogHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = CatalogHTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let referenceMode = Self.fixture.record(request)
        let url = request.url!, isReference = url.host == "openrouter.ai"
        if isReference && referenceMode.hold { return }
        let status = isReference && referenceMode.fail ? 503 : 200
        let payload: String
        if request.httpMethod == "POST" {
            payload = #"data: {"type":"response.output_text.delta","delta":"Fixture answer"}"# + "\n\n" +
                #"data: {"type":"response.completed","response":{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Fixture answer"}]}],"usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n\n"
        } else if isReference {
            payload = #"{"data":[{"id":"anthropic/claude-sonnet-4.6","name":"Reference Claude","description":"Public catalog description","context_length":1000000,"max_tokens":64000,"created":1704067200,"pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003"},"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["tools","reasoning"]},{"id":"openai/gpt-4.1","name":"Reference GPT","description":"Public GPT description","context_length":1000000,"max_tokens":64000,"pricing":{"prompt":"0.000002","completion":"0.000008"}}]}"#
        } else if url.host == "api.anthropic.com" {
            payload = #"{"data":[{"id":"claude-sonnet-4-6","display_name":"Direct Claude","context_length":200000,"max_tokens":32000}],"has_more":false}"#
        } else {
            payload = #"{"data":[{"id":"gpt-4.1","display_name":"Direct GPT","context_length":200000,"max_tokens":32000}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": request.httpMethod == "POST" ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AudioSessionOrderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var count = 0
    let entered = XCTestExpectation(description: "First audio activation entered")
    let release = DispatchSemaphore(value: 0)
    func activate(preview: Bool) {
        lock.lock(); count += 1; let first = count == 1
        recorded.append(preview ? "activate-preview" : "activate-conversation"); lock.unlock()
        if first { entered.fulfill(); release.wait() }
    }
    func deactivate() { lock.lock(); recorded.append("deactivate"); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// Returns a captured server read only after an overlapping save has completed.
private actor DelayedMemoryReadService: AccountContentSyncing {
    private let accountID: UUID
    private let captured: AccountDocument
    private var reads = 0
    private var waitingRead: CheckedContinuation<[AccountDocument], Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var readStarted = false
    init(accountID: UUID, captured: AccountMemorySnapshot) throws {
        self.accountID = accountID
        self.captured = AccountDocument(id: AccountMemoryService.documentID, kind: "memory",
            payload: String(decoding: try JSONEncoder().encode(captured), as: UTF8.self), revision: captured.revision ?? 0)
    }
    func documents(accountID: UUID) async throws -> [AccountDocument] {
        guard accountID == self.accountID else { throw AccountServiceError.conflict }
        reads += 1
        if reads == 1 { return [captured] } // Activity's independent document read.
        return await withCheckedContinuation { continuation in
            waitingRead = continuation; readStarted = true
            readWaiters.forEach { $0.resume() }; readWaiters.removeAll()
        }
    }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard accountID == self.accountID, document.id == AccountMemoryService.documentID,
              document.revision == captured.revision else { throw AccountServiceError.conflict }
        var saved = document; saved.revision += 1; return saved
    }
    func waitUntilMemoryRead() async {
        if readStarted { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func finishCapturedRead() { waitingRead?.resume(returning: [captured]); waitingRead = nil }
}

@MainActor final class NativeChatStoreAccountTests: XCTestCase {
    func testProviderCatalogUsesPublicMetadataWithoutChangingSelectionOrNativeCapacity() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        CatalogHTTPProtocol.fixture.reset()
        let store = catalogStore(accountID)
        store.provider = .openAI; store.modelID = "keep-selected-model"
        let selectedID = UUID(); store.selectedID = selectedID
        let catalog = try await store.catalog(for: .anthropic)
        let model = try XCTUnwrap(catalog.first)
        XCTAssertEqual(model.id, "claude-sonnet-4-6"); XCTAssertEqual(model.name, "Direct Claude")
        XCTAssertEqual(model.contextLength, 200_000); XCTAssertEqual(model.maxOutputTokens, 32_000)
        XCTAssertEqual(model.summary, "Public catalog description")
        XCTAssertEqual(model.pricing?.inputPerMillion, 3); XCTAssertEqual(model.pricing?.outputPerMillion, 15)
        XCTAssertTrue(store.modelPricingIsReference(provider: .anthropic, modelID: model.id))
        XCTAssertEqual(model.architecture?.outputModalities, ["text"])
        XCTAssertEqual(model.supportedParameters, ["tools", "reasoning"])
        XCTAssertEqual(store.catalogModels[.anthropic], catalog)
        XCTAssertEqual(store.provider, .openAI); XCTAssertEqual(store.modelID, "keep-selected-model"); XCTAssertEqual(store.selectedID, selectedID)
        let publicRequests = CatalogHTTPProtocol.fixture.requests.filter { $0.url?.host == "openrouter.ai" }
        XCTAssertEqual(publicRequests.count, 1); XCTAssertNil(publicRequests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(CatalogHTTPProtocol.fixture.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }

    func testLoadingAndSavingProviderKeyShareCachedPublicMetadata() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        CatalogHTTPProtocol.fixture.reset()
        let store = catalogStore(accountID)
        store.provider = .anthropic; store.modelID = "claude-sonnet-4-6"
        await store.loadModels()
        XCTAssertEqual(store.models.first?.summary, "Public catalog description")
        XCTAssertEqual(store.modelID, "claude-sonnet-4-6")
        store.provider = .openAI; store.modelID = "keep-selected-model"
        let saved = await store.saveKey("new-fixture-key", provider: .anthropic)
        XCTAssertTrue(saved); XCTAssertEqual(store.catalogModels[.anthropic]?.first?.pricing?.inputPerMillion, 3)
        XCTAssertEqual(store.provider, .openAI); XCTAssertEqual(store.modelID, "keep-selected-model")
        _ = try await store.catalog(for: .openAI)
        XCTAssertEqual(CatalogHTTPProtocol.fixture.requests.filter { $0.url?.host == "openrouter.ai" }.count, 1)
        XCTAssertTrue(CatalogHTTPProtocol.fixture.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }

    func testUnavailablePublicMetadataKeepsDirectCatalogUsableAndDoesNotRepeatFailedLookup() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        CatalogHTTPProtocol.fixture.reset(failReference: true)
        let store = catalogStore(accountID)
        let first = try await store.catalog(for: .anthropic)
        let second = try await store.catalog(for: .openAI)
        XCTAssertEqual(first.first?.name, "Direct Claude"); XCTAssertEqual(second.first?.name, "Direct GPT")
        XCTAssertNil(first.first?.summary); XCTAssertNil(first.first?.pricing); XCTAssertNil(store.errorMessage)
        XCTAssertEqual(CatalogHTTPProtocol.fixture.requests.filter { $0.url?.host == "openrouter.ai" }.count, 1)
    }

    func testSlowPublicMetadataHasItsOwnDeadlineAndKeepsDirectCatalogUsable() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        CatalogHTTPProtocol.fixture.reset(holdReference: true)
        let store = catalogStore(accountID, publicCatalogTimeout: .milliseconds(20))
        let started = ContinuousClock.now
        let catalog = try await store.catalog(for: .anthropic)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(catalog.first?.id, "claude-sonnet-4-6"); XCTAssertNil(catalog.first?.summary)
        XCTAssertNil(store.errorMessage)
    }

    func testPublicReferencePriceCannotAdmitDirectProviderBudgetOrBecomeItsRecordedCost() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let priorBudget = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        let priorLimit = UserDefaults.standard.object(forKey: "aim.budget.limit")
        let priorOutput = UserDefaults.standard.object(forKey: "aim.chat.output-tokens")
        defer {
            UserDefaults.standard.set(priorBudget, forKey: "aim.budget.enabled")
            UserDefaults.standard.set(priorLimit, forKey: "aim.budget.limit")
            UserDefaults.standard.set(priorOutput, forKey: "aim.chat.output-tokens")
        }
        UserDefaults.standard.set(true, forKey: "aim.budget.enabled"); UserDefaults.standard.set(100, forKey: "aim.budget.limit")
        UserDefaults.standard.removeObject(forKey: "aim.chat.output-tokens"); CatalogHTTPProtocol.fixture.reset()
        let store = catalogStore(accountID); store.provider = .openAI; store.modelID = "gpt-4.1"
        store.preferences.automaticWebSearch = false; store.memory.enabled = false
        await store.loadModels()
        XCTAssertEqual(store.models.first?.pricing?.inputPerMillion, 2, "A reference price is useful in the details page")
        let blocked = await store.send("Fixture budget request")
        XCTAssertFalse(blocked); XCTAssertTrue(store.errorMessage?.contains("verified price") == true)
        XCTAssertFalse(CatalogHTTPProtocol.fixture.requests.contains { $0.httpMethod == "POST" })
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        let admitted = await store.send("Fixture unbudgeted request")
        XCTAssertTrue(admitted); await store.waitForResponse()
        XCTAssertEqual(store.selected?.messages.last?.text, "Fixture answer")
        let request = try XCTUnwrap(store.activityRecords.first { $0.kind == .response })
        XCTAssertNil(request.costUSD); XCTAssertEqual(request.costState, .unknown)
        XCTAssertNil(store.selected?.turns.last?.estimatedUSD)
        XCTAssertEqual(CatalogHTTPProtocol.fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testUnsubmittedRequestSurvivesProtectionAndRestartWithStableIDs() async throws {
        let account = UUID(); defer { cleanVoiceTest(account) }
        let oldBudget = UserDefaults.standard.bool(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(oldBudget, forKey: "aim.budget.enabled") }
        CatalogHTTPProtocol.fixture.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CatalogHTTPProtocol.self]
        let waiting = expectation(description: "Wait before provider admission")
        let transport = NativeChatTransport(session: URLSession(configuration: configuration), networkReadiness: { onWaiting in
            onWaiting(); waiting.fulfill(); try await Task.sleep(for: .seconds(10_000))
        })
        let store = trackNativeChatFixture(NativeChatStore(accountID: account, credentials: CatalogStoreTestSecrets(), transport: transport, notifyCompletion: { _, _, _, _, _ in }))
        store.provider = .openAI; store.modelID = "gpt-4.1"; store.preferences.automaticWebSearch = false; store.memory.enabled = false
        await store.loadModels()
        let admitted = await store.send("Preserve this exact request")
        XCTAssertTrue(admitted)
        await fulfillment(of: [waiting], timeout: 5)
        let conversation = try XCTUnwrap(store.selected), ids = conversation.messages.map(\.id)
        store.suspendForProtection(); await store.waitForResponse()
        XCTAssertFalse(CatalogHTTPProtocol.fixture.requests.contains { $0.httpMethod == "POST" })
        let restored = catalogStore(account); restored.provider = .openAI; restored.modelID = "gpt-4.1"
        await restored.loadModels(); restored.resumePendingSubmissions(); await restored.waitForResponse(conversationID: conversation.id)
        let result = try XCTUnwrap(restored.conversations.first { $0.id == conversation.id })
        XCTAssertEqual(result.messages.map(\.id), ids); XCTAssertEqual(result.messages.last?.text, "Fixture answer")
        XCTAssertEqual(CatalogHTTPProtocol.fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
        restored.resumePendingSubmissions(); await restored.waitForResponse(conversationID: conversation.id)
        XCTAssertEqual(CatalogHTTPProtocol.fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testCancelledUnsubmittedRequestNeverResumes() async throws {
        let account = UUID(); defer { cleanVoiceTest(account) }
        let oldBudget = UserDefaults.standard.bool(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(oldBudget, forKey: "aim.budget.enabled") }
        CatalogHTTPProtocol.fixture.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CatalogHTTPProtocol.self]
        let waiting = expectation(description: "Unsubmitted request waiting")
        let store = trackNativeChatFixture(NativeChatStore(accountID: account, credentials: CatalogStoreTestSecrets(), transport: NativeChatTransport(session: URLSession(configuration: configuration), networkReadiness: { announce in
            announce(); waiting.fulfill(); try await Task.sleep(for: .seconds(10_000))
        }), notifyCompletion: { _, _, _, _, _ in }))
        store.provider = .openAI; store.modelID = "gpt-4.1"; store.preferences.automaticWebSearch = false; store.memory.enabled = false
        await store.loadModels(); let accepted = await store.send("Cancel before sending"); XCTAssertTrue(accepted)
        await fulfillment(of: [waiting], timeout: 5)
        let id = try XCTUnwrap(store.selectedID)
        let snapshot = directory(account).appendingPathComponent("conversations.json")
        let staleHistory = try Data(contentsOf: snapshot)
        store.cancel(conversationID: id); await store.waitForResponse()
        // Simulate an unavailable history write: an older snapshot must not replay a cancelled request.
        try staleHistory.write(to: snapshot, options: .atomic)
        let restored = catalogStore(account);
        XCTAssertEqual(restored.conversations.first { $0.id == id }?.lastTurnStatus, "cancelled"); await restored.loadModels(); restored.resumePendingSubmissions()
        XCTAssertFalse(CatalogHTTPProtocol.fixture.requests.contains { $0.httpMethod == "POST" })
    }

    private func catalogStore(_ accountID: UUID, publicCatalogTimeout: Duration = .seconds(10)) -> NativeChatStore {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CatalogHTTPProtocol.self]
        return trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: CatalogStoreTestSecrets(),
            transport: NativeChatTransport(session: URLSession(configuration: configuration)), publicCatalogTimeout: publicCatalogTimeout,
            notifyCompletion: { _, _, _, _, _ in }))
    }

    func testOlderMemoryRefreshCannotReplaceAnEditSavedWhileTheReadWasInFlight() async throws {
        let accountID = UUID()

        var original = AccountMemorySnapshot(); original.revision = 7; original.enabled = true
        original.entries = [.init(subject: "Name", content: "Earlier name")]
        let service = try DelayedMemoryReadService(accountID: accountID, captured: original)
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, sync: service, credentials: AccountStoreTestSecrets()))
        store.memory = original
        let refresh = Task { await store.syncAccountData() }
        await service.waitUntilMemoryRead()
        var edited = original; edited.entries[0].content = "Saved new name"
        let saved = await store.saveMemory(edited)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.memory.revision, 8)
        await service.finishCapturedRead(); await refresh.value
        XCTAssertEqual(store.memory.revision, 8)
        XCTAssertEqual(store.memory.entries.first?.content, "Saved new name")
        let restored = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        XCTAssertEqual(restored.memory, store.memory, "The stale read must not regress the persisted copy either")
    }

    func testNewerMemoryRefreshStillUpdatesTheDevice() async throws {
        let accountID = UUID()

        var remote = AccountMemorySnapshot(); remote.revision = 9; remote.enabled = true
        remote.entries = [.init(subject: "Name", content: "Edited on Mac")]
        let service = try DelayedMemoryReadService(accountID: accountID, captured: remote)
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, sync: service, credentials: AccountStoreTestSecrets()))
        store.memory.revision = 8
        let refresh = Task { await store.syncAccountData() }
        await service.waitUntilMemoryRead(); await service.finishCapturedRead(); await refresh.value
        XCTAssertEqual(store.memory, remote)
    }

    func testVoiceChatSelectionIsAppliedToTheRuntimeAndPreservedForOnlyItsAccount() throws {
        let accountID = UUID(), otherAccountID = UUID()
        defer { cleanVoiceTest(accountID); cleanVoiceTest(otherAccountID) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        store.connectedProviders = [.openAI, .anthropic]
        store.provider = .openAI; store.modelID = "earlier-model"
        let chosen = ChatModel(id: "chosen-text-model", name: "Chosen text model")
        let voice = store.voiceController
        XCTAssertTrue(voice.selectConversationModel(provider: .anthropic, model: chosen))
        XCTAssertEqual(store.provider, .openAI, "Choosing a voice model does not interrupt the existing Chat")
        XCTAssertTrue(voice.applyConversationSelection(voice.resolvedConversationSelection, catalog: [chosen]))
        XCTAssertEqual(store.provider, .anthropic)
        XCTAssertEqual(store.modelID, chosen.id)
        XCTAssertEqual(store.models, [chosen], "The catalog used for actual Chat admission is the selected provider’s catalog")
        let restored = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        XCTAssertEqual(restored.voiceController.conversationSelection, AIMVoiceChatSelection(provider: .anthropic, modelID: chosen.id))
        let other = trackNativeChatFixture(NativeChatStore(accountID: otherAccountID, credentials: AccountStoreTestSecrets()))
        XCTAssertNil(other.voiceController.conversationSelection)
    }

    func testVoiceRuntimeRejectsUnavailableNonTextOrDisconnectedModelsWithoutSubstitution() {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        store.connectedProviders = [.openAI]
        store.provider = .openAI; store.modelID = "keep-this-model"
        var image = ChatModel(id: "image-model", name: "Image model")
        image.architecture = .init(inputModalities: ["text"], outputModalities: ["image"])
        let voice = store.voiceController
        XCTAssertFalse(voice.selectConversationModel(provider: .openAI, model: image))
        XCTAssertFalse(voice.applyConversationSelection(.init(provider: .openAI, modelID: image.id), catalog: [image]))
        XCTAssertFalse(voice.applyConversationSelection(.init(provider: .openAI, modelID: "removed-model"), catalog: []))
        XCTAssertFalse(voice.applyConversationSelection(.init(provider: .anthropic, modelID: "text-model"), catalog: [.init(id: "text-model", name: "Text model")]))
        XCTAssertEqual(store.provider, .openAI)
        XCTAssertEqual(store.modelID, "keep-this-model")
    }

    func testRealtimeUsesCapturedProjectRelevantMemoryPreferencesAndSelectedVoice() throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let project = NativeChatProject(name: "Selected", instructions: "Use captured project rules")
        let other = NativeChatProject(name: "Other", instructions: "Do not leak other project rules")
        store.projects = [project, other]; store.selectedProjectID = other.id
        let conversation = NativeChatConversation(title: "Captured", provider: .openAI, modelID: "gpt-4.1", projectID: project.id.uuidString)
        store.conversations = [conversation]; store.selectedID = conversation.id
        store.profileInstructions = "Use this profile preference"
        store.preferences.customInstructions = "Use shared custom instructions"
        store.memory.enabled = true
        store.memory.entries = [
            .init(subject: "General", content: "Shared general memory", pinned: true),
            .init(subject: "Project", content: "Captured project memory", projectID: project.id, pinned: true),
            .init(subject: "Other", content: "Do not leak other project memory", projectID: other.id, pinned: true)
        ]
        let voice = store.voiceController
        voice.configuration.voice = "cedar"; voice.configuration.language = "fr-FR"
        voice.captureSessionContext()
        store.selectedProjectID = other.id
        let payload = voice.realtimeSessionUpdate(query: "memory")
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        for text in ["Use captured project rules", "Use this profile preference", "Use shared custom instructions", "Shared general memory", "Captured project memory", "fr-FR"] { XCTAssertTrue(instructions.contains(text), text) }
        XCTAssertFalse(instructions.contains("Do not leak"))
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, "cedar")
        XCTAssertEqual(session["tool_choice"] as? String, "none")
        let nextTurn = try XCTUnwrap(voice.realtimeContextUpdate(query: "memory")["session"] as? [String: Any])
        XCTAssertNil(nextTurn["audio"], "Later turns must not attempt to change a Realtime voice after audio output")
        XCTAssertTrue((nextTurn["instructions"] as? String ?? "").contains("Captured project memory"))
        store.memory.enabled = false
        let disabled = voice.realtimeSessionUpdate(query: "memory")["session"] as? [String: Any]
        XCTAssertFalse((disabled?["instructions"] as? String ?? "").contains("Shared general memory"))
        let preview = voice.realtimeSessionUpdate(query: "memory", preview: true)["session"] as? [String: Any]
        XCTAssertFalse((preview?["instructions"] as? String ?? "").contains("Use shared custom instructions"), "The fixed preview never discloses account context")
        let sample = try XCTUnwrap(AIMVoiceController.realtimePreviewResponse()["response"] as? [String: Any])
        XCTAssertEqual(sample["conversation"] as? String, "none")
        XCTAssertEqual(sample["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(sample["max_output_tokens"] as? Int, 128)
        XCTAssertEqual((sample["input"] as? [Any])?.count, 0)
    }

    func testRealtimeStopPreservesPartialTurnOnceInCapturedConversationAfterSelectionChanges() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let priorBudget = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(priorBudget, forKey: "aim.budget.enabled") }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let projectID = UUID(), otherProjectID = UUID()
        let captured = NativeChatConversation(title: "Voice", provider: .openAI, modelID: RealtimeVoiceProtocol.defaultModel, projectID: projectID.uuidString)
        let other = NativeChatConversation(title: "Other", provider: .anthropic, modelID: "other", projectID: otherProjectID.uuidString)
        store.conversations = [captured, other]; store.selectedID = captured.id; store.selectedProjectID = otherProjectID
        let voice = store.voiceController; voice.configuration.engine = .realtime
        voice.captureSessionContext()
        XCTAssertTrue(voice.prepareRealtimeTurn(transcript: "Keep my spoken request"))
        try await voice.receive(.assistantTranscriptDelta("A partial spoken answer"))
        store.selectedID = other.id
        voice.stop(); voice.stop()
        let saved = try XCTUnwrap(store.conversations.first { $0.id == captured.id })
        XCTAssertEqual(saved.projectID, projectID.uuidString)
        XCTAssertEqual(saved.messages.map(\.text), ["Keep my spoken request", "A partial spoken answer"])
        XCTAssertEqual(store.selectedID, other.id, "Closing the captured turn must not replace the user's newer selection")
        XCTAssertEqual(store.conversations.first { $0.id == other.id }?.messages.count, 0)
        XCTAssertEqual(store.activityRecords.count, 1)
        let row = try XCTUnwrap(store.activityRecords.first)
        XCTAssertEqual(row.conversationID, captured.id); XCTAssertNotNil(row.completedAt)
        XCTAssertNil(row.costUSD); XCTAssertNil(row.totalTokens); XCTAssertEqual(row.costState, .unknown)
        XCTAssertEqual(voice.history.count, 1); XCTAssertEqual(voice.history.first?.conversationID, captured.id)
        let restored = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        XCTAssertEqual(restored.conversations.first { $0.id == captured.id }?.messages, saved.messages)
        XCTAssertEqual(restored.activityRecords.count, 1)
    }

    func testRealtimeIncompleteCompletionKeepsUnknownCostAndDoesNotReplayAtStop() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let priorBudget = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(priorBudget, forKey: "aim.budget.enabled") }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let unrelatedProject = NativeChatProject(name: "Other", instructions: "Never use this project")
        let original = NativeChatConversation(title: "Unassigned", provider: .openRouter, modelID: "original", projectID: nil)
        store.projects = [unrelatedProject]; store.selectedProjectID = unrelatedProject.id
        store.conversations = [original]; store.selectedID = original.id
        let voice = store.voiceController; voice.configuration.engine = .realtime
        voice.captureSessionContext()
        let instructions = (voice.realtimeSessionUpdate(query: "hello")["session"] as? [String: Any])?["instructions"] as? String ?? ""
        XCTAssertFalse(instructions.contains("Never use this project"), "An unassigned conversation does not inherit a stale project selector")
        XCTAssertTrue(voice.prepareRealtimeTurn(transcript: "Hello"))
        try await voice.receive(.assistantTranscriptDone("Hello back"))
        let done = RealtimeVoiceProtocol.parse(#"{"type":"response.done","response":{"status":"completed","usage":{}}}"#)
        try await voice.receive(done); try await voice.receive(done); voice.stop()
        XCTAssertEqual(store.conversations.count, 2)
        let saved = try XCTUnwrap(store.conversations.first { $0.modelID == RealtimeVoiceProtocol.defaultModel })
        XCTAssertNil(saved.projectID); XCTAssertEqual(saved.messages.count, 2)
        XCTAssertEqual(store.activityRecords.count, 1); XCTAssertEqual(voice.history.count, 1)
        let row = try XCTUnwrap(store.activityRecords.first)
        XCTAssertNil(row.costUSD); XCTAssertNil(row.totalTokens); XCTAssertEqual(row.costState, .unknown)
        // A repeated persisted receipt also uses stable message IDs.
        store.recordVoiceTurn(id: row.id, userText: "Hello", assistantText: "Hello back", start: row.startedAt,
            tokens: nil, cost: nil, context: .init(conversationID: saved.id, projectID: nil))
        XCTAssertEqual(store.conversations.first { $0.id == saved.id }?.messages.count, 2)
        XCTAssertEqual(store.activityRecords.count, 1)
    }

    func testRealtimeResponseReceiptDoesNotPretendToIncludeUnmeasuredTranscriptionCost() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let priorBudget = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(priorBudget, forKey: "aim.budget.enabled") }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let voice = store.voiceController; voice.configuration.engine = .realtime; voice.captureSessionContext()
        XCTAssertTrue(voice.prepareRealtimeTurn(transcript: "Spoken text"))
        try await voice.receive(.assistantTranscriptDone("Answer"))
        let done = RealtimeVoiceProtocol.parse(#"{"type":"response.done","response":{"status":"completed","usage":{"input_token_details":{"text_tokens":10,"audio_tokens":20,"cached_tokens":0},"output_token_details":{"text_tokens":5,"audio_tokens":10}}}}"#)
        try await voice.receive(done); voice.stop()
        let row = try XCTUnwrap(store.activityRecords.first)
        XCTAssertEqual(row.totalTokens, 45, "Only provider-reported Response tokens are currently measured")
        XCTAssertNil(row.costUSD); XCTAssertEqual(row.costState, .unknown, "The separate input-transcription receipt is not yet measured")
        XCTAssertEqual(store.activityRecords.count, 1)
    }

    func testAudioStopIsOrderedBeforeNewPreviewAndObsoleteActivationCannotStopIt() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let fixture = AudioSessionOrderFixture()
        let session = AIMVoiceAudioSession(activate: { fixture.activate(preview: $0) }, deactivate: { fixture.deactivate() })
        let voice = AIMVoiceController(chat: store, audioSession: session)
        voice.active = true
        let earlier = Task { try await voice.activateAudioSession(preview: false) }
        await fulfillment(of: [fixture.entered], timeout: 2)
        voice.stop() // Enqueues immediately, while the old activation is still blocked.
        voice.active = true
        let newer = Task { try await voice.activateAudioSession(preview: true) }
        fixture.release.signal()
        let oldReady = try await earlier.value, newReady = try await newer.value
        await session.drain()
        XCTAssertFalse(oldReady); XCTAssertTrue(newReady); XCTAssertTrue(voice.active)
        XCTAssertEqual(fixture.events, ["activate-conversation", "deactivate", "activate-preview"])
        await voice.stopAndWait()
        XCTAssertEqual(fixture.events.last, "deactivate")
    }

    func testCancelledAudioActivationClosesItsSessionWithoutProceeding() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let fixture = AudioSessionOrderFixture()
        let session = AIMVoiceAudioSession(activate: { fixture.activate(preview: $0) }, deactivate: { fixture.deactivate() })
        let voice = AIMVoiceController(chat: store, audioSession: session)
        voice.active = true
        let activation = Task { try await voice.activateAudioSession(preview: false) }
        await fulfillment(of: [fixture.entered], timeout: 2)
        activation.cancel(); fixture.release.signal()
        let ready = try await activation.value
        await session.drain()
        XCTAssertFalse(ready); XCTAssertFalse(voice.active)
        XCTAssertEqual(fixture.events, ["activate-conversation", "deactivate"])
    }

    func testSpeechSegmentsPreserveTheEntireLongUnicodeAnswer() {
        let text = String(repeating: "Bonjour 👩🏽‍💻 — voici la réponse complète.\n", count: 1000)
        let segments = NativeChatStore.speechSegments(text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.joined(), text)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 2000 && $0.utf8.count <= 8000 })
        XCTAssertEqual(NativeChatStore.speechSegments(""), [])
    }
    func testDictationHistoryKeepsEntriesBeyondTwoThousand() async throws {
        let accountID = UUID(); defer { cleanVoiceTest(accountID) }
        let priorBudget = UserDefaults.standard.object(forKey: "aim.budget.enabled")
        UserDefaults.standard.set(false, forKey: "aim.budget.enabled")
        defer { UserDefaults.standard.set(priorBudget, forKey: "aim.budget.enabled") }
        let store = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        let voice = store.voiceController; voice.configuration.engine = .realtime; voice.captureSessionContext()
        voice.history = (0..<2000).map { .init(text: "Previous \($0)", conversationID: nil) }
        let oldest = try XCTUnwrap(voice.history.first?.id)
        XCTAssertTrue(voice.prepareRealtimeTurn(transcript: "One more dictated request"))
        try await voice.receive(.assistantTranscriptDone("Answer")); voice.stop()
        XCTAssertEqual(voice.history.count, 2001); XCTAssertEqual(voice.history.first?.id, oldest)
        let restored = trackNativeChatFixture(NativeChatStore(accountID: accountID, credentials: AccountStoreTestSecrets()))
        XCTAssertEqual(restored.voiceController.history.count, 2001)
        XCTAssertEqual(restored.voiceController.history.first?.id, oldest)
    }

    func testInputDraftRestoresPerAccountAndFailedAdmissionKeepsSnapshots() async throws {
        let account = UUID(), other = UUID()
        defer { cleanVoiceTest(account); cleanVoiceTest(other) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: account, credentials: AccountStoreTestSecrets()))
        let id = store.draftIdentifier(conversationID: nil)
        let reference = await store.prepareInput(Data("Fixture document".utf8), name: "notes.txt", mimeType: "text/plain", draftID: id)
        XCTAssertNotNil(reference)
        store.setDraftText("Keep draft", conversationID: nil)
        let restored = trackNativeChatFixture(NativeChatStore(accountID: account, credentials: AccountStoreTestSecrets()))
        XCTAssertEqual(restored.draftIdentifier(conversationID: nil), id)
        XCTAssertEqual(restored.inputAttachments(id).first?.text, "Fixture document")
        XCTAssertEqual(restored.inputReferences(id).first?.transferID, reference?.transferID)
        XCTAssertEqual(restored.draftText, "Keep draft")
        XCTAssertTrue(trackNativeChatFixture(NativeChatStore(accountID: other, credentials: AccountStoreTestSecrets())).inputAttachments(id).isEmpty)
        let admitted = await restored.send("", attachments: restored.inputAttachments(id))
        XCTAssertFalse(admitted, "No credentials: no provider request or lost draft")
        XCTAssertEqual(restored.inputReferences(id).first?.transferID, reference?.transferID)
        restored.setInputReferences([], id: id)
        XCTAssertTrue(restored.inputAttachments(id).isEmpty)
    }

    func testInvalidImportDoesNotReplaceValidDraft() async {
        let account = UUID(); defer { cleanVoiceTest(account) }
        let store = trackNativeChatFixture(NativeChatStore(accountID: account, credentials: AccountStoreTestSecrets()))
        let id = store.draftIdentifier(conversationID: nil)
        _ = await store.prepareInput(Data("valid".utf8), name: "notes.txt", mimeType: "text/plain", draftID: id)
        let rejected = await store.prepareInput(Data("fake image".utf8), name: "photo.png", mimeType: "image/png", draftID: id)
        XCTAssertNil(rejected); XCTAssertEqual(store.inputAttachments(id).count, 1); XCTAssertNotNil(store.errorMessage)
    }

    private func cleanVoiceTest(_ accountID: UUID) {
        UserDefaults.standard.removeObject(forKey: "aim.chat.cancelled-unsent.v1." + accountID.uuidString.lowercased())
        for suffix in [".configuration", ".chat-selection", ".start"] { UserDefaults.standard.removeObject(forKey: "aim.voice." + accountID.uuidString + suffix) }
    }

    private func directory(_ accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Chat/\(accountID.uuidString)", directoryHint: .isDirectory)
    }
}

@MainActor
final class ConversationFilterPreferenceTests: XCTestCase {
    private func session(mode: RemoteMode = .chat, devices: [String]? = nil) -> RemoteSession {
        RemoteSession(id: UUID().uuidString, machineID: "legacy-mac", mode: mode, title: "Fixture", workspace: nil,
            modelID: nil, approvalMode: nil, status: "idle", messageCount: 2, updatedAt: .now,
            agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false, executionDeviceIDs: devices)
    }
    func testFiltersCombineTypeDevicesAndCompletedUnreadWithoutInventingProvenance() {
        let name = "aim.round21.filters." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let filter = AIMConversationFilters(accountID: UUID(), surface: "search", defaults: defaults)
        XCTAssertTrue(filter.includes(session(mode: .agent), status: .idle))
        filter.kind = .agent; filter.deviceIDs = ["phone", "mac-a"]; filter.unreadOnly = true
        XCTAssertTrue(filter.includes(session(mode: .agent, devices: ["mac-b", "mac-a"]), status: .unread))
        XCTAssertFalse(filter.includes(session(mode: .chat, devices: ["phone"]), status: .unread))
        XCTAssertFalse(filter.includes(session(mode: .agent, devices: ["phone"]), status: .running))
        XCTAssertFalse(filter.includes(session(mode: .agent, devices: ["phone"]), status: .failed))
        XCTAssertFalse(filter.includes(session(mode: .agent), status: .unread))
        XCTAssertFalse(filter.includes(session(mode: .agent, devices: ["mac-b"]), status: .unread))
    }
    func testPreferencesSurviveReconstructionAndStayIndependentAcrossAccountAndSurface() {
        let name = "aim.round21.filters." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let account = UUID()
        let search = AIMConversationFilters(accountID: account, surface: "search", defaults: defaults)
        search.kind = .code; search.unreadOnly = true; search.deviceIDs = ["offline-mac"]
        let restored = AIMConversationFilters(accountID: account, surface: "search", defaults: defaults)
        XCTAssertEqual(restored.kind, .code); XCTAssertTrue(restored.unreadOnly); XCTAssertEqual(restored.deviceIDs, ["offline-mac"])
        let recent = AIMConversationFilters(accountID: account, surface: "recent", defaults: defaults)
        XCTAssertEqual(recent.kind, .all); XCTAssertFalse(recent.unreadOnly); XCTAssertTrue(recent.deviceIDs.isEmpty)
        let other = AIMConversationFilters(accountID: UUID(), surface: "search", defaults: defaults)
        XCTAssertEqual(other.kind, .all); XCTAssertFalse(other.unreadOnly); XCTAssertTrue(other.deviceIDs.isEmpty)
    }
}

extension NativeChatStoreAccountTests {
    func testReadAcknowledgementRequiresLoadedAccessibleResponseAndNeverFuture() {
        let store = trackNativeChatFixture(NativeChatStore(accountID: UUID(), credentials: AccountStoreTestSecrets()))
        let conversation = UUID(), version = ConversationResponseVersion(id: UUID().uuidString, completedAt: .now)
        func session(_ response: ConversationResponseVersion, state: RemoteReadState = .readable) -> RemoteSession {
            .init(id: conversation.uuidString, machineID: "mac", mode: .agent, title: "test", workspace: nil, modelID: nil, approvalMode: nil, status: "idle", messageCount: 1, updatedAt: .now, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false, readState: state, executionDeviceIDs: ["mac"], latestResponseVersion: response)
        }
        XCTAssertEqual(store.conversationStatus(session: session(version)), .unread)
        store.acknowledge(session: session(version), loadedResponseIDs: ["other"])
        XCTAssertEqual(store.conversationStatus(session: session(version)), .unread)
        store.acknowledge(session: session(version, state: .keyPending), loadedResponseIDs: [version.id])
        XCTAssertEqual(store.conversationStatus(session: session(version)), .unread)
        store.acknowledge(session: session(version), loadedResponseIDs: [version.id])
        XCTAssertEqual(store.conversationStatus(session: session(version)), .idle)
        let future = ConversationResponseVersion(id: UUID().uuidString, completedAt: .now.addingTimeInterval(1))
        XCTAssertEqual(store.conversationStatus(session: session(future)), .unread)
    }
    func testImportedConversationDoesNotAcquireThisIPhoneProvenance() {
        let store = trackNativeChatFixture(NativeChatStore(accountID: UUID(), credentials: AccountStoreTestSecrets()))
        store.conversations = [.init(title: "legacy", provider: .openRouter, modelID: "test"), .init(title: "from Mac", provider: .openRouter, modelID: "test", executionDeviceIDs: ["mac"])]
        XCTAssertNil(store.searchSessions[0].executionDeviceIDs)
        XCTAssertEqual(store.searchSessions[1].executionDeviceIDs, ["mac"])
        XCTAssertTrue(store.searchSessions.allSatisfy { $0.executionDeviceIDs?.contains(store.deviceID) != true })
    }
}

@MainActor
final class ConversationDrawerMotionTests: XCTestCase {
    func testReversalStartsAtPresentedPositionAndRetainsCornersUntilClosed() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("Animated path requires Reduce Motion off") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = AIMMovingConversation<EmptyView>.Controller()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.stopMotion(); window.isHidden = true; previous?.makeKey() }
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        controller.move(to: 280, open: true, animated: true)
        try await Task.sleep(for: .milliseconds(90))
        let opening = controller.displayedOffset
        XCTAssertGreaterThan(opening, 1); XCTAssertLessThan(opening, 280)
        XCTAssertGreaterThan(controller.host.view.layer.cornerRadius, 0)
        controller.move(to: 0, open: false, animated: true)
        XCTAssertEqual(controller.displayedOffset, opening, accuracy: 3)
        try await Task.sleep(for: .milliseconds(70))
        let closing = controller.displayedOffset
        XCTAssertGreaterThan(controller.host.view.layer.cornerRadius, 0)
        controller.move(to: 280, open: true, animated: true)
        XCTAssertEqual(controller.displayedOffset, closing, accuracy: 3)
        try await Task.sleep(for: .milliseconds(450))
        controller.move(to: 0, open: false, animated: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(controller.host.view.layer.cornerRadius, 0)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(controller.displayedOffset, 0, accuracy: 1)
        XCTAssertEqual(controller.host.view.layer.cornerRadius, 0)
    }
}
