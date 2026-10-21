@testable import AIMMacPlatform
import Foundation
import XCTest

final class EmbeddedCuaDriverHostTests: XCTestCase {
    func testConcurrentStartSharesGenerationAndRestartInvalidatesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cua-driver")
        let script = """
            #!/bin/zsh
            if [[ "$1" == "--version" ]]; then
              print 'cua-driver 0.28.2'
              exit 0
            fi
            [[ "$1" == "serve" && "$CUA_DRIVER_EMBEDDED" == "1" && "$CUA_DRIVER_HOST_BUNDLE_ID" == "com.aimai.fixture" ]] || exit 9
            socket=''
            while (( $# > 0 )); do
              if [[ "$1" == "--socket" ]]; then shift; socket="$1"; break; fi
              shift
            done
            [[ -n "$socket" ]] || exit 10
            touch "$socket"
            trap 'rm -f "$socket"; exit 0' TERM INT
            while true; do sleep 1; done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = EmbeddedCuaDriverHost(executable: executable, hostBundleID: "com.aimai.fixture")
        async let first = host.start()
        async let second = host.start()
        let initial = try await first
        let other = try await second
        let current = await host.currentConnection()
        XCTAssertEqual(initial, other)
        XCTAssertEqual(current, initial)
        await host.stop()
        let stopped = await host.currentConnection()
        XCTAssertNil(stopped)
        let restarted = try await host.start()
        XCTAssertNotEqual(restarted.generation, initial.generation)
        await host.stop()
    }

    func testWrongVersionNeverStartsDaemon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("wrong-driver")
        try "#!/bin/zsh\nprint 'cua-driver 0.28.1'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = EmbeddedCuaDriverHost(executable: executable)
        do {
            _ = try await host.start()
            XCTFail("An unqualified driver must not launch")
        } catch CuaDriverHostError.wrongVersion {}
        let current = await host.currentConnection()
        XCTAssertNil(current)
    }

    func testAppShutdownWaitsForEmbeddedHelperCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cua-driver")
        let script = """
            #!/bin/zsh
            if [[ "$1" == "--version" ]]; then print 'cua-driver 0.28.2'; exit 0; fi
            socket=''
            while (( $# > 0 )); do
              if [[ "$1" == "--socket" ]]; then shift; socket="$1"; break; fi
              shift
            done
            touch "$socket"
            trap 'rm -f "$socket"; exit 0' TERM INT
            while true; do sleep 1; done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let supervisor = ProcessSupervisor()
        let host = EmbeddedCuaDriverHost(executable: executable,
            hostBundleID: "com.aimai.fixture", supervisor: supervisor)
        let connection = try await host.start()
        XCTAssertEqual(supervisor.activeCount, 1)
        supervisor.beginShutdown()
        await supervisor.waitForIdle()
        let current = await host.currentConnection()
        XCTAssertNil(current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: connection.socketPath))
    }

    func testHelperEnvironmentDisablesTelemetryAndKeepsOnlyNeutralVariables() {
        let environment = CuaDriverEnvironment.make(hostBundleID: "com.aimai.fixture", base: [
            "HOME": "/Users/example", "PATH": "/usr/bin", "OPENROUTER_API_KEY": "secret",
            "CUA_DRIVER_PERMISSION_MODE": "unrestricted", "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS": "1"])
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertNil(environment["OPENROUTER_API_KEY"])
        XCTAssertNil(environment["CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS"])
        XCTAssertEqual(environment["CUA_DRIVER_PERMISSION_MODE"], "standard")
        XCTAssertEqual(environment["CUA_DRIVER_EMBEDDED"], "1")
        XCTAssertEqual(environment["CUA_DRIVER_HOST_BUNDLE_ID"], "com.aimai.fixture")
        XCTAssertEqual(environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"], "0")
        XCTAssertEqual(environment["CUA_DRIVER_RS_UPDATE_CHECK"], "0")
        XCTAssertEqual(environment["CUA_DRIVER_RS_PERMISSIONS_GATE"], "0")
        let arguments = CuaDriverEnvironment.serveArguments(socketPath: "/tmp/s.sock", hostBundleID: "com.aimai.fixture")
        XCTAssertEqual(arguments.first, "serve")
        XCTAssertTrue(arguments.contains("--embedded"))
        XCTAssertTrue(arguments.contains("--parent-liveness-stdio"))
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals"))
        XCTAssertFalse(arguments.contains("unrestricted"))
    }

    func testLivenessPipeStaysOpenUntilHostStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cua-driver")
        let marker = directory.appendingPathComponent("stdin-closed")
        // The fake daemon mirrors --parent-liveness-stdio: it exits at stdin EOF.
        let script = """
            #!/bin/zsh
            if [[ "$1" == "--version" ]]; then print 'cua-driver 0.28.2'; exit 0; fi
            [[ "$CUA_DRIVER_RS_TELEMETRY_ENABLED" == "0" ]] || exit 11
            socket=''
            while (( $# > 0 )); do
              if [[ "$1" == "--socket" ]]; then shift; socket="$1"; break; fi
              shift
            done
            touch "$socket"
            cat > /dev/null
            touch "\(marker.path)"
            rm -f "$socket"
            exit 0
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = EmbeddedCuaDriverHost(executable: executable, hostBundleID: "com.aimai.fixture",
            supervisor: ProcessSupervisor())
        _ = try await host.start()
        // An inherited /dev/null would reach EOF at once and end the daemon.
        try await Task.sleep(for: .milliseconds(400))
        let running = await host.daemonProcessIdentifier()
        XCTAssertNotNil(running, "stdin must stay open while the host owns the daemon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await host.stop()
        let stopped = await host.daemonProcessIdentifier()
        XCTAssertNil(stopped)
    }
}
