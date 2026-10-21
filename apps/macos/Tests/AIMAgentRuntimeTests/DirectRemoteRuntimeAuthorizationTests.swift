import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation
import XCTest
@testable import AIMAgentRuntime

private struct DirectRuntimeSecrets: SecureStoring {
    func readData(forKey key: String) throws -> Data? { nil }
    func store(_ value: Data, forKey key: String) throws { throw DirectRemoteError.unauthorized }
    func removeData(forKey key: String) throws { }
}
private actor DirectUnusedRuntimeDriver: ContinuityTurnDriving {
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        throw DirectRemoteError.unauthorized
    }
    func cancel(conversationID: UUID) async { }
}
private final class DirectAdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func authorizeOnlyFirstBoundary() throws {
        let current = lock.withLock { value += 1; return value }
        if current > 1 { throw DirectRemoteError.revoked }
    }
    var count: Int { lock.withLock { value } }
}
final class DirectRemoteRuntimeAuthorizationTests: XCTestCase {
    func testRevocationAfterSessionReadIsRecheckedInsideResourceReservationBeforeMutation() async throws {
        let database = try AIMDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-runtime-auth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try RuntimeLease(url: directory.appendingPathComponent("runtime.lock")); defer { lease.release() }
        let conversations = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Original", mode: .chat)
        try await conversations.save(conversation)
        let coordinator = RunCoordinator(repository: SQLiteAgentExecutionRepository(database: database),
            driver: DirectUnusedRuntimeDriver(), lease: lease, authorized: { _ in false })
        try await coordinator.start()
        let dependencies = AgentRuntimeDependencies(conversations: conversations,
            missions: SQLiteAgentMissionRepository(database: database), runs: SQLiteWorkspaceRunRepository(database: database),
            secureStore: DirectRuntimeSecrets(), memory: nil, settings: nil, plans: nil,
            ledger: SQLiteGlobalSpendLedger(database: database), cuaQualifications: nil, mcpServers: nil)
        let counter = DirectAdmissionCounter()
        let bridge = RuntimeRemoteSessionBridge(dependencies: dependencies, coordinator: coordinator,
            authorizeOperation: { try counter.authorizeOnlyFirstBoundary() })
        do {
            _ = try await bridge.execute(commandID: UUID().uuidString, type: "rename_session", sessionID: conversation.id.uuidString,
                payload: .object(["title": .string("Must not be applied")]))
            XCTFail("Revoked grant must not cross a later native effect boundary")
        } catch { XCTAssertEqual(error as? DirectRemoteError, .revoked) }
        let saved = try await conversations.conversation(id: conversation.id)
        XCTAssertEqual(saved?.title, "Original"); XCTAssertEqual(counter.count, 2)
        try await coordinator.shutdown()
    }
}
