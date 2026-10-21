import Foundation
import XCTest
@testable import AIMCore

private final class ContinuityMemoryStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func store(_ value: Data, forKey key: String) throws { lock.withLock { data[key] = value } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { data[key] } }
    func removeData(forKey key: String) throws { lock.withLock { data.removeValue(forKey: key) }; }
}
final class RemoteContinuityTests: XCTestCase {
    func testPublishedResultIsDistinctFromAdmittedCreationAfterNetworkLoss() {
        var receipt = RemoteContinuityCommandReceipt()
        receipt.submitted = true; receipt.acknowledged = true
        receipt.result = .object(["session_id": .string(UUID().uuidString)])
        XCTAssertFalse(RemoteContinuityCommandRules.shouldBeginNewGesture(receipt, continuousCreation: true))
        XCTAssertTrue(RemoteContinuityCommandRules.shouldBeginNewGesture(receipt, continuousCreation: false))
        receipt.publicationComplete = true
        XCTAssertTrue(RemoteContinuityCommandRules.shouldBeginNewGesture(receipt, continuousCreation: true))
        receipt.publicationComplete = nil; receipt.terminalError = "rejected"
        XCTAssertTrue(RemoteContinuityCommandRules.shouldBeginNewGesture(receipt, continuousCreation: true))
    }
    func testEncryptedAdmissionReceiptSurvivesUncertainSubmissionAndKeepsHistoryAfterFailure() throws {
        let memory = ContinuityMemoryStore()
        let journal = RemoteContinuityCommandStore(secureStore: memory)
        let key = RemoteContinuityCommandStore.key(accountID: UUID(), deviceID: "phone", commandKey: "start")
        var original = RemoteContinuityCommandReceipt()
        // Written before RPC. A lost HTTP response must reuse this exact envelope.
        original.wirePayload = .object(["e": .string("fixture-encrypted-envelope-with-stable-nonce")])
        try journal.save(original, key: key)
        let reopened = RemoteContinuityCommandStore(secureStore: memory)
        var retry = try XCTUnwrap(reopened.load(key: key))
        XCTAssertEqual(retry.commandID, original.commandID)
        XCTAssertEqual(retry.wirePayload, original.wirePayload)
        XCTAssertFalse(retry.submitted)
        retry.submitted = true; retry.acknowledged = true; retry.terminalError = "session_introuvable"
        try reopened.save(retry, key: key)
        let replacement = RemoteContinuityCommandReceipt()
        try reopened.save(replacement, key: key)
        XCTAssertNotEqual(replacement.commandID, original.commandID)
        let history = try XCTUnwrap(reopened.receipt(commandID: original.commandID, key: key))
        XCTAssertEqual(history.terminalError, "session_introuvable")
        XCTAssertEqual(history.wirePayload, original.wirePayload)
        XCTAssertNil(try reopened.load(key: key)?.terminalError)
    }
    func testOldReceiptWithoutNewFieldsStillRestores() throws {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["commandID": id, "createdAt": 123,
            "submitted": true, "acknowledged": true])
        let receipt = try JSONDecoder().decode(RemoteContinuityCommandReceipt.self, from: data)
        XCTAssertEqual(receipt.commandID, id); XCTAssertTrue(receipt.acknowledged)
        XCTAssertNil(receipt.terminalError); XCTAssertNil(receipt.wirePayload)
    }
    func testContinuousGoalHasNoDefaultCeilingAndOldGoalKeepsItsCap() {
        let goal = RemoteContinuousGoalConfiguration()
        XCTAssertTrue(goal.isValid); XCTAssertNil(goal.maximumTurns); XCTAssertNil(goal.maximumSpendUSD)
        XCTAssertNil(goal.json.objectValue?["max_turns"])
        XCTAssertEqual(RemoteGoalConfiguration(maximumTurns: 500).maximumTurns, 50)
        XCTAssertEqual(RemoteGoalConfiguration(continuous: true, maximumTurns: 500).json.objectValue?["max_turns"]?.numberValue, 500)
        XCTAssertNil(RemoteGoalConfiguration(continuous: true).json.objectValue?["max_turns"])
        XCTAssertFalse(RemoteContinuousGoalConfiguration(maximumTurns: 0).isValid)
    }
    func testOldComputerCannotExposeContinuousActionsAndRevisionStaysExact() throws {
        XCTAssertFalse(RemoteContinuityRules.supported(capabilities: RemoteCapabilities(features: ["goal": true])))
        XCTAssertNil(RemoteContinuityRules.goalPayload(text: "Work", maximumTurns: nil, capabilities: nil))
        let capabilities = RemoteCapabilities(features: [RemoteCapabilities.Feature.continuity: true])
        XCTAssertNotNil(RemoteContinuityRules.goalPayload(text: "Work", maximumTurns: nil, capabilities: capabilities))
        let snapshot = try XCTUnwrap(RemoteContinuitySnapshot(json: .object(["version": .number(1),
            "execution_id": .string(UUID().uuidString), "conversation_id": .string(UUID().uuidString),
            "state": .string("awaitingReview"), "revision": .string("9007199254740995"), "unknown_spend_attempts": .number(2)])))
        XCTAssertEqual(snapshot.revision, 9007199254740995); XCTAssertEqual(snapshot.unknownSpendAttempts, 2)
    }
    func testAcknowledgedCommandSurvivesSeveralDaysAndIsAccountScoped() throws {
        let memory = ContinuityMemoryStore(); let journal = RemoteContinuityCommandStore(secureStore: memory)
        let key = RemoteContinuityCommandStore.key(accountID: UUID(), deviceID: "phone", commandKey: "goal")
        var receipt = RemoteContinuityCommandReceipt(createdAt: .now.addingTimeInterval(-7 * 24 * 3600))
        receipt.submitted = true; receipt.acknowledged = true
        try journal.save(receipt, key: key)
        let reopened = RemoteContinuityCommandStore(secureStore: memory)
        XCTAssertEqual(try reopened.load(key: key), receipt)
        receipt.result = .object(["execution_id": .string(UUID().uuidString)])
        try reopened.save(receipt, key: key)
        try reopened.save(RemoteContinuityCommandReceipt(), key: key)
        XCTAssertEqual(try reopened.receipt(commandID: receipt.commandID, key: key), receipt)
        let other = RemoteContinuityCommandStore.key(accountID: UUID(), deviceID: "phone", commandKey: "goal")
        XCTAssertNil(try reopened.load(key: other))
    }
}
