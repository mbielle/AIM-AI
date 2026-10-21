import AIMCore
import CryptoKit
import Foundation
import XCTest
@testable import AIMMac

private final class DirectAccessSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func store(_ value: Data, forKey key: String) throws { lock.withLock { values[key] = value } }
    func removeData(forKey key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
final class DirectRemoteAccessTests: XCTestCase {
    private func pair(permissions: Set<DirectRemotePermission> = [.read, .chat]) async throws -> (LocalProfile, DirectRemotePair) {
        let profile = LocalProfile(id: UUID()), secret = DirectAccessSecrets()
        let host = DirectRemoteIdentity(profile: profile, role: .mac, name: "Fixture Mac")
        let phone = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Fixture phone")
        let authority = try DirectRemotePairingHost(identity: host, store: secret)
        let invitation = try await authority.createInvite()
        _ = try await authority.propose(DirectRemoteClaim(invite: invitation, client: phone.publicIdentity))
        let confirmed = try await authority.confirmDevice(phone.publicIdentity.id, permissions: permissions)
        return (profile, try DirectRemoteCoding.decode(DirectRemotePair.self, confirmed.pairBytes))
    }
    func testDirectGrantDoesNotAuthorizeAnotherLocalProfileOrAbsentIdentity() async throws {
        let (profile, pair) = try await pair()
        XCTAssertNoThrow(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profile.id, currentIdentity: .local(profile), permission: .chat))
        XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profile.id, currentIdentity: .local(.init(id: UUID())), permission: .chat))
        XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profile.id, currentIdentity: nil, permission: .chat))
        XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profile.id,
            currentIdentity: .account(.init(id: profile.id, email: nil, fullName: nil)), permission: .chat))
        XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: UUID(), currentIdentity: .local(profile), permission: .read))
    }
    func testReadChatGrantCannotRunTerminalControlOrApproveAndRevocationDeniesReads() async throws {
        let (profile, pair) = try await pair()
        for permission: DirectRemotePermission in [.terminal, .control, .approve, .agent, .code, .settings] {
            XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profile.id, currentIdentity: .local(profile), permission: permission))
        }
        var revoked = pair; revoked.revoked = true
        XCTAssertThrowsError(try MacDirectAccessRules.authorize(pair: revoked, expectedProfileID: profile.id, currentIdentity: .local(profile), permission: .read))
    }
    func testSmartAndAutoApprovalCannotBypassExplicitMacPermissions() async throws {
        let (_, pair) = try await pair()
        XCTAssertNoThrow(try MacDirectAccessRules.authorizeApprovalMode("review", pair: pair))
        XCTAssertThrowsError(try MacDirectAccessRules.authorizeApprovalMode("smart", pair: pair))
        XCTAssertThrowsError(try MacDirectAccessRules.authorizeApprovalMode("auto", pair: pair))
        let (_, privileged) = try await self.pair(permissions: [.read, .agent, .control, .approve])
        XCTAssertNoThrow(try MacDirectAccessRules.authorizeApprovalMode("smart", pair: privileged))
        XCTAssertNoThrow(try MacDirectAccessRules.authorizeApprovalMode("auto", pair: privileged))
    }
    func testChunkedAttachmentIsBoundToPairAndSessionAndVerifiesDigest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-vault-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try DirectRemoteAttachmentVault(directory: directory)
        let pair = UUID(), session = UUID(), transfer = UUID(), data = Data("synthetic document".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var value: [String: RemoteJSONValue] = ["transfer_id": .string(transfer.uuidString), "phase": .string("begin"),
            "name": .string("../../fixture.txt"), "mime": .string("text/plain"), "size": .number(Double(data.count)), "sha256": .string(digest)]
        _ = try await vault.upload(value, pairID: pair, sessionID: session)
        value = ["transfer_id": .string(transfer.uuidString), "phase": .string("chunk"), "offset": .number(0), "data": .string(data.base64EncodedString())]
        _ = try await vault.upload(value, pairID: pair, sessionID: session)
        _ = try await vault.upload(value, pairID: pair, sessionID: session) // same bytes retry is idempotent
        value = ["transfer_id": .string(transfer.uuidString), "phase": .string("finish")]
        _ = try await vault.upload(value, pairID: pair, sessionID: session)
        let references = RemoteJSONValue.array([.object(["transfer_id": .string(transfer.uuidString)])])
        let files = try await vault.attachments(references, pairID: pair, sessionID: session)
        XCTAssertEqual(files.first?.data, data); XCTAssertEqual(files.first?.name, "fixture.txt")
        do { _ = try await vault.attachments(references, pairID: UUID(), sessionID: session); XCTFail("Another paired phone must not read these bytes") } catch { }
        do { _ = try await vault.attachments(references, pairID: pair, sessionID: UUID()); XCTFail("Another conversation must not reuse these bytes") } catch { }
        await vault.revoke(pairID: pair)
        do { _ = try await vault.attachments(references, pairID: pair, sessionID: session); XCTFail("Revoked device's staged data must be removed") } catch { }
    }
    func testSuspensionFencesWaitingOperationsButAllowsReconnectAndRevocationDoesNot() async throws {
        let registry = DirectRemoteGrantRegistry(), id = UUID()
        let first = try await registry.grant(for: id, revision: 1)
        XCTAssertTrue(first.isActive)
        _ = await registry.suspend(id)
        XCTAssertFalse(first.isActive)
        let second = try await registry.grant(for: id, revision: 1)
        XCTAssertTrue(second.isActive)
        _ = await registry.revoke(id)
        XCTAssertFalse(second.isActive)
        do { _ = try await registry.grant(for: id, revision: 1); XCTFail("Revocation cannot be undone by reconnecting") } catch { }
    }
    func testPermissionEditFencesBothWaitingAndLateOldRevisionRequests() async throws {
        let registry = DirectRemoteGrantRegistry(), id = UUID(), otherID = UUID()
        let waiting = try await registry.grant(for: id, revision: 1)
        let other = try await registry.grant(for: otherID, revision: 1)
        await registry.track("synthetic-conversation", pairID: id)
        let stopped = await registry.updatePermissions(pairID: id, revision: 2)
        XCTAssertEqual(stopped, ["synthetic-conversation"])
        XCTAssertFalse(waiting.isActive, "An operation waiting inside the UI adapter loses its live grant")
        XCTAssertTrue(other.isActive, "Editing one phone does not suspend another phone")
        do {
            _ = try await registry.grant(for: id, revision: 1)
            XCTFail("A delayed dispatcher request cannot recreate the removed privileged grant")
        } catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        let reconnected = try await registry.grant(for: id, revision: 2)
        XCTAssertTrue(reconnected.isActive)
        _ = await registry.suspend(id)
        do {
            _ = try await registry.grant(for: id, revision: 1)
            XCTFail("Transport suspension must retain the permission revision fence")
        } catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
    }
    func testPermissionEditBeforeFirstRequestAndDelayedUpdatesCannotReopenOldRevision() async throws {
        let registry = DirectRemoteGrantRegistry(), id = UUID()
        _ = await registry.updatePermissions(pairID: id, revision: 3)
        do { _ = try await registry.grant(for: id, revision: 1); XCTFail("Dormant pairs need the same fence") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        let current = try await registry.grant(for: id, revision: 3)
        let obsolete = await registry.updatePermissions(pairID: id, revision: 2)
        XCTAssertNil(obsolete)
        XCTAssertTrue(current.isActive, "A delayed older update cannot suspend the newer grant")
        _ = await registry.revoke(id)
        _ = await registry.updatePermissions(pairID: id, revision: 4)
        do { _ = try await registry.grant(for: id, revision: 4); XCTFail("Permission updates never undo revocation") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .revoked) }
    }
    func testNewRevisionGrantInvalidatesOldTokenBeforeCleanupArrives() async throws {
        let registry = DirectRemoteGrantRegistry(), id = UUID()
        let first = try await registry.grant(for: id, revision: 1)
        let next = try await registry.grant(for: id, revision: 2)
        XCTAssertFalse(first.isActive)
        XCTAssertTrue(next.isActive)
        do { _ = try await registry.grant(for: id, revision: 1); XCTFail("The observed revision cannot regress") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
    }
    func testAttachmentWithWrongDigestCannotBecomeReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-vault-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = try DirectRemoteAttachmentVault(directory: directory)
        let pair = UUID(), session = UUID(), id = UUID().uuidString
        _ = try await vault.upload(["transfer_id": .string(id), "phase": .string("begin"), "name": .string("fixture.txt"), "mime": .string("text/plain"), "size": .number(1), "sha256": .string(String(repeating: "0", count: 64))], pairID: pair, sessionID: session)
        _ = try await vault.upload(["transfer_id": .string(id), "phase": .string("chunk"), "offset": .number(0), "data": .string(Data([1]).base64EncodedString())], pairID: pair, sessionID: session)
        do { _ = try await vault.upload(["transfer_id": .string(id), "phase": .string("finish")], pairID: pair, sessionID: session); XCTFail("Mismatched digest must fail") } catch { }
    }
}
