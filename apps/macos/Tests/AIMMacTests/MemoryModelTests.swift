@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import AIMCore
import XCTest

@MainActor
final class MemoryModelTests: XCTestCase {
    func testProviderAssistedMemoryCaptureRequiresExplicitNewOptIn() async throws {
        let oldPreferences = Data(#"{"launchAtLogin":false,"selectedMode":"chat","activity":{"isEnabled":false,"retentionDays":30,"excludedApplications":[],"excludedDomains":[]}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldPreferences)
        XCTAssertNil(decoded.externalMemoryCaptureEnabled)
        XCTAssertFalse(decoded.externalMemoryCaptureEnabled == true)
        let model = AppModel(database: try AIMDatabase(inMemory: true), settingsRepository: IsolatedMemorySettings())
        XCTAssertTrue(model.settings.memoryEnabled != false)
        XCTAssertFalse(model.settings.externalMemoryCaptureEnabled == true)
        model.setExternalMemoryCaptureEnabled(true)
        XCTAssertEqual(model.settings.externalMemoryCaptureEnabled, true)
        model.setExternalMemoryCaptureEnabled(false)
        XCTAssertEqual(model.settings.externalMemoryCaptureEnabled, false)
        _ = await model.prepareForTermination()
    }

    func testMemoryCaptureRunsByDefaultAndNeverWhenTurnedOff() async throws {
        for captureOn in [true, false] {
            let store = MemoryReadCountingStore()
            let model = AppModel(database: try AIMDatabase(inMemory: true),
                                 turnRunner: MemoryRequestRunner(recorder: MemoryRequestRecorder()),
                                 settingsRepository: IsolatedMemorySettings(), providerStore: store)
            await model.start()
            if !captureOn { model.setExternalMemoryCaptureEnabled(false) }
            let startupReads = store.readCount
            model.connectedProviders = [.openAI]
            model.selectedProvider = .openAI
            model.selectedModelID = "fixture"
            model.composerText = "Remember that I prefer concise answers."
            await model.sendComposer()
            for _ in 0..<100 where model.isSending {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(model.isSending)
            // The capture reads the provider key in its own task after the answer is saved.
            for _ in 0..<100 where captureOn && store.readCount == startupReads {
                try await Task.sleep(for: .milliseconds(10))
            }
            if captureOn {
                XCTAssertGreaterThan(store.readCount, startupReads, "memory capture is on by default")
            } else {
                XCTAssertEqual(store.readCount, startupReads, "a person who turned capture off gets no memory request")
            }
            _ = await model.prepareForTermination()
        }
    }

    func testManualCorrectionPinArchiveRestoreAndDeletePersist() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteMemoryRepository(database: database)
        let model = AppModel(database: database, memoryRepository: repository)
        let item = MemoryItem(kind: .preference, scope: "global", scopeKey: "self",
                              subjectKey: "answer style", content: "Keep replies short.",
                              evidenceQuote: "I like short replies", sourceMessageID: UUID(), status: .provisional)
        try await repository.save(item)
        await model.loadMemories()
        XCTAssertEqual(model.memories.first?.status, .provisional)
        XCTAssertEqual(model.memories.first?.evidenceQuote, item.evidenceQuote)
        XCTAssertEqual(model.memories.first?.sourceMessageID, item.sourceMessageID)
        var corrected = item
        corrected.content = "Use detailed replies."
        try await model.saveMemory(corrected)
        XCTAssertEqual(model.memories.first?.status, .verified)
        XCTAssertEqual(model.memories.first?.content, "Use detailed replies.")
        await model.setMemoryPinned(try XCTUnwrap(model.memories.first), true)
        XCTAssertEqual(model.memories.first?.isPinned, true)
        await model.archiveMemory(item.id)
        XCTAssertEqual(model.memories.first?.status, .archived)
        XCTAssertTrue(MemoryContext.relevant(model.memories, query: "replies", projectID: nil).isEmpty)
        await model.restoreMemory(try XCTUnwrap(model.memories.first))
        XCTAssertEqual(model.memories.first?.status, .verified)
        await model.deleteMemory(item.id)
        XCTAssertTrue(model.memories.isEmpty)
        let remaining = try await repository.list(status: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMemoryOptOutIsSnapshottedIntoAgentRequest() async throws {
        let recorder = MemoryRequestRecorder()
        let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: MemoryRequestRunner(recorder: recorder),
                             settingsRepository: IsolatedMemorySettings())
        model.setMemoryEnabled(false)
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        model.composerText = "Tell me about SwiftUI"
        await model.sendComposer()
        XCTAssertEqual(recorder.request?.memoryEnabled, false)
        _ = await model.prepareForTermination()
    }

    func testAutomaticCaptureUpdatesOnlyUnreviewedMemoryAndExplicitRequestCanRestore() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteMemoryRepository(database: database)
        let capture = MemoryCaptureService(repository: repository, secureStore: MemoryNoopKeyStore())
        let original = MemoryItem(kind: .preference, scope: "global", scopeKey: "self",
                                  subjectKey: "answer style", content: "Use short answers.", status: .provisional)
        try await repository.save(original)
        var changed = original
        changed.id = UUID()
        changed.content = "Use detailed answers."
        changed.evidenceQuote = "I prefer detailed answers"
        changed.updatedAt = original.updatedAt.addingTimeInterval(1)
        let firstSave = try await capture.saveNew([changed])
        XCTAssertEqual(firstSave, 1)
        var records = try await repository.list(status: nil)
        var current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.id, original.id)
        XCTAssertEqual(current.content, changed.content)
        XCTAssertEqual(current.status, .provisional)

        var delayedOlderResult = changed
        delayedOlderResult.content = "Use short answers again."
        delayedOlderResult.updatedAt = original.updatedAt
        let staleSave = try await capture.saveNew([delayedOlderResult])
        XCTAssertEqual(staleSave, 0)
        records = try await repository.list(status: nil)
        XCTAssertEqual(records.first?.content, "Use detailed answers.")

        current.status = .verified
        try await repository.save(current)
        changed.content = "Use bullet points."
        changed.updatedAt = original.updatedAt.addingTimeInterval(2)
        let protectedSave = try await capture.saveNew([changed])
        XCTAssertEqual(protectedSave, 0)
        records = try await repository.list(status: nil)
        XCTAssertEqual(records.first?.content, "Use detailed answers.")
        let explicitSave = try await capture.saveNew([changed], explicitRequest: true)
        XCTAssertEqual(explicitSave, 1)
        records = try await repository.list(status: nil)
        XCTAssertEqual(records.first?.content, "Use bullet points.")

        try await repository.archive(id: original.id)
        changed.content = "Use one sentence."
        changed.updatedAt = original.updatedAt.addingTimeInterval(3)
        let archivedSave = try await capture.saveNew([changed])
        XCTAssertEqual(archivedSave, 0)
        records = try await repository.list(status: nil)
        XCTAssertEqual(records.first?.status, .archived)
        let explicitRestore = try await capture.saveNew([changed], explicitRequest: true)
        XCTAssertEqual(explicitRestore, 1)
        records = try await repository.list(status: nil)
        current = try XCTUnwrap(records.first)
        XCTAssertEqual(current.id, original.id)
        XCTAssertEqual(current.status, .verified, "\"remember that…\" is the person's own statement")
        XCTAssertEqual(current.content, "Use one sentence.")
    }
}

private struct MemoryNoopKeyStore: SecureStoring {
    func store(_ data: Data, forKey key: String) throws { }
    func readData(forKey key: String) throws -> Data? { nil }
    func removeData(forKey key: String) throws { }
}

private final class MemoryReadCountingStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func store(_ data: Data, forKey key: String) throws { }
    func readData(forKey key: String) throws -> Data? {
        lock.withLock { reads += 1 }
        return Data("fixture-key".utf8)
    }
    func removeData(forKey key: String) throws { }
}

private final class MemoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentRequest?
    var request: AgentRequest? { lock.withLock { stored } }
    func record(_ request: AgentRequest) { lock.withLock { stored = request } }
}

private struct MemoryRequestRunner: NativeAgentTurnRunning {
    let recorder: MemoryRequestRecorder
    func cancel(conversationID: UUID) async { }
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        recorder.record(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

private actor IsolatedMemorySettings: SettingsRepository {
    private var value = AppSettings()
    func load() -> AppSettings { value }
    func save(_ settings: AppSettings) { value = settings }
}
