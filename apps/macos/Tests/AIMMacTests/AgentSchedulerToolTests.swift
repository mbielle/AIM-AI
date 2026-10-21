@testable import AIMAgentRuntime
@testable import AIMMac
import AIMAgentKit
import AIMApplication
import XCTest

final class AgentSchedulerToolTests: XCTestCase {
    func testScheduleArgumentsAndInheritedScope() async throws {
        XCTAssertEqual(try AgentSchedulerToolService.schedule(["schedule": "daily", "time": "07:45"]), .daily(hour: 7, minute: 45))
        XCTAssertEqual(try AgentSchedulerToolService.schedule(["schedule": "weekly", "weekday": "2", "time": "09:00"]),
                       .weekly(weekday: 2, hour: 9, minute: 0))
        XCTAssertEqual(try AgentSchedulerToolService.schedule(["schedule": "interval", "interval_minutes": "30"]),
                       .interval(seconds: 1_800))
        XCTAssertThrowsError(try AgentSchedulerToolService.schedule(["schedule": "cron", "time": "x"]))
        XCTAssertNil(try AgentSchedulerToolService.schedule([:]))

        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Plan", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let missions = SQLiteAgentMissionRepository(database: database)
        let mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Organize downloads")
        let rule = try MissionAuthorizationRule(resource: MissionResource(kind: .directory, identifier: "/tmp/inbox"),
                                                operations: [.observe, .edit])
        _ = try await missions.replaceAuthorization(missionID: mission.id, expectedRevision: nil, rules: [rule])
        let repository = SQLiteSchedulerRepository(database: database)
        let service = AgentSchedulerToolService(repository: repository, missions: missions, conversationID: chat.id,
            provider: .openRouter, modelID: "anthropic/claude-sonnet-5.5", workspacePath: "/tmp/inbox",
            allowEdits: false, allowCommands: false)
        let result = await service.execute(ToolRequest(name: "schedule_task", arguments: [
            "title": "Tidy", "prompt": "Sort new files", "schedule": "daily", "time": "08:00",
            "allow_edits": "true", "max_spend_usd": "0.40"], risk: .missionDefinition))
        XCTAssertFalse(result.isError, result.content)
        let tasks = try await repository.list()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.spec?.scope, [rule], "The task inherits exactly the mission's approved scope")
        XCTAssertEqual(task.spec?.allowEdits, false, "A run that could not edit cannot schedule edits")
        XCTAssertEqual(task.spec?.maxSpendUSD, "0.40")
        XCTAssertNotNil(task.nextRunAt)
    }
}
