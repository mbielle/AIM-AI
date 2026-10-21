import AIMAgentKit
import AIMMacPlatform
import XCTest

private actor NeverRun: ProcessRunning {
    var commands: [ProcessCommand] = []
    func run(_ command: ProcessCommand) -> ProcessOutput {
        commands.append(command)
        return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }
    func terminateAll() {}
}

final class ShellGuardrailTests: XCTestCase {
    func testCatastrophicCommandIsRefusedWithoutAskingOrRunning() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let runner = NeverRun(), broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "run_command", risk: .destructive, requiredArguments: ["command"],
                           executor: WorkspaceShellToolService(runner: runner))
        ], broker: broker, policy: .autoApprove, workspacePath: root)
        let result = await dispatcher.execute(id: "x", name: "run_command", arguments: ["command": "rm -rf ~/"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("refuses"))
        let asked = await broker.snapshot()
        XCTAssertTrue(asked.isEmpty, "no approval is requested")
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty, "nothing is run")
        await dispatcher.close()
    }

    func testSensitiveCommandShowsWarningsInItsApproval() async throws {
        let service = WorkspaceShellToolService(runner: NeverRun())
        let review = try await service.review(ToolRequest(name: "run_command",
            arguments: ["command": "git push --force origin main"], risk: .destructive, workspacePath: "/tmp/project"))
        XCTAssertTrue(review?.after.contains("Rewrites or deletes history on a remote") == true)
        XCTAssertEqual(review?.path, "Command in project")
        let plain = try await service.review(ToolRequest(name: "run_command", arguments: ["command": "swift build"],
                                                         risk: .destructive, workspacePath: "/tmp/project"))
        XCTAssertNil(plain)
    }

    func testDiscardingCommandSavesARecoveryPointFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-recovery-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = try git("init", "-q", "-b", "main")
        try "v1\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try git("add", "-A")
        _ = try git("-c", "user.name=F", "-c", "user.email=f@example.invalid", "commit", "-q", "-m", "init")
        try "unsaved work\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new file\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let result = await service.execute(ToolRequest(name: "run_command", arguments: ["command": "git reset --hard && git clean -fd"],
                                                       risk: .destructive, workspacePath: root.path))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Recovery point saved before running: refs/aim/recovery/"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "v1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))

        let reference = try XCTUnwrap(try git("for-each-ref", "--format=%(refname)", "refs/aim/recovery").split(separator: "\n").first)
        _ = try git("restore", "--source=\(reference)", "--worktree", "--", ".")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "unsaved work\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "new file\n")
    }
}
