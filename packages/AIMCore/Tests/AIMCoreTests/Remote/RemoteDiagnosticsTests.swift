import Foundation
import XCTest
@testable import AIMCore

final class RemoteDiagnosticsTests: XCTestCase {
    func testKnownBridgeFailuresKeepSpecificSafeCodes() {
        XCTAssertEqual(RemoteCommandErrorCode.classify("timeout"), .bridgeUnresponsive)
        XCTAssertEqual(RemoteCommandErrorCode.classify("charge_illisible"), .unreadablePayload)
        XCTAssertEqual(RemoteCommandErrorCode.classify("commande_non_prise_en_charge"), .unsupportedCommand)
        XCTAssertEqual(RemoteCommandErrorCode.classify("unlock_required"), .unlockRequired)
        XCTAssertEqual(RemoteCommandErrorCode.classify("device_not_paired"), .deviceNotPaired)
    }

    func testDiagnosticIdentifiersAreStableHashesRatherThanTransportIdentifiers() {
        let raw = "98abcf58-23ad-402b-95ce-user@example.com"
        let identifier = RemoteDiagnosticPrivacy.identifier(raw)
        XCTAssertEqual(identifier, RemoteDiagnosticPrivacy.identifier(raw))
        XCTAssertEqual(identifier.count, 16)
        XCTAssertFalse(identifier.contains("example"))
        XCTAssertFalse(identifier.contains("98ab"))
    }

    func testReportContainsOnlyFolderBasenameAndSafeServerCode() throws {
        let entry = RemoteDiagnosticEntry(
            commandIdentifier: "abc123",
            machineIdentifier: "def456",
            type: "list_folders",
            stage: .failed,
            status: "error",
            durationMilliseconds: 25_001,
            errorCode: .bridgeUnresponsive,
            serverCode: "timeout\nsecret@example.com",
            pathBasename: "/Users/example/Developer/AIM/private-project"
        )
        let data = try RemoteDiagnosticReport(appVersion: "1.2.3", entries: [entry]).encodedData()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("private-project"))
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("secret@example.com"))
        XCTAssertTrue(json.contains("bridge_unresponsive"))
    }

    func testUnlockTokenUsesServerWireFormatAndExpiry() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let value = RemoteUnlockToken(token: "opaque", expiresAt: date, method: "pin")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RemoteUnlockToken.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.value, "opaque")
    }

    func testUnlockTokenAcceptsSupabaseFractionalSecondExpiry() throws {
        let data = Data(#"{"token":"opaque","expiresAt":"2026-09-21T12:34:56.789Z","method":"pin"}"#.utf8)

        let decoded = try JSONDecoder().decode(RemoteUnlockToken.self, from: data)

        XCTAssertEqual(decoded.token, "opaque")
        XCTAssertGreaterThan(decoded.expiresAt.timeIntervalSince1970, 0)
        XCTAssertEqual(decoded.method, "pin")
    }

    func testFolderSnapshotDetectsStalenessWithoutDiscardingFolders() {
        let loaded = Date(timeIntervalSince1970: 1_000)
        let snapshot = RemoteFolderSnapshot(
            machineID: "machine",
            path: nil,
            folders: [.init(path: "/workspace", name: "workspace")],
            loadedAt: loaded,
            isFromCache: true,
            errorCode: .bridgeUnresponsive
        )
        XCTAssertFalse(snapshot.isStale(at: loaded.addingTimeInterval(299)))
        XCTAssertTrue(snapshot.isStale(at: loaded.addingTimeInterval(301)))
        XCTAssertEqual(snapshot.folders.first?.name, "workspace")
    }

    func testRemoteCommandRPCAlwaysIncludesNullableSessionAndUnlockToken() throws {
        let parameters = RemoteCommandParameters(
            deviceID: "device",
            deviceSecret: "secret",
            commandID: "command",
            machineID: "machine",
            sessionID: nil,
            type: "list_folders",
            payload: .object([:]),
            unlockToken: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any]
        )
        XCTAssertEqual(object["p_device_id"] as? String, "device")
        XCTAssertEqual(object["p_device_secret"] as? String, "secret")
        XCTAssertEqual(object["p_command_id"] as? String, "command")
        XCTAssertEqual(object["p_machine_id"] as? String, "machine")
        XCTAssertEqual(object["p_type"] as? String, "list_folders")
        XCTAssertTrue(object["p_session_id"] is NSNull)
        XCTAssertTrue(object["p_unlock_token"] is NSNull)
        XCTAssertTrue(object["p_mode"] is NSNull)
        XCTAssertNotNil(object["p_payload"])
    }

    func testRemoteCommandRPCIncludesUnlockTokenWhenPresent() throws {
        let parameters = RemoteCommandParameters(
            deviceID: "device",
            deviceSecret: "secret",
            commandID: "command",
            machineID: "machine",
            sessionID: "session",
            type: "user_message",
            payload: .object(["content": .string("redacted")]),
            unlockToken: "unlock-token",
            mode: .code
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any]
        )
        XCTAssertEqual(object["p_session_id"] as? String, "session")
        XCTAssertEqual(object["p_unlock_token"] as? String, "unlock-token")
        XCTAssertEqual(object["p_mode"] as? String, "code")
    }
}
