import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

final class MissionHostCheckRunnerTests: XCTestCase {
    func testCommandCheckUsesExitStatusAndOutputWithoutShell() async throws {
        let runner = MissionHostCheckRunner()
        let workspace = FileManager.default.temporaryDirectory.path
        let passes = try await runner.observe(MissionHostCheck(kind: .command, executable: "/bin/echo",
            arguments: ["build ok; rm -rf /"], requiredText: "build ok; rm -rf /"), workspacePath: workspace)
        XCTAssertTrue(passes.satisfied, "Arguments are passed literally, never to a shell")
        let wrongExit = try await runner.observe(MissionHostCheck(kind: .command, executable: "/usr/bin/false"),
            workspacePath: workspace)
        XCTAssertFalse(wrongExit.satisfied)
        let missingText = try await runner.observe(MissionHostCheck(kind: .command, executable: "/bin/echo",
            arguments: ["hello"], requiredText: "goodbye"), workspacePath: workspace)
        XCTAssertFalse(missingText.satisfied)
        let slow = try await runner.observe(MissionHostCheck(kind: .command, executable: "/bin/sleep",
            arguments: ["5"], timeoutSeconds: 1), workspacePath: workspace)
        XCTAssertFalse(slow.satisfied)
    }

    func testDefinitionResolvesBareProgramsAndRejectsUnknownKinds() throws {
        let check = try AgentMissionEvidenceToolService.hostCheck(["kind": "command", "command": "[\"true\"]"])
        XCTAssertEqual(check.executable, "/usr/bin/true")
        XCTAssertThrowsError(try AgentMissionEvidenceToolService.hostCheck(["kind": "shell", "command": "[\"true\"]"]))
        XCTAssertThrowsError(try AgentMissionEvidenceToolService.hostCheck(["kind": "command", "command": "true"]))
    }
}
