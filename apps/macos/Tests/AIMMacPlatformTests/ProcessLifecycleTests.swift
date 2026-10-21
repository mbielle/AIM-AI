import AIMAgentKit
import AIMMacPlatform
import Darwin
import XCTest

final class ProcessLifecycleTests: XCTestCase {
    func testPipedInputCanBeSentAndClosedForOneKnownProcess() async throws {
        let runner = MacProcessRunner()
        let id = UUID()
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/cat"),
            timeout: .seconds(5), acceptsStandardInput: true)
        let output = Task { () throws -> ProcessOutput in
            for try await event in runner.stream(command, id: id) {
                if case .completed(let result) = event { return result }
            }
            throw ProcessInputError.notRunning
        }
        let input = "Bonjour 🌍\n"
        let sent: Int
        do { sent = try await runner.send(input, to: id) }
        catch {
            let state = await output.result
            XCTFail("stdin send failed: \(error); process: \(state)")
            return
        }
        XCTAssertEqual(sent, input.utf8.count)
        try await runner.closeInput(to: id)
        let result = try await output.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, input)
        do {
            _ = try await runner.send("late", to: id)
            XCTFail("A completed handle must not accept input")
        } catch ProcessInputError.notRunning {}
    }

    func testDefaultProcessStdinRemainsClosed() async throws {
        let runner = MacProcessRunner()
        let result = try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/cat"),
            timeout: .seconds(3)))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        do {
            _ = try await runner.send("unexpected", to: UUID())
            XCTFail("An unrelated process cannot receive input")
        } catch ProcessInputError.notRunning {}
    }

    func testClosedChildStdinReturnsErrorWithoutKillingHost() async throws {
        let runner = MacProcessRunner()
        let id = UUID()
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "exec 0<&-; printf ready; sleep 0.5"],
            timeout: .seconds(3), acceptsStandardInput: true)
        let stream = runner.stream(command, id: id)
        let output = Task { () throws -> ProcessOutput in
            for try await event in stream {
                if case .completed(let result) = event { return result }
            }
            throw ProcessInputError.notRunning
        }
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await runner.send("after-close\n", to: id)
            XCTFail("Input after the child closes stdin must fail")
        } catch ProcessInputError.notRunning {}
        let result = try await output.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("ready"))
    }

    func testStreamingDeliversOutputBeforeCompletionAndPreservesFinalUnicode() async throws {
        let runner = MacProcessRunner()
        var sawEarly = false
        var sawQuietFlush = false
        var completed = false
        for try await event in runner.stream(Self.shell("printf first; sleep 0.01; printf '🌍'; printf error >&2; sleep 0.2; printf last")) {
            switch event {
            case .output(let snapshot):
                if snapshot.stdout == "first" { sawEarly = true }
                if snapshot.stdout == "first🌍" { sawQuietFlush = true }
            case .completed(let result):
                completed = true
                XCTAssertEqual(result.stdout, "first🌍last")
                XCTAssertEqual(result.stderr, "error")
                XCTAssertEqual(result.exitCode, 0)
            }
        }
        XCTAssertTrue(sawEarly)
        XCTAssertTrue(sawQuietFlush)
        XCTAssertTrue(completed)
    }

    func testStreamingTimeoutKeepsPartialOutputAndNeverReportsSuccess() async throws {
        let runner = MacProcessRunner()
        var partial = ""
        do {
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", "printf partial; sleep 5"], timeout: .milliseconds(200))
            for try await event in runner.stream(command) {
                switch event {
                case .output(let snapshot): partial = snapshot.stdout
                case .completed: XCTFail("Timed-out process cannot complete successfully")
                }
            }
            XCTFail("Expected timeout")
        } catch ProcessExecutionError.timedOut { }
        XCTAssertEqual(partial, "partial")
    }

    func testCancellingStreamKillsDescendants() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("stream-pids")
        let runner = MacProcessRunner()
        let task = Task {
            for try await _ in runner.stream(Self.stubborn(marker: marker, timeout: .seconds(5))) { }
        }
        defer { task.cancel() }
        let pids = try await readPIDs(marker)
        task.cancel()
        _ = try? await task.value
        await runner.terminateAll()
        try await assertStopped(pids)
    }

    func testFastConcurrentCommandsAndNonzeroExit() async throws {
        let runner = MacProcessRunner()
        try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0..<12 {
                group.addTask { try await runner.run(Self.shell("printf out; printf err >&2; exit 7")) }
            }
            for try await result in group {
                XCTAssertEqual(result.stdout, "out")
                XCTAssertEqual(result.stderr, "err")
                XCTAssertEqual(result.exitCode, 7)
            }
        }
    }

    func testCancellationKillsTermIgnoringGroup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pids")
        let runner = MacProcessRunner()
        let task = Task { try await runner.run(Self.stubborn(marker: marker, timeout: .seconds(5))) }
        defer { task.cancel() }
        let pids = try await readPIDs(marker)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not look successful") }
        catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        try await assertStopped(pids)
    }

    func testTimeoutKillsChildrenAndReportsTimeout() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pids")
        do {
            _ = try await MacProcessRunner().run(Self.stubborn(marker: marker, timeout: .milliseconds(400)))
            XCTFail("Timeout must not look successful")
        } catch ProcessExecutionError.timedOut { }
        try await assertStopped(try await readPIDs(marker))
    }

    func testLeaderExitCleansUpBackgroundChildAndPipe() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pids")
        let result = try await MacProcessRunner().run(Self.shell(
            "/bin/sleep 30 & printf '%s %s' \"$$\" \"$!\" > \"$1\"; printf done",
            arguments: [marker.path]
        ))
        XCTAssertEqual(result.stdout, "done")
        try await assertStopped(try await readPIDs(marker))
    }

    func testLargeOutputIsDrainedAndBounded() async throws {
        let output = try await MacProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=65536", "count=80"], timeout: .seconds(5)
        ))
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout.utf8.count, 4 * 1_024 * 1_024)
        XCTAssertTrue(output.wasTruncated)
        XCTAssertTrue(output.stderr.contains("records out"))
    }

    func testCancellingOneCommandDoesNotStopAnother() async throws {
        let runner = MacProcessRunner()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pids")
        let cancelled = Task { try await runner.run(Self.stubborn(marker: marker, timeout: .seconds(5))) }
        defer { cancelled.cancel() }
        let pids = try await readPIDs(marker)
        let survivor = Task { try await runner.run(Self.shell("/bin/sleep 0.4; printf survived")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let result = try await survivor.value
        XCTAssertEqual(result.stdout, "survived")
        XCTAssertEqual(result.exitCode, 0)
        try await assertStopped(pids)
    }

    func testInvalidExecutableDirectoryAndNULFailWithoutHanging() async throws {
        for command in [
            ProcessCommand(executable: URL(fileURLWithPath: "/does-not-exist-aim")),
            ProcessCommand(executable: URL(fileURLWithPath: "/bin/echo"), workingDirectory: URL(fileURLWithPath: "/does-not-exist-aim")),
            ProcessCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["a\0b"])
        ] {
            do { _ = try await MacProcessRunner().run(command); XCTFail("Expected invalid command to fail") }
            catch { }
        }
    }

    func testTerminateAllAndCancellationBeforeLaunch() async throws {
        let runner = MacProcessRunner()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pids")
        let task = Task { try await runner.run(Self.stubborn(marker: marker, timeout: .seconds(5))) }
        defer { task.cancel() }
        let pids = try await readPIDs(marker)
        await runner.terminateAll()
        try await assertStopped(pids)
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(Self.shell("exit 0"))
        }
        do { _ = try await cancelled.value; XCTFail("Expected pre-launch cancellation") } catch is CancellationError { }
    }

    private static func shell(_ script: String, arguments: [String] = []) -> ProcessCommand {
        ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "aim-test"] + arguments, timeout: .seconds(5))
    }
    private static func stubborn(marker: URL, timeout: Duration) -> ProcessCommand {
        var command = shell("trap '' TERM; /bin/sleep 30 & printf '%s %s' \"$$\" \"$!\" > \"$1\"; wait", arguments: [marker.path])
        command.timeout = timeout
        return command
    }
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("aim-process-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func readPIDs(_ marker: URL) async throws -> [Int32] {
        for _ in 0..<150 {
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                let pids = text.split(separator: " ").compactMap { Int32($0) }
                if pids.count == 2 { return pids }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Process test marker not written", code: 1)
    }
    private func assertStopped(_ pids: [Int32]) async throws {
        let leaderResult = kill(pids[0], 0)
        let leaderError = errno
        XCTAssertEqual(leaderResult, -1, "Leader must be reaped")
        if leaderResult == -1 {
            XCTAssertEqual(leaderError, ESRCH, "Leader inspection must confirm absence, not a permission error")
        }
        for pid in pids.dropFirst() {
            let state = try Self.processState(of: pid)
            XCTAssertTrue(state == nil || state == Int8(SZOMB), "Child \(pid) remains live: \(String(describing: state))")
        }
    }

    private static func processState(of pid: Int32) throws -> Int8? {
        // Query only the PID recorded by this test, without launching setuid ps.
        guard pid > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = name.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, UInt32(name.count), &info, &size, nil, 0)
        }
        guard result == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Cannot inspect test PID \(pid): \(String(cString: strerror(code)))"
            ])
        }
        guard size != 0 else { return nil }
        guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else {
            throw NSError(domain: "Process test inspection returned unexpected data", code: 1)
        }
        return info.kp_proc.p_stat
    }
}
