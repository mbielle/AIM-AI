import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private struct BridgeFixtureSecrets: SecureStoring {
    func readData(forKey key: String) throws -> Data? { key == ChatProvider.openRouter.rawValue ? Data("not-a-real-key".utf8) : nil }
    func store(_ data: Data, forKey key: String) throws { throw ExecutionStoreError.invalidTransition }
    func removeData(forKey key: String) throws { throw ExecutionStoreError.invalidTransition }
}
private actor BridgeFixtureSettings: SettingsRepository {
    func load() -> AppSettings {
        var settings = AppSettings(selectedModelID: "fixture-only")
        settings.selectedProvider = .openRouter
        return settings
    }
    func save(_ settings: AppSettings) {}
}
private actor BridgeFixtureDriver: ContinuityTurnDriving {
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        .wait(WakeCondition(executionID: context.executionID, kind: .deadline, key: "fixture", dueAt: .now.addingTimeInterval(3600)))
    }
    func cancel(conversationID: UUID) async {}
}

final class ContinuityRemoteBridgeTests: XCTestCase {
    func testHeadlessAdmissionKeepsCodeModeDeduplicatesAndAcceptsCorrectionWhilePaused() async throws {
        let database = try AIMDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-bridge-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try RuntimeLease(url: directory.appending(path: "runtime.lock")); defer { lease.release() }
        let executions = SQLiteAgentExecutionRepository(database: database)
        let conversations = SQLiteConversationRepository(database: database), account = UUID()
        let dependencies = AgentRuntimeDependencies(conversations: conversations,
            missions: SQLiteAgentMissionRepository(database: database), runs: SQLiteWorkspaceRunRepository(database: database),
            secureStore: BridgeFixtureSecrets(), memory: nil, settings: BridgeFixtureSettings(), plans: nil,
            ledger: SQLiteGlobalSpendLedger(database: database), cuaQualifications: nil, mcpServers: nil)
        let coordinator = RunCoordinator(repository: executions, driver: BridgeFixtureDriver(), lease: lease,
            authorized: { $0 == account })
        try await coordinator.start()
        let cache = ModelCatalogCache(directory: directory.appending(path: "catalog"))
        try await cache.save([ChatModel(id: "fixture-only", name: "Fixture")], for: .openRouter)
        let bridge = ContinuityRemoteBridge(coordinator: coordinator, dependencies: dependencies, executions: executions,
            qualified: true, catalogCache: cache, accountID: { account })
        let qualifiedCapabilities = await bridge.remoteCapabilities()
        XCTAssertTrue(RemoteContinuityRules.supported(capabilities: qualifiedCapabilities))
        XCTAssertEqual(qualifiedCapabilities.features["goal"], true)
        let unqualified = ContinuityRemoteBridge(coordinator: coordinator, dependencies: dependencies, executions: executions,
            qualified: false, catalogCache: cache, accountID: { account })
        let unqualifiedCapabilities = await unqualified.remoteCapabilities()
        XCTAssertEqual(unqualifiedCapabilities.features[RemoteCapabilities.Feature.continuityAvailable], true)
        XCTAssertFalse(RemoteContinuityRules.supported(capabilities: unqualifiedCapabilities))
        XCTAssertEqual(unqualifiedCapabilities.features["goal"], false)
        let command = UUID(), payload = RemoteJSONValue.object(["mode": .string("code"), "text": .string("Continue this Code task"),
            "model_id": .string("fixture-only"), "workspace": .string(FileManager.default.homeDirectoryForCurrentUser.path),
            "goal": RemoteContinuousGoalConfiguration().json])
        var rejected = try XCTUnwrap(payload.objectValue)
        rejected["provider"] = .string(ChatProvider.anthropic.rawValue)
        do {
            _ = try await bridge.remoteExecute(commandID: UUID().uuidString, type: "create_session", sessionID: nil, payload: .object(rejected), attachments: [])
            XCTFail("An explicit disconnected provider must not fall back to the first catalog")
        } catch { }
        let beforeAdmission = try await conversations.list(includeArchived: true)
        XCTAssertTrue(beforeAdmission.isEmpty)
        let response = try await bridge.remoteExecute(commandID: command.uuidString, type: "create_session", sessionID: nil, payload: payload, attachments: [])
        let repeated = try await bridge.remoteExecute(commandID: command.uuidString, type: "create_session", sessionID: nil, payload: payload, attachments: [])
        XCTAssertEqual(response?.objectValue?["execution_id"], repeated?.objectValue?["execution_id"])
        do {
            _ = try await bridge.remoteExecute(commandID: command.uuidString, type: "create_session", sessionID: nil, payload: .object(rejected), attachments: [])
            XCTFail("Reusing a command must not replace its original provider")
        } catch { }
        let saved = try await conversations.conversation(id: command)
        XCTAssertEqual(saved?.mode, .code)
        let records = try await coordinator.list(); XCTAssertEqual(records.count, 1)
        let request = try JSONDecoder().decode(AgentRequest.self, from: XCTUnwrap(records.first).request)
        XCTAssertEqual(request.mode, .code); XCTAssertNil(request.continuityMaximumTurns); XCTAssertNil(request.continuityMaximumSpendUSD)
        let snapshots = await bridge.remoteSnapshots(); XCTAssertEqual(snapshots.first?.mode, "code")
        let session = command.uuidString
        _ = try await bridge.remoteExecute(commandID: UUID().uuidString, type: "goal_pause", sessionID: session, payload: .object([:]), attachments: [])
        _ = try await bridge.remoteExecute(commandID: UUID().uuidString, type: "goal_correct", sessionID: session,
            payload: .object(["text": .string("Keep the original workspace")]), attachments: [])
        let paused = try await coordinator.snapshot(try XCTUnwrap(records.first).id)
        XCTAssertEqual(paused?.state, .paused)
        let inputs = try await executions.pendingUserInputs(executionID: try XCTUnwrap(records.first).id, owner: lease.generation)
        XCTAssertEqual(inputs.map(\.content), ["Keep the original workspace"])
        try await coordinator.shutdown()
    }
}
