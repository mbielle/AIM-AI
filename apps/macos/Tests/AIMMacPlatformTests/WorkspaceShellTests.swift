import AIMAgentKit
import AIMMacPlatform
import XCTest

private actor ShellRecorder: ProcessRunning {
    var commands: [ProcessCommand] = []
    func run(_ command: ProcessCommand) -> ProcessOutput {
        commands.append(command)
        return ProcessOutput(stdout: "fixture output", stderr: "fixture error", exitCode: 7)
    }
    func terminateAll() {}
}

private actor WaitingShell: ProcessRunning {
    var started = false
    var cancelled = false
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
    }
    func terminateAll() {}
}

final class WorkspaceShellTests: XCTestCase {
    func testOutputPagesKeepUnicodeScalarsAndExposeBinaryBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = String(repeating: "x", count: 16_383) + "🌍done"
        try Data(expected.utf8).write(to: directory.appendingPathComponent("unicode.txt"))
        let binary = Data([0xff, 0x00, 0x80, 0x0a])
        try binary.write(to: directory.appendingPathComponent("binary.dat"))
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let started = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "cat unicode.txt; cat binary.dat >&2"],
            risk: .destructive, workspacePath: directory.path))
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        var state = "running"
        var version = "0"
        for _ in 0..<10 where state == "running" {
            let result = await service.execute(ToolRequest(name: "read_command",
                arguments: ["handle": handle, "after_version": version, "wait_ms": "5000"],
                risk: .readOnly, workspacePath: directory.path))
            state = result.metadata["process_state"] ?? "unknown"
            version = result.metadata["process_version"] ?? version
        }
        XCTAssertEqual(state, "completed")
        let first = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle], risk: .readOnly, workspacePath: directory.path))
        let firstReceipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.content.utf8)) as? [String: Any])
        XCTAssertEqual(firstReceipt["stdoutChunk"] as? String, String(repeating: "x", count: 16_383))
        XCTAssertNil(firstReceipt["stdoutChunkBase64"] as? String)
        XCTAssertEqual(firstReceipt["nextStdoutOffset"] as? Int, 16_383)
        XCTAssertEqual(firstReceipt["stderrChunkBase64"] as? String, binary.base64EncodedString())
        let second = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle, "stdout_offset": "16383", "stderr_offset": String(binary.count)],
            risk: .readOnly, workspacePath: directory.path))
        let secondReceipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.content.utf8)) as? [String: Any])
        XCTAssertEqual(secondReceipt["stdoutChunk"] as? String, "🌍done")
        XCTAssertEqual(secondReceipt["nextStdoutOffset"] as? Int, expected.utf8.count)
        XCTAssertEqual(secondReceipt["hasMore"] as? Bool, false)
        await service.closeSession()
    }

    func testOutputPagesCoverCompleteStreamDespiteCoalescedSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = String(repeating: "x", count: 40_000)
        try expected.write(to: directory.appendingPathComponent("output.txt"), atomically: true, encoding: .utf8)
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let started = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "cat output.txt"], risk: .destructive, workspacePath: directory.path))
        XCTAssertFalse(started.isError)
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        var state = "running"
        var version = "0"
        for _ in 0..<10 where state == "running" {
            let result = await service.execute(ToolRequest(name: "read_command",
                arguments: ["handle": handle, "after_version": version, "wait_ms": "5000"],
                risk: .readOnly, workspacePath: directory.path))
            state = result.metadata["process_state"] ?? "unknown"
            version = result.metadata["process_version"] ?? version
        }
        XCTAssertEqual(state, "completed")
        var offset = 0
        var assembled = ""
        for _ in 0..<10 {
            let result = await service.execute(ToolRequest(name: "read_command",
                arguments: ["handle": handle, "stdout_offset": String(offset)],
                risk: .readOnly, workspacePath: directory.path))
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            assembled += receipt["stdoutChunk"] as? String ?? ""
            offset = try XCTUnwrap(receipt["nextStdoutOffset"] as? Int)
            XCTAssertEqual(receipt["outputLimitReached"] as? Bool, false)
            XCTAssertEqual(receipt["outputStorageError"] as? Bool, false)
            if receipt["hasMore"] as? Bool == false { break }
        }
        XCTAssertEqual(offset, expected.utf8.count)
        XCTAssertEqual(assembled, expected)
        await service.closeSession()
    }

    func testBackgroundCommandAcceptsApprovedInputAndEOF() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let started = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "cat", "allow_stdin": "true"], risk: .destructive, workspacePath: root))
        XCTAssertFalse(started.isError)
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        let oversized = await service.execute(ToolRequest(name: "write_command",
            arguments: ["handle": handle, "text": String(repeating: "x", count: 16_385)],
            risk: .destructive, workspacePath: root))
        XCTAssertTrue(oversized.isError)
        XCTAssertEqual(oversized.metadata["input_bytes_accepted"], "0")
        let sent = await service.execute(ToolRequest(name: "write_command",
            arguments: ["handle": handle, "text": "Bonjour 🌍\n"],
            risk: .destructive, workspacePath: root))
        XCTAssertFalse(sent.isError)
        XCTAssertEqual(sent.metadata["input_bytes_accepted"], String("Bonjour 🌍\n".utf8.count))
        let closed = await service.execute(ToolRequest(name: "close_command_input",
            arguments: ["handle": handle], risk: .destructive, workspacePath: root))
        XCTAssertFalse(closed.isError)
        var latest = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle, "after_version": "0", "wait_ms": "5000"],
            risk: .readOnly, workspacePath: root))
        for _ in 0..<5 where latest.metadata["process_state"] == "running" {
            latest = await service.execute(ToolRequest(name: "read_command",
                arguments: ["handle": handle,
                            "after_version": latest.metadata["process_version"] ?? "0",
                            "wait_ms": "5000"], risk: .readOnly, workspacePath: root))
        }
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(latest.content.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["stdoutChunk"] as? String, "Bonjour 🌍\n")
        XCTAssertEqual(receipt["stdinPipeOpen"] as? Bool, false)
        XCTAssertEqual(receipt["exitCode"] as? Int, 0)
        let repeatClose = await service.execute(ToolRequest(name: "close_command_input",
            arguments: ["handle": handle], risk: .destructive, workspacePath: root))
        XCTAssertTrue(repeatClose.isError)
        let wrongHandle = await service.execute(ToolRequest(name: "write_command",
            arguments: ["handle": UUID().uuidString, "text": "wrong\n"],
            risk: .destructive, workspacePath: root))
        XCTAssertTrue(wrongHandle.isError)
        await service.closeSession()
    }

    func testCommandInputNeedsExactApprovalEvenInAutoMode() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "start_command", risk: .destructive,
                requiredArguments: ["command"], optionalArguments: ["allow_stdin"],
                argumentKinds: ["allow_stdin": .boolean], executor: service),
            RegisteredTool(name: "write_command", risk: .destructive,
                requiredArguments: ["handle", "text"], executor: service),
            RegisteredTool(name: "close_command_input", risk: .destructive,
                requiredArguments: ["handle"], executor: service)
        ], broker: broker, policy: .autoApprove, workspacePath: root)
        let start = Task { await dispatcher.execute(id: "start-input", name: "start_command",
            arguments: ["command": "cat", "allow_stdin": "true"]) }
        // Auto's safety check lets a plain `cat` start; input sent to it is still approved exactly.
        let started = await start.value
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        let write = Task { await dispatcher.execute(id: "write-input", name: "write_command",
            arguments: ["handle": handle, "text": "fixture\n"]) }
        let writeApproval = try await pending(broker)
        XCTAssertEqual(writeApproval.arguments["text"], "fixture\n")
        await broker.decide(id: writeApproval.id, sessionID: writeApproval.sessionID, decision: .deny)
        let denied = await write.value
        XCTAssertTrue(denied.isError)
        let close = Task { await dispatcher.execute(id: "close-input", name: "close_command_input",
            arguments: ["handle": handle]) }
        let closeApproval = try await pending(broker)
        XCTAssertEqual(closeApproval.arguments["handle"], handle)
        await broker.decide(id: closeApproval.id, sessionID: closeApproval.sessionID, decision: .allowOnce)
        let closeResult = await close.value
        XCTAssertFalse(closeResult.isError)
        await dispatcher.close()
    }

    func testBackgroundHandleReportsOutputAndCompletionWithinOwningRun() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let started = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "printf first; sleep 0.2; printf second"],
            risk: .destructive, workspacePath: root))
        XCTAssertFalse(started.isError)
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        let first = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle, "after_version": "0", "wait_ms": "5000"],
            risk: .readOnly, workspacePath: root))
        XCTAssertFalse(first.isError)
        XCTAssertTrue(first.content.contains("first"))
        var latest = first
        for _ in 0..<5 where latest.metadata["process_state"] == "running" {
            let version = try XCTUnwrap(latest.metadata["process_version"])
            latest = await service.execute(ToolRequest(name: "read_command",
                arguments: ["handle": handle, "after_version": version, "wait_ms": "5000"],
                risk: .readOnly, workspacePath: root))
        }
        let final = latest
        XCTAssertFalse(final.isError)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(final.content.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["stdoutChunk"] as? String, "firstsecond")
        XCTAssertEqual(receipt["state"] as? String, "completed")
        XCTAssertEqual(final.metadata["process_state"], "completed")
        XCTAssertEqual(receipt["exitCode"] as? Int, 0)

        let otherRun = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let inaccessible = await otherRun.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle], risk: .readOnly, workspacePath: root))
        XCTAssertTrue(inaccessible.isError)
        await otherRun.closeSession()
        await service.closeSession()
    }

    func testClosingRunStopsItsBackgroundProcessBeforeSideEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("should-not-exist")
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let command = "sleep 0.4; touch should-not-exist"
        let started = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": command], risk: .destructive, workspacePath: directory.path))
        XCTAssertFalse(started.isError)
        await service.closeSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
            "The process must not survive after the run closes")
        let handle = try XCTUnwrap(started.metadata["process_handle"])
        let rejected = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": handle], risk: .readOnly, workspacePath: directory.path))
        XCTAssertTrue(rejected.isError)
    }

    func testDispatcherCloseStopsReturnedProcessHandle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "start_command", risk: .destructive,
                requiredArguments: ["command"], executor: service),
            RegisteredTool(name: "read_command", risk: .readOnly,
                requiredArguments: ["handle"], executor: service)
        ], broker: broker, policy: .autoApprove, workspacePath: directory.path)
        let started = Task { await dispatcher.execute(id: "start", name: "start_command",
            arguments: ["command": "sleep 0.4; touch should-not-exist"]) }
        // Safe inside the folder, so Auto starts it without a card.
        let receipt = await started.value
        XCTAssertFalse(receipt.isError)
        await dispatcher.close()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("should-not-exist").path))
        let denied = await dispatcher.execute(id: "after-close", name: "read_command",
            arguments: ["handle": receipt.metadata["process_handle"] ?? ""])
        XCTAssertTrue(denied.isError)
    }

    func testStopCommandReturnsStoppedStateAndLeavesOtherHandlesAlone() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let long = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "sleep 5"], risk: .destructive, workspacePath: root))
        let short = await service.execute(ToolRequest(name: "start_command",
            arguments: ["command": "printf unaffected"], risk: .destructive, workspacePath: root))
        let longID = try XCTUnwrap(long.metadata["process_handle"])
        let shortID = try XCTUnwrap(short.metadata["process_handle"])
        let stopped = await service.execute(ToolRequest(name: "stop_command",
            arguments: ["handle": longID], risk: .localMutation, workspacePath: root))
        XCTAssertEqual(stopped.metadata["process_state"], "stopped")
        let other = await service.execute(ToolRequest(name: "read_command",
            arguments: ["handle": shortID, "after_version": "0", "wait_ms": "5000"],
            risk: .readOnly, workspacePath: root))
        XCTAssertTrue(other.content.contains("unaffected"))
        await service.closeSession()
    }

    func testCancelAwaitsRunningCommandAndBlocksFurtherExecution() async throws {
        let runner = WaitingShell(), service = WorkspaceShellToolService(runner: runner)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let request = ToolRequest(name: "run_command", arguments: ["command": "fixture"], risk: .destructive, workspacePath: root)
        let task = Task { await service.execute(request) }
        for _ in 0..<200 {
            if await runner.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await runner.started
        XCTAssertTrue(started)
        await service.cancel(requestID: request.id)
        let cancelled = await runner.cancelled
        XCTAssertTrue(cancelled)
        let result = await task.value
        XCTAssertTrue(result.isError)
    }

    private func pending(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let value = await broker.snapshot().first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProcessExecutionError.invalidArgument
    }

    func testShellAsksInAutoWhenTheSafetyCheckCannotVouchForIt() async throws {
        let runner = ShellRecorder(), broker = ToolApprovalBroker()
        let service = WorkspaceShellToolService(runner: runner)
        XCTAssertEqual(service.risk(for: "start_command", arguments: ["command": "pwd"]), .destructive)
        XCTAssertEqual(service.risk(for: "read_command", arguments: ["handle": UUID().uuidString]), .readOnly)
        XCTAssertEqual(service.risk(for: "stop_command", arguments: ["handle": UUID().uuidString]), .localMutation)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "run_command", risk: .destructive, requiredArguments: ["command"], executor: service)], broker: broker, policy: .autoApprove, workspacePath: root)
        for (id, decision) in [("deny", ApprovalDecision.deny), ("run", .allowOnce)] {
            let task = Task { await dispatcher.execute(id: id, name: "run_command", arguments: ["command": "fixture-tool --run"]) }
            let approval = try await pending(broker)
            XCTAssertEqual(approval.arguments["command"], "fixture-tool --run")
            XCTAssertEqual(approval.workspacePath, root)
            XCTAssertFalse(approval.allowsSessionDecision)
            let before = await runner.commands
            XCTAssertTrue(before.isEmpty)
            await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: decision)
            let result = await task.value
            XCTAssertTrue(result.isError)
            if decision == .allowOnce { XCTAssertTrue(result.content.contains("Exit code: 7")) }
        }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["-f", "-c", "fixture-tool --run"])
        XCTAssertFalse(command.inheritsEnvironment)
        XCTAssertNil(command.timeout)
        XCTAssertEqual(command.workingDirectory?.path, root)
        XCTAssertTrue(Set(command.environment.keys).isSubset(of: ["PATH", "TERM", "NO_COLOR", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"]))
        await dispatcher.close()
    }

    func testCommandExecutionAndClosedServiceRejectsFurtherRuns() async throws {
        let service = WorkspaceShellToolService(runner: MacProcessRunner(supervisor: ProcessSupervisor()))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let result = await service.execute(ToolRequest(name: "run_command", arguments: ["command": "printf 'local command fixture'"], risk: .destructive, workspacePath: root))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("local command fixture"))
        await service.cancel(requestID: "closed")
        let rejected = await service.execute(ToolRequest(name: "run_command", arguments: ["command": "printf unexpected"], risk: .destructive, workspacePath: root))
        XCTAssertTrue(rejected.isError)
    }

    func testExplicitProcessEnvironmentDoesNotInheritParentVariables() async throws {
        let runner = MacProcessRunner(supervisor: ProcessSupervisor())
        let result = try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["AIM_FIXTURE": "isolated"], timeout: .seconds(5), inheritsEnvironment: false))
        XCTAssertEqual(result.stdout, "AIM_FIXTURE=isolated\n")
    }

    func testAgentShellFindsPersonalToolchainsThatExist() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cargo/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/v9.0.0/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = WorkspaceShellToolService.toolPath(home: home.path).split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains(home.path + "/.cargo/bin"))
        XCTAssertTrue(path.contains(home.path + "/.nvm/versions/node/v22.1.0/bin"), "the newest nvm Node")
        XCTAssertFalse(path.contains(home.path + "/.bun/bin"), "folders that do not exist are left out")
        XCTAssertEqual(path.suffix(4), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }
}
