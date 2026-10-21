@testable import AIMAgentRuntime
import AIMMacPlatform
import XCTest
@testable import AIMMac

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testManualForegroundServerKeepsRunningUntilStopped() async throws {
        let session = TerminalSession(terminal: MacPTYTerminal(supervisor: ProcessSupervisor()))
        session.command = "printf '\\163\\145\\162\\166\\145\\162\\055\\162\\145\\141\\144\\171'; sleep 30"
        session.run(workspacePath: FileManager.default.temporaryDirectory.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !session.output.contains("server-ready") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.output.contains("server-ready"))
        session.cancel()
        while session.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.output.contains("[stopped]"))
    }

    func testWorkspaceChangeDiscardsLateOutputAndClearsHistory() async throws {
        let session = TerminalSession(terminal: MacPTYTerminal(supervisor: ProcessSupervisor()))
        session.command = "printf old-workspace-marker; sleep 2; printf late-marker"
        session.run(workspacePath: FileManager.default.temporaryDirectory.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !session.output.contains("old-workspace-marker") && ContinuousClock.now < deadline {
            // Wait for at least one worker update, not just the echoed command.
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.output.contains("old-workspace-marker"))
        session.resetForWorkspace()
        XCTAssertTrue(session.history.commands.isEmpty)
        XCTAssertEqual(session.command, "")
        while session.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.output, TerminalSession.introduction)
    }

    func testHistoryRecallDoesNotRunAndOutputCanBeCleared() async throws {
        let session = TerminalSession(terminal: MacPTYTerminal(supervisor: ProcessSupervisor()))
        session.command = "printf fixture"
        session.run(workspacePath: FileManager.default.temporaryDirectory.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !session.output.contains("fixture") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(session.isRunning)
        session.command = "unsent"
        XCTAssertTrue(session.previousCommand())
        XCTAssertEqual(session.command, "printf fixture")
        XCTAssertTrue(session.nextCommand())
        XCTAssertEqual(session.command, "unsent")
        session.cancel()
        while (session.isRunning || session.isStopping) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.isRunning)
        session.clearOutput()
        XCTAssertEqual(session.output, TerminalSession.introduction)
    }

    func testPanelKeepsShellDirectoryAcrossSeparateSubmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-terminal-ui-\(UUID())")
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(terminal: MacPTYTerminal(supervisor: ProcessSupervisor()))
        session.command = "cd child"
        session.run(workspacePath: root.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !session.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(session.isRunning)
        session.command = "pwd"
        session.run(workspacePath: root.path)
        while !session.output.contains(child.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.output.contains(child.path), session.output)
        XCTAssertEqual(session.history.commands, ["cd child", "pwd"])
        session.command = ": private-value"
        session.run(workspacePath: root.path, privateInput: true)
        XCTAssertEqual(session.history.commands, ["cd child", "pwd"])
        session.cancel()
    }
}
