@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import Foundation
import XCTest

@MainActor
final class AgentEngineRoutingTests: XCTestCase {
    func testChosenEngineReceivesTurnAndCancellationAndIsSavedOnConversation() async throws {
        for engineID in [AgentEngineID.hermes, .openClaw] {
            let database = try AIMDatabase(inMemory: true)
            let engine = RecordingAgentEngine(id: engineID)
            let model = AppModel(database: database, settingsRepository: AgentTestSettings(), additionalAgentEngines: [engine])
            await model.start()
            model.selectMode(.agent, restoreRecent: false)
            model.selectAgentEngine(engineID)
            model.connectedProviders = [.openAI]
            model.selectedProvider = .openAI
            model.selectedModelID = "fixture"
            model.composerText = "Research this"

            await model.sendComposer()
            let id = try XCTUnwrap(model.selectedConversationID)
            let saved = try await SQLiteConversationRepository(database: database).conversation(id: id)
            XCTAssertEqual(saved?.engineID, engineID.rawValue)
            let sent = await engine.sentConversationIDs()
            XCTAssertEqual(sent, [id])
            model.selectAgentEngine(.aim)
            XCTAssertEqual(model.selectedAgentEngineID, engineID, "An established conversation cannot silently switch engines")

            await model.cancelCurrentTurn()
            let cancelled = await engine.cancelledConversationIDs()
            XCTAssertEqual(cancelled, [id])
            XCTAssertFalse(model.isSending)
            _ = await model.prepareForTermination()
        }
    }

    func testNativeAgentOffersToolsWithoutAWorkspace() async throws {
        let capture = AgentRequestCapture()
        let runner = AgentRequestRunner(capture: capture)
        let model = AppModel(database: try AIMDatabase(inMemory: true), turnRunner: runner)
        model.selectMode(.agent, restoreRecent: false)
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        model.composerText = "Read a web page"
        await model.sendComposer()
        let captured = await capture.request()
        let request = try XCTUnwrap(captured)
        XCTAssertNil(request.workspacePath)
        XCTAssertEqual(request.workspaceToolsEnabled, true)
        await model.cancelCurrentTurn()
        _ = await model.prepareForTermination()
    }
}

private actor RecordingAgentEngine: AgentEngine {
    nonisolated let id: AgentEngineID
    private var sent: [UUID] = []
    private var cancelled: [UUID] = []
    init(id: AgentEngineID) { self.id = id }
    func status() -> EngineStatus { EngineStatus(id: id, state: .ready, isInstalled: true) }
    func install() async throws {}
    func start() async throws {}
    func stop() async {}
    func diagnose() async -> EngineDiagnostic? { nil }
    func send(_ request: AgentRequest) async throws { sent.append(request.conversationID) }
    func cancel(conversationID: UUID) async { cancelled.append(conversationID) }
    func decide(approvalID: String, decision: ApprovalDecision) async {}
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func sentConversationIDs() -> [UUID] { sent }
    func cancelledConversationIDs() -> [UUID] { cancelled }
}

private actor AgentTestSettings: SettingsRepository {
    private var value = AppSettings()
    func load() -> AppSettings { value }
    func save(_ settings: AppSettings) { value = settings }
}

private actor AgentRequestCapture {
    private var value: AgentRequest?
    func set(_ request: AgentRequest) { value = request }
    func request() -> AgentRequest? { value }
}

private struct AgentRequestRunner: NativeAgentTurnRunning {
    let capture: AgentRequestCapture
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await capture.set(request); continuation.finish() }
        }
    }
    func cancel(conversationID: UUID) async {}
}
