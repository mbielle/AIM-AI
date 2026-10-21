import AIMCore
@testable import AIMMacPlatform
import Supabase
import XCTest

final class RemoteLegacySessionEncodingTests: XCTestCase {
    private func row(archive: Date? = nil) -> RemoteSessionRow {
        RemoteSessionRow(id: "session", machine_id: "machine", mode: "agent", title: "encrypted",
            workspace: nil, model_id: nil, approval_mode: nil, agent_system: nil, status: "idle",
            pending_approval: nil, phase: nil, silence: false, interrupted: false, run_started_at: nil,
            message_count: 0, updated_at: Date(timeIntervalSince1970: 1), last_synced_at: Date(timeIntervalSince1970: 2), archived_at: archive)
    }
    func testModernUnarchiveExplicitlyEncodesNull() throws {
        let data = try JSONEncoder().encode(row())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["archived_at"] is NSNull)
    }
    func testLegacyEncodingOmitsOnlyUnsupportedArchiveColumn() throws {
        let modern = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row())) as? [String: Any])
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteLegacySessionPayload(row: row()))) as? [String: Any])
        var expected = modern; expected.removeValue(forKey: "archived_at")
        XCTAssertTrue(NSDictionary(dictionary: expected).isEqual(to: legacy))
        XCTAssertNil(legacy["archived_at"])
    }
    func testCompletedSnapshotClearsPendingAndPhaseInModernAndLegacyUpsert() throws {
        // PostgREST merges only columns present in the encoded row. Omitting a nil
        // interaction leaves the earlier encrypted approval visible on the phone.
        let old: [String: Any] = ["pending_approval": "encrypted-old-approval", "phase": "Waiting for approval", "status": "waiting_approval"]
        for data in [try JSONEncoder().encode(row()),
                     try JSONEncoder().encode(RemoteLegacySessionPayload(row: row()))] {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(payload["pending_approval"] is NSNull)
            XCTAssertTrue(payload["phase"] is NSNull)
            let persisted = old.merging(payload) { _, updated in updated }
            XCTAssertTrue(persisted["pending_approval"] is NSNull)
            XCTAssertTrue(persisted["phase"] is NSNull)
            XCTAssertEqual(persisted["status"] as? String, "idle")
        }
    }
    func testPendingSnapshotKeepsEncryptedInteractionInsteadOfClearingIt() throws {
        let pending = RemoteSessionRow(id: "session", machine_id: "machine", mode: "agent", title: "encrypted",
            workspace: nil, model_id: nil, approval_mode: nil, agent_system: nil, status: "waiting_approval",
            pending_approval: "encrypted-current-approval", phase: "Waiting for approval", silence: false,
            interrupted: false, run_started_at: nil, message_count: 0,
            updated_at: Date(timeIntervalSince1970: 1), last_synced_at: Date(timeIntervalSince1970: 2), archived_at: nil)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
        XCTAssertEqual(payload["pending_approval"] as? String, "encrypted-current-approval")
        XCTAssertEqual(payload["phase"] as? String, "Waiting for approval")
    }
    func testFallbackRequiresExactSchemaRefusal() {
        let message = "Could not find the 'archived_at' column of 'remote_sessions' in the schema cache"
        XCTAssertTrue(SupabaseRemoteHostBackend.isMissingArchiveColumn(PostgrestError(code: "PGRST204", message: message)))
        for error in [PostgrestError(code: "42501", message: message),
                      PostgrestError(code: "PGRST204", message: message.replacingOccurrences(of: "archived_at", with: "phase")),
                      PostgrestError(code: "PGRST204", message: message.replacingOccurrences(of: "remote_sessions", with: "remote_messages")),
                      PostgrestError(code: "PGRST204", message: "network unavailable")] {
            XCTAssertFalse(SupabaseRemoteHostBackend.isMissingArchiveColumn(error))
        }
        XCTAssertFalse(SupabaseRemoteHostBackend.isMissingArchiveColumn(URLError(.timedOut)))
    }
    func testLegacyDoesNotSilentlyDiscardArchive() throws {
        XCTAssertThrowsError(try SupabaseRemoteHostBackend.legacySessions([row(archive: .now)])) { error in
            XCTAssertEqual(error as? RemoteHostError, .server("archive_schema_unavailable"))
        }
        XCTAssertEqual(try SupabaseRemoteHostBackend.legacySessions([row()]).count, 1)
    }
}
