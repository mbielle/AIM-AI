@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import AIMAgentKit
import XCTest

@MainActor
final class PersonalizationRequestTests: XCTestCase {
    func testSendSnapshotsOpenAIReasoningEffortForSelectedModel() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Reasoning setting captured")
        let recorder = PreferenceRecorder()
        let model = AppModel(database: database, turnRunner: PreferenceRunner { request in recorder.set(request); captured.fulfill() })
        model.settings.openAIReasoningEffortByModel = ["fixture": .high, "other": .low]
        model.connectedProviders = [.openAI]
        model.selectedProvider = .openAI
        model.selectedModelID = "fixture"
        model.composerText = "Actual prompt"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        model.settings.openAIReasoningEffortByModel = ["fixture": .medium]
        XCTAssertEqual(recorder.get()?.openAIReasoningEffort, .high)
        _ = await model.prepareForTermination()
    }

    func testSendSnapshotsAnthropicOutputChoiceForSelectedModel() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Output setting captured")
        let recorder = PreferenceRecorder()
        let model = AppModel(database: database, turnRunner: PreferenceRunner { request in recorder.set(request); captured.fulfill() })
        model.settings.anthropicOutputTokensByModel = ["fixture": 32_768, "other": 1]
        model.connectedProviders = [.anthropic]
        model.selectedProvider = .anthropic
        model.selectedModelID = "fixture"
        model.composerText = "Actual prompt"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        model.settings.anthropicOutputTokensByModel = ["fixture": 16_384]
        XCTAssertEqual(recorder.get()?.anthropicOutputTokens, 32_768)
        _ = await model.prepareForTermination()
    }

    func testSendSnapshotsPreferencesWithoutWritingThemToHistory() async throws {
        let database = try AIMDatabase(inMemory: true)
        let captured = expectation(description: "Request captured")
        let recorder = PreferenceRecorder()
        let runner = PreferenceRunner { request in recorder.set(request); captured.fulfill() }
        let model = AppModel(database: database, turnRunner: runner)
        model.settings.personalization = .init(isEnabled: true, instructions: "First preference")
        model.connectedProviders = [.xAI]
        model.selectedProvider = .xAI
        model.selectedModelID = "fixture"
        model.composerText = "Actual prompt"
        await model.sendComposer()
        await fulfillment(of: [captured], timeout: 2)
        model.settings.personalization = .init(isEnabled: false, instructions: "Later preference")
        let request = try XCTUnwrap(recorder.get())
        XCTAssertEqual(request.personalization?.instructions, "First preference")
        XCTAssertEqual(request.personalization?.isEnabled, true)
        let messages = try await SQLiteConversationRepository(database: database).messages(conversationID: request.conversationID)
        XCTAssertEqual(messages.map(\.content), ["Actual prompt"])
        _ = await model.prepareForTermination()
    }
}

private struct PreferenceRunner: NativeAgentTurnRunning {
    let capture: @Sendable (AgentRequest) -> Void
    func cancel(conversationID: UUID) async { }
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        capture(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class PreferenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: AgentRequest?
    func set(_ value: AgentRequest) { lock.withLock { request = value } }
    func get() -> AgentRequest? { lock.withLock { request } }
}
