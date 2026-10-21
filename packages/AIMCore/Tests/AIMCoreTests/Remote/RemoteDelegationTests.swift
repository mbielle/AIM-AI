import Foundation
import XCTest
@testable import AIMCore

private final class DelegationMemory: SecureStoring, @unchecked Sendable {
    private let mutex = NSLock()
    private var data: [String: Data] = [:]
    var fails = false
    func readData(forKey key: String) throws -> Data? { mutex.withLock { data[key] } }
    func store(_ value: Data, forKey key: String) throws {
        if fails { throw RemoteServiceError.unavailable }
        mutex.withLock { data[key] = value }
    }
    func removeData(forKey key: String) throws { mutex.withLock { data[key] = nil } }
}
private actor DelegationRemote: RemoteServicing {
    private(set) var admissions: [RemoteSessionCreationRequest] = []
    var timesOut = true
    func setTimeout(_ value: Bool) { timesOut = value }
    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String {
        admissions.append(request)
        if timesOut { throw RemoteServiceError.unavailable }
        return "fixture-conversation"
    }
    func loadOverview() async throws -> RemoteOverview { throw RemoteServiceError.unavailable }
    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] { throw RemoteServiceError.unavailable }
    func pairDevice(code: String, name: String) async throws -> RemotePairingResult { throw RemoteServiceError.unavailable }
    func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult { throw RemoteServiceError.unavailable }
    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing { throw RemoteServiceError.unavailable }
    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult { throw RemoteServiceError.unavailable }
    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult { throw RemoteServiceError.unavailable }
    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult { throw RemoteServiceError.unavailable }
    func stopPreview(machineID: String, sessionID: String) async throws { throw RemoteServiceError.unavailable }
}
@available(macOS 14.0, iOS 17.0, *)
@MainActor final class RemoteDelegationTests: XCTestCase {
    private func request() -> RemoteDelegation {
        .init(machineID: "fixture-mac", modelID: "fixture-model", text: "Explicit goal", workspace: "/fixture", maximumSpendUSD: "0.50", maximumTurns: 3)
    }
    private func machine(online: Bool = true) -> RemoteMachine {
        .init(id: "fixture-mac", name: "Fixture", platform: "macOS", appVersion: "15", lastSeenAt: online ? .now : .distantPast, keyVersion: 1,
              capabilities: .init(models: [.init(id: "fixture-model", name: "Fixture", provider: "fixture")], features: [RemoteCapabilities.Feature.continuity: true]))
    }
    func testOfflineQueuePersistsButNeverSchedulesAndCancellationPreventsStart() async throws {
        let remote = DelegationRemote(), storage = DelegationMemory(), account = UUID()
        let service = RemoteDelegationService(accountID: account, remote: remote, secureStore: storage)
        let id = try service.enqueue(request())
        XCTAssertThrowsError(try service.enqueue(service.requests[0]))
        await service.start(id, machine: machine(online: false))
        let restored = RemoteDelegationService(accountID: account, remote: remote, secureStore: storage)
        XCTAssertEqual(restored.requests[0].state, .waiting)
        var calls = await remote.admissions; XCTAssertTrue(calls.isEmpty)
        try restored.cancel(id); await restored.start(id, machine: machine())
        calls = await remote.admissions; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(restored.requests[0].state, .cancelled)
        XCTAssertTrue(RemoteDelegationService(accountID: UUID(), remote: remote, secureStore: storage).requests.isEmpty)
    }
    func testTimeoutRetryKeepsStableIDModelBudgetAndExplicitApproval() async throws {
        let remote = DelegationRemote(), storage = DelegationMemory()
        let actual = RemoteDelegationService(accountID: UUID(), remote: remote, secureStore: storage)
        let id = try actual.enqueue(request()); await actual.start(id, machine: machine())
        XCTAssertEqual(actual.requests[0].state, .uncertain)
        XCTAssertThrowsError(try actual.cancel(id))
        await remote.setTimeout(false); await actual.start(id, machine: machine())
        let calls = await remote.admissions; XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.delegationID), [id, id]); XCTAssertEqual(calls.map(\.maximumSpendUSD), ["0.50", "0.50"])
        XCTAssertTrue(calls.allSatisfy { $0.approvalMode == "always_ask" && $0.modelID == "fixture-model" && $0.goal?.maximumTurns == 3 })
        XCTAssertEqual(actual.requests[0].conversationID, "fixture-conversation")
        await actual.start(id, machine: machine()); let finalCalls = await remote.admissions; XCTAssertEqual(finalCalls.count, 2)
    }
    func testStorageFailureNeverAdmitsRequest() async throws {
        let remote = DelegationRemote(), storage = DelegationMemory()
        let service = RemoteDelegationService(accountID: UUID(), remote: remote, secureStore: storage)
        let id = try service.enqueue(request()); storage.fails = true
        await service.start(id, machine: machine())
        let calls = await remote.admissions; XCTAssertTrue(calls.isEmpty); XCTAssertEqual(service.requests[0].state, .waiting)
        XCTAssertThrowsError(try service.enqueue(request())); XCTAssertEqual(service.requests.count, 1)
    }
}
