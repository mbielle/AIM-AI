import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

final class MacCalendarToolTests: XCTestCase {
    func testInvalidCalendarArgumentsFailBeforeSystemPermissionRequest() async {
        let service = MacCalendarToolService()
        let cases: [(String, [String: String])] = [
            ("calendar_events", ["start_iso": "tomorrow", "end_iso": "2026-10-01T12:00:00Z"]),
            ("calendar_events", ["start_iso": "2026-10-02T12:00:00Z", "end_iso": "2026-10-01T12:00:00Z"]),
            ("calendar_events", ["start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-12-01T12:00:00Z"]),
            ("calendar_events", ["start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-02T12:00:00Z", "limit": "101"]),
            ("calendar_get", ["id": ""]),
            ("calendar_create", ["title": "", "start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-01T13:00:00Z"]),
            ("calendar_create", ["title": "Meeting", "start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-01T13:00:00Z", "all_day": "sometimes"]),
            ("calendar_create", ["title": "Holiday", "start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-02T12:00:00Z", "all_day": "true"]),
            ("calendar_create", ["title": "Meeting", "start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-01T13:00:00Z", "calendar_id": "a", "calendar_name": "b"]),
            ("calendar_update", ["id": "one", "expected_title": "Meeting", "expected_start_iso": "2026-10-01T12:00:00Z", "expected_end_iso": "2026-10-01T13:00:00Z"]),
            ("calendar_update", ["id": "one", "expected_title": "Meeting", "expected_start_iso": "2026-10-01T12:00:00Z", "expected_end_iso": "2026-10-01T13:00:00Z", "start_iso": "2026-10-02T12:00:00Z", "title": "New"]),
            ("calendar_update", ["id": "one", "expected_title": "Meeting", "expected_start_iso": "2026-10-01T12:00:00Z", "expected_end_iso": "2026-10-01T13:00:00Z", "notes": "New", "clear_notes": "true"]),
            ("calendar_delete", ["id": "one", "expected_title": "Meeting", "expected_start_iso": "bad", "expected_end_iso": "2026-10-01T13:00:00Z"])
        ]
        for (name, arguments) in cases {
            let result = await service.execute(ToolRequest(name: name, arguments: arguments,
                risk: ["calendar_create", "calendar_update", "calendar_delete"].contains(name) ? .computerAction : .computerRead))
            XCTAssertTrue(result.isError, "\(name): \(arguments)")
            XCTAssertTrue(result.content.contains("Invalid Calendar"), result.content)
            if ["calendar_create", "calendar_update", "calendar_delete"].contains(name) {
                XCTAssertEqual(result.actionOutcome, .suspectedAbsent)
            }
        }
    }

    func testCalendarOperationsBindToExactSystemApplicationScope() throws {
        let service = MacCalendarToolService()
        let read = try service.missionIntent(for: ToolRequest(name: "calendar_events",
            arguments: ["start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-02T12:00:00Z"],
            risk: .computerRead))
        XCTAssertEqual(read?.operation, .observe)
        XCTAssertEqual(read?.target, try MissionResource(kind: .application, identifier: "com.apple.iCal"))
        let create = try service.missionIntent(for: ToolRequest(name: "calendar_create",
            arguments: ["title": "Meeting", "start_iso": "2026-10-01T12:00:00Z", "end_iso": "2026-10-01T13:00:00Z"],
            risk: .computerAction))
        XCTAssertEqual(create?.operation, .edit)
        XCTAssertEqual(create?.target, read?.target)
        let get = try service.missionIntent(for: ToolRequest(name: "calendar_get",
            arguments: ["id": "one"], risk: .computerRead))
        XCTAssertEqual(get?.operation, .observe)
        let update = try service.missionIntent(for: ToolRequest(name: "calendar_update",
            arguments: ["id": "one", "expected_title": "Meeting",
                        "expected_start_iso": "2026-10-01T12:00:00Z",
                        "expected_end_iso": "2026-10-01T13:00:00Z", "title": "Changed"],
            risk: .computerAction))
        XCTAssertEqual(update?.operation, .edit)
        XCTAssertEqual(update?.target, read?.target)
        let delete = try service.missionIntent(for: ToolRequest(name: "calendar_delete",
            arguments: ["id": "one", "expected_title": "Meeting",
                        "expected_start_iso": "2026-10-01T12:00:00Z",
                        "expected_end_iso": "2026-10-01T13:00:00Z"], risk: .computerAction))
        XCTAssertEqual(delete?.operation, .permanentDelete)
        XCTAssertTrue(delete?.operation.requiresExactApproval == true)
        XCTAssertThrowsError(try service.missionIntent(for: ToolRequest(name: "calendar_create",
            arguments: ["title": "Meeting", "start_iso": "tomorrow", "end_iso": "later"],
            risk: .computerAction)))
    }
}
