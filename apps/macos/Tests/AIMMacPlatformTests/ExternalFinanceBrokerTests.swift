import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

final class ExternalFinanceBrokerTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let executions: SQLiteAgentExecutionRepository
        let ledger: SQLiteGlobalSpendLedger
        let broker: ExternalFinanceBroker
        let session: ExternalFinanceSession
        let owner: UUID
    }
    private func fixture() async throws -> Fixture {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "external finance fixture", mode: .code)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let executions = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(), account = UUID()
        try await executions.installOwner(owner)
        var request = AgentRequest(conversationID: conversation.id, text: "fixture", modelID: "fixture-model", mode: .code, provider: .openRouter)
        request.continuityMaximumSpendUSD = "1"
        let admitted = try await executions.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id,
            accountID: account, request: JSONEncoder().encode(request)), owner: owner)
        _ = try await executions.transition(admitted.id, owner: owner, expectedRevision: admitted.revision, to: .running)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-external-finance-" + UUID().uuidString)
        let ledger = SQLiteGlobalSpendLedger(database: database)
        let broker = try ExternalFinanceBroker(ledger: ledger, executions: executions, owner: owner, directory: directory,
            accountID: { account }, authorize: { _, _ in true }, verifyBound: { _, request in ["0.6", "0.5"].contains(request.maximumUSD ?? "") })
        let configuration = ExternalEngineConfiguration(identity: "aim-test-bridge", engineVersion: "fixture-v1",
            executable: URL(fileURLWithPath: "/not-launched"), executableSHA256: String(repeating: "a", count: 64),
            enabled: true, allowModelCalls: true, isolationReceipt: "fixture-no-process", version: 2, financeProtocolVersion: 1)
        let session = try await broker.open(request: request, runID: UUID(), configuration: configuration,
            binding: ExternalFinanceBinding(executionID: admitted.id, accountID: account, allowedFeatures: ["agent", "active_compaction"],
                expiresAt: .now.addingTimeInterval(3600)))
        return Fixture(directory: directory, executions: executions, ledger: ledger, broker: broker, session: session, owner: owner)
    }
    private func admission(_ session: ExternalFinanceSession, id: UUID = UUID(), amount: String = "0.6") -> ExternalFinanceRequest {
        ExternalFinanceRequest(requestID: UUID(), grantID: session.grant.id, action: .admit, attemptID: id,
            provider: session.grant.provider, modelID: session.grant.modelID, feature: "agent", maximumUSD: amount)
    }
    func testExactAdmissionAndSentRetransmissionDoNotReserveTwiceAndCloseKeepsUnknown() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = admission(fixture.session)
        let first = try await fixture.session.handle(request)
        let replay = try await fixture.session.handle(request)
        XCTAssertEqual(first.attempt?.id, replay.attempt?.id)
        let sent = ExternalFinanceRequest(requestID: UUID(), grantID: fixture.session.grant.id, action: .sent, attemptID: request.attemptID)
        _ = try await fixture.session.handle(sent)
        let acknowledgment = try await fixture.session.handle(sent)
        XCTAssertEqual(acknowledgment.attempt?.state, .sent)
        var conflict = sent; conflict.requestID = UUID()
        do { _ = try await fixture.session.handle(conflict); XCTFail("Second send identity was admitted") }
        catch { XCTAssertEqual(error as? SpendAdmissionError, .duplicateAttempt) }
        try await fixture.session.close()
        let snapshot = try await fixture.ledger.executionSnapshot(fixture.session.grant.executionID)
        XCTAssertEqual(snapshot.countedUSD, "0.6"); XCTAssertEqual(snapshot.confirmedUSD, "0"); XCTAssertEqual(snapshot.unknownAttempts, 1)
        do { _ = try await fixture.session.handle(sent); XCTFail("Closed scope returned a new send authorization") }
        catch { XCTAssertEqual(error as? SpendAdmissionError, .invalidPolicy) }
    }
    func testUnverifiedZeroReceiptStaysUnknownAndCapBlocksNextPhysicalAttempt() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = admission(fixture.session)
        _ = try await fixture.session.handle(request)
        _ = try await fixture.session.handle(.init(requestID: UUID(), grantID: fixture.session.grant.id, action: .sent, attemptID: request.attemptID))
        let receipt = try await fixture.session.handle(.init(requestID: UUID(), grantID: fixture.session.grant.id, action: .reconcile,
            attemptID: request.attemptID, actualUSD: "0", providerReceipt: Data("untrusted-stdout".utf8), receiptSourceID: "fake"))
        XCTAssertEqual(receipt.disposition, .denied)
        let snapshot = try await fixture.ledger.executionSnapshot(fixture.session.grant.executionID)
        XCTAssertEqual(snapshot.countedUSD, "0.6"); XCTAssertEqual(snapshot.unknownAttempts, 1)
        let next = try await fixture.session.handle(admission(fixture.session, amount: "0.5"))
        XCTAssertEqual(next.disposition, .denied); XCTAssertEqual(next.diagnostic, "limitReached")
    }
    func testProviderScopeAndReplacedOwnerCannotAdmitOrConfirmCost() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var wrong = admission(fixture.session); wrong.modelID = "ungranted-model"
        do { _ = try await fixture.session.handle(wrong); XCTFail("Model scope widened") }
        catch { XCTAssertEqual(error as? SpendAdmissionError, .invalidPolicy) }
        let request = admission(fixture.session)
        _ = try await fixture.session.handle(request)
        try await fixture.executions.installOwner(UUID())
        do { _ = try await fixture.session.handle(.init(requestID: UUID(), grantID: fixture.session.grant.id, action: .sent, attemptID: request.attemptID)); XCTFail("Stale owner admitted send") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }
}
