import Foundation
import XCTest
@testable import AIMCore

final class ConversationContinuity21Tests: XCTestCase {
    func testReceiptUnionDoesNotAcknowledgeFutureAnswer() {
        let id = UUID().uuidString, first = ConversationResponseVersion(id: UUID().uuidString, completedAt: .now)
        let future = ConversationResponseVersion(id: UUID().uuidString, completedAt: .now)
        var a = ConversationReadReceipts(), b = ConversationReadReceipts()
        a.acknowledge(conversationID: id.uppercased(), response: first)
        b.acknowledge(conversationID: id.lowercased(), response: first)
        let merged = a.merging(b)
        XCTAssertTrue(merged.contains(conversationID: id, response: first))
        XCTAssertFalse(merged.contains(conversationID: id, response: future))
        XCTAssertEqual(merged, merged.merging(a))
    }
    func testStatusLegacyNeutralAndUnreadOnlyCompleted() {
        let response = ConversationResponseVersion(id: "response", completedAt: .now)
        XCTAssertEqual(ConversationActivityState.resolve(status: "idle", latestResponse: nil, read: false), .idle)
        XCTAssertEqual(ConversationActivityState.resolve(status: "running", latestResponse: response, read: false), .running)
        XCTAssertEqual(ConversationActivityState.resolve(status: "waiting_approval", latestResponse: response, read: false), .waiting)
        XCTAssertEqual(ConversationActivityState.resolve(status: "failed", latestResponse: response, read: false), .failed)
        XCTAssertEqual(ConversationActivityState.resolve(status: "idle", latestResponse: response, read: false), .unread)
        XCTAssertEqual(ConversationActivityState.resolve(status: "idle", latestResponse: response, read: true), .idle)
    }
    func testProjectionKeepsAllRemoteReferencesAndActualProvenance() {
        let id = UUID().uuidString
        let native = session(id: id, machine: "this-device", devices: ["iphone"])
        let mac1 = session(id: id.lowercased(), machine: "mac1", devices: ["mac1"])
        let mac2 = session(id: id, machine: "mac2", devices: nil)
        let projected = AccountConversationIdentity.projections(accountID: "account", native: [native], remote: [mac1, mac2])
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.remoteReferences.count, 2)
        XCTAssertEqual(Set(projected.first?.session.executionDeviceIDs ?? []), ["iphone", "mac1"])
        XCTAssertFalse(projected[0].session.executionDeviceIDs!.contains("mac2"))
        XCTAssertEqual(AccountConversationIdentity.projections(accountID: "account", native: [], remote: [mac2])[0].session.executionDeviceIDs, nil)
    }
    func testTitlesNeverMergeAndRenamingDoesNotChangeResponseVersion() {
        let first = session(id: "one", machine: "mac", devices: nil)
        let second = session(id: "two", machine: "mac", devices: nil)
        XCTAssertEqual(AccountConversationIdentity.sessions(accountID: "account", native: [first], remote: [second]).count, 2)
        let response = ConversationResponseVersion(id: "stable", completedAt: .now)
        var native = NativeChatConversation(title: "before", provider: .openRouter, modelID: "model", latestResponseVersion: response)
        native.title = "after"; native.updatedAt = .now.addingTimeInterval(50)
        XCTAssertEqual(native.latestResponseVersion, response)
    }
    func testLegacyConversationDecodeAndAnnouncementRoundTrip() throws {
        let original = NativeChatConversation(title: "legacy", provider: .openRouter, modelID: "model")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object.removeValue(forKey: "executionDeviceIDs"); object.removeValue(forKey: "latestResponseVersion")
        let decoded = try JSONDecoder().decode(NativeChatConversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.executionDeviceIDs); XCTAssertNil(decoded.latestResponseVersion)
        XCTAssertEqual(RemoteConversationAnnouncement.decode(phase: "Working").phase, "Working")
        let announcement = RemoteConversationAnnouncement(phase: "Working", executionDeviceIDs: ["mac"], latestResponseVersion: .init(id: "answer", completedAt: .now))
        XCTAssertEqual(RemoteConversationAnnouncement.decode(phase: announcement.encodedPhase()), announcement)
    }
    func testCASConflictMergesConcurrentAcknowledgements() async throws {
        let owner = UUID(), a = ConversationResponseVersion(id: "a", completedAt: .now), b = ConversationResponseVersion(id: "b", completedAt: .now)
        var local = ConversationReadReceipts(), remote = ConversationReadReceipts()
        local.acknowledge(conversationID: "conversation", response: a); remote.acknowledge(conversationID: "conversation", response: b)
        let service = ReceiptFixture(concurrent: remote)
        let result = try await ConversationReadReceiptSync.synchronize(local, accountID: owner, service: service, currentAccount: { owner })
        XCTAssertTrue(result.contains(conversationID: "conversation", response: a)); XCTAssertTrue(result.contains(conversationID: "conversation", response: b))
        let saves = await service.saves; XCTAssertEqual(saves, 2)
    }
    func testAccountChangePreventsReceiptWrite() async {
        let owner = UUID(), service = ReceiptFixture(concurrent: .init())
        do { _ = try await ConversationReadReceiptSync.synchronize(.init(), accountID: owner, service: service, currentAccount: { nil }); XCTFail("Expected revoked") }
        catch { XCTAssertEqual(error as? AccountServiceError, .revoked) }
        let saves = await service.saves; XCTAssertEqual(saves, 0)
    }
    func testStaleRunningSnapshotCannotHideNewCompletedResponse() {
        let date = Date(), id = UUID().uuidString
        let stale = RemoteSession(id: id, machineID: "mac", mode: .chat, title: "test", workspace: nil, modelID: nil, approvalMode: nil, status: "running", messageCount: 1, updatedAt: date.addingTimeInterval(-5), agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false)
        let complete = RemoteSession(id: id, machineID: "phone", mode: .chat, title: "test", workspace: nil, modelID: nil, approvalMode: nil, status: "idle", messageCount: 2, updatedAt: date, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false, latestResponseVersion: .init(id: "answer", completedAt: date))
        let result = AccountConversationIdentity.sessions(accountID: "account", native: [complete], remote: [stale])
        XCTAssertEqual(result.first?.status, "idle")
        XCTAssertEqual(result.first?.latestResponseVersion?.id, "answer")
    }
    private func session(id: String, machine: String, devices: [String]?) -> RemoteSession {
        .init(id: id, machineID: machine, mode: .chat, title: "same title", workspace: nil, modelID: nil, approvalMode: nil, status: "idle", messageCount: 1, updatedAt: .now, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false, executionDeviceIDs: devices)
    }
}

private actor ReceiptFixture: AccountContentSyncing {
    var saves = 0
    private var document: AccountDocument?
    private let concurrent: ConversationReadReceipts
    init(concurrent: ConversationReadReceipts) { self.concurrent = concurrent }
    func documents(accountID: UUID) async throws -> [AccountDocument] { document.map { [$0] } ?? [] }
    func save(_ value: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        saves += 1
        if saves == 1 {
            document = .init(id: ConversationReadReceiptSync.documentID, kind: "preferences", payload: String(decoding: try JSONEncoder().encode(concurrent), as: UTF8.self), revision: 1)
            throw AccountServiceError.conflict
        }
        XCTAssertEqual(value.revision, 1)
        var saved = value; saved.revision += 1; document = saved; return saved
    }
}
