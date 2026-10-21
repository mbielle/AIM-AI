import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

final class MacRemindersToolTests: XCTestCase {
    func testInvalidReminderArgumentsFailBeforeAnySystemPermissionRequest() async {
        let service = MacRemindersToolService()
        let cases: [(String, [String: String])] = [
            ("reminders_create", ["title": ""]),
            ("reminders_create", ["title": "Task", "due_iso": "tomorrow"]),
            ("reminders_create", ["title": "Task", "list_id": "one", "list_name": "Two"]),
            ("reminders_list", ["limit": "101"]),
            ("reminders_list", ["include_completed": "sometimes"]),
            ("reminders_list", ["list_id": "one", "list_name": "Two"]),
            ("reminders_get", ["id": ""]),
            ("reminders_complete", ["id": "one", "completed": "sometimes"]),
            ("reminders_update", ["id": "one", "expected_title": "Task"]),
            ("reminders_update", ["id": "one", "expected_title": "Task", "clear_due": "sometimes"]),
            ("reminders_update", ["id": "one", "expected_title": "Task", "notes": "Text", "clear_notes": "true"]),
            ("reminders_delete", ["id": "one"])
        ]
        for (name, arguments) in cases {
            let result = await service.execute(ToolRequest(name: name, arguments: arguments,
                risk: ["reminders_create", "reminders_update", "reminders_complete", "reminders_delete"].contains(name) ? .computerAction : .computerRead))
            XCTAssertTrue(result.isError, "\(name): \(arguments)")
            XCTAssertTrue(result.content.contains("Invalid reminder"), "\(name): \(result.content)")
            if ["reminders_create", "reminders_update", "reminders_complete", "reminders_delete"].contains(name) {
                XCTAssertEqual(result.actionOutcome, .suspectedAbsent)
            }
        }
    }

    func testReminderOperationsBindToExactSystemApplicationScope() throws {
        let service = MacRemindersToolService()
        let lists = try service.missionIntent(for: ToolRequest(name: "reminders_lists",
            arguments: [:], risk: .computerRead))
        XCTAssertEqual(lists?.operation, .observe)
        XCTAssertEqual(lists?.target, try MissionResource(kind: .application,
            identifier: "com.apple.reminders"))
        let create = try service.missionIntent(for: ToolRequest(name: "reminders_create",
            arguments: ["title": "Task"], risk: .computerAction))
        XCTAssertEqual(create?.operation, .edit)
        XCTAssertEqual(create?.target, lists?.target)
        let complete = try service.missionIntent(for: ToolRequest(name: "reminders_complete",
            arguments: ["id": "one", "completed": "true"], risk: .computerAction))
        XCTAssertEqual(complete?.operation, .edit)
        XCTAssertEqual(complete?.target, lists?.target)
        let update = try service.missionIntent(for: ToolRequest(name: "reminders_update",
            arguments: ["id": "one", "expected_title": "Task", "title": "Changed"], risk: .computerAction))
        XCTAssertEqual(update?.operation, .edit)
        XCTAssertEqual(update?.target, lists?.target)
        let delete = try service.missionIntent(for: ToolRequest(name: "reminders_delete",
            arguments: ["id": "one", "expected_title": "Task"], risk: .computerAction))
        XCTAssertEqual(delete?.operation, .permanentDelete)
        XCTAssertTrue(delete?.operation.requiresExactApproval == true)
        XCTAssertThrowsError(try service.missionIntent(for: ToolRequest(name: "reminders_create",
            arguments: ["title": "Task", "due_iso": "later"], risk: .computerAction)))
    }
}
