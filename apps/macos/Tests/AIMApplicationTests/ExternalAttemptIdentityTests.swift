import AIMApplication
import Foundation
import XCTest

private actor ExternalAttemptCounter {
    private var value = 0
    func sent() { value += 1 }
    func count() -> Int { value }
}
final class ExternalAttemptIdentityTests: XCTestCase {
    private func fixture() async throws -> (SQLiteGlobalSpendLedger, ExecutionScopedSpendLedger, UUID, UUID) {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "offline external attempt fixture", mode: .code)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: database), owner = UUID()
        try await repository.installOwner(owner)
        let admitted = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id,
            accountID: UUID(), request: Data("{}".utf8)), owner: owner)
        _ = try await repository.transition(admitted.id, owner: owner, expectedRevision: admitted.revision, to: .running)
        let ledger = SQLiteGlobalSpendLedger(database: database)
        return (ledger, ExecutionScopedSpendLedger(ledger: ledger, executionID: admitted.id, owner: owner, capUSD: "1"), admitted.id, owner)
    }
    func testStableWireAttemptCannotRepeatConfirmedPhysicalSend() async throws {
        let (ledger, scoped, execution, owner) = try await fixture()
        let meter = BillableRequestMeter(ledger: scoped), id = UUID(), counter = ExternalAttemptCounter()
        _ = try await meter.perform(provider: "openrouter", modelID: "fixture/model", feature: "external_model",
            maximumUSD: "0.2", attemptID: id, receiptUSD: { (_: String) in "0.1" }) {
                await counter.sent(); return "offline provider fixture"
            }
        do {
            _ = try await meter.perform(provider: "openrouter", modelID: "fixture/model", feature: "external_model",
                maximumUSD: "0.2", attemptID: id) { await counter.sent(); return "must not execute" }
            XCTFail("A repeated wire identity sent again")
        } catch { XCTAssertEqual(error as? SpendAdmissionError, .duplicateAttempt) }
        let sent = await counter.count(), attempt = try await ledger.executionAttempt(id, executionID: execution, owner: owner)
        XCTAssertEqual(sent, 1); XCTAssertEqual(attempt?.state, .confirmed); XCTAssertEqual(attempt?.actualUSD, "0.1")
    }
    func testStableWireAttemptCannotRepeatUnknownPhysicalSend() async throws {
        let (ledger, scoped, execution, owner) = try await fixture()
        let meter = BillableRequestMeter(ledger: scoped), id = UUID(), counter = ExternalAttemptCounter()
        do {
            let _: String = try await meter.perform(provider: "openrouter", modelID: "fixture/model", feature: "external_model",
                maximumUSD: "0.2", attemptID: id) {
                    await counter.sent(); throw URLError(.timedOut)
                }
            XCTFail("Simulated timeout succeeded")
        } catch { XCTAssertTrue(error is URLError) }
        do {
            _ = try await meter.perform(provider: "openrouter", modelID: "fixture/model", feature: "external_model",
                maximumUSD: "0.2", attemptID: id) { await counter.sent(); return "must not execute" }
            XCTFail("An unknown attempt sent again")
        } catch { XCTAssertTrue([SpendAdmissionError.unknownBound, .duplicateAttempt].contains(error as? SpendAdmissionError ?? .invalidPolicy)) }
        let sent = await counter.count(), attempt = try await ledger.executionAttempt(id, executionID: execution, owner: owner)
        XCTAssertEqual(sent, 1); XCTAssertEqual(attempt?.state, .unknown); XCTAssertEqual(attempt?.maximumUSD, "0.2")
    }
}
