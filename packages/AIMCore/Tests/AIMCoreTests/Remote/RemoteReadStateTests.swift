import Foundation
import XCTest
@testable import AIMCore

final class RemoteReadStateTests: XCTestCase {
    private let context = RemoteFieldContext(table: "remote_messages", column: "content", rowID: "fixture-message")

    func testMissingCurrentAndHistoricalKeysAreDifferentFromUnreadableEnvelope() throws {
        let sealed = try RemoteCrypto.encryptField("fixture", key: Data(repeating: 7, count: 32), version: 2, context: context)
        XCTAssertEqual(RemoteFieldReader.read(sealed, context: context, currentVersion: 2, keys: [:]).state, .keyPending)
        XCTAssertEqual(RemoteFieldReader.read(sealed, context: context, currentVersion: 3, keys: [:]).state, .historicalKeyMissing)
        XCTAssertEqual(RemoteFieldReader.read(sealed, context: context, currentVersion: 2, keys: [:], envelopeUnreadable: true).state, .envelopeUnreadable)
    }

    func testTitleDecryptionDoesNotProveMessageDecryptionOrAnotherVersion() throws {
        let key = Data(repeating: 7, count: 32)
        let titleContext = RemoteFieldContext(table: "remote_sessions", column: "title", rowID: "fixture-session")
        let title = try RemoteCrypto.encryptField("fixture title", key: key, version: 2, context: titleContext)
        let message = try RemoteCrypto.encryptField("fixture message", key: key, version: 1, context: context)
        XCTAssertEqual(RemoteFieldReader.read(title, context: titleContext, currentVersion: 2, keys: [2: key]).state, .readable)
        XCTAssertEqual(RemoteFieldReader.read(message, context: context, currentVersion: 2, keys: [2: key]).state, .historicalKeyMissing)
        XCTAssertEqual(RemoteFieldReader.read(title, context: context, currentVersion: 2, keys: [2: key]).state, .payloadUnreadable)
    }

    func testProtectedMachineNeverAcceptsPlaintextBecauseItsKeyIsMissing() {
        XCTAssertEqual(RemoteFieldReader.read("legacy", context: context, currentVersion: nil, keys: [:]).text, "legacy")
        XCTAssertEqual(RemoteFieldReader.read("plaintext", context: context, currentVersion: 1, keys: [:]).state, .payloadUnreadable)
        XCTAssertEqual(RemoteFieldReader.read("e1.bad.invalid", context: context, currentVersion: 1, keys: [:]).state, .invalidData)
    }

    func testReportCorrelatesVersionsAndPublicFingerprintsWithoutRawIdentifiersOrKeys() throws {
        let link = RemoteLinkDiagnostic(accountID: "private-account", deviceID: "private-device", machineID: "private-machine",
            localPublicKey: "public-key-local", registeredPublicKey: "public-key-server", currentKeyVersion: 2,
            envelopeVersions: [2, 1], openedVersions: [1], unreadableVersions: [2], readState: .envelopeUnreadable)
        let report = RemoteDiagnosticReport(formatVersion: 2, appVersion: "fixture", entries: [], links: [link])
        let json = String(decoding: try report.encodedData(), as: UTF8.self)
        for raw in ["private-account", "private-device", "private-machine", "public-key-local", "public-key-server"] { XCTAssertFalse(json.contains(raw)) }
        XCTAssertNotEqual(link.localPublicKeyFingerprint, link.registeredPublicKeyFingerprint)
        XCTAssertEqual(link.envelopeVersions, [1, 2])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"formatVersion":1,"generatedAt":"2026-10-05T12:00:00Z","appVersion":"fixture","entries":[]}"#.utf8)
        XCTAssertNil(try decoder.decode(RemoteDiagnosticReport.self, from: legacy).links)
    }
}
