import AIMCore
import AIMApplication
import Darwin
import Foundation

/// One environment for every helper launch (daemon, MCP proxy, version probe).
/// AIM promises no telemetry; the pinned driver enables both product telemetry
/// and a GitHub update check by default, so both are disabled at launch.
public enum CuaDriverEnvironment {
    public static func make(hostBundleID: String,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var clean = base.filter { key, _ in
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"].contains(key)
        }
        clean["CUA_DRIVER_EMBEDDED"] = "1"
        clean["CUA_DRIVER_HOST_BUNDLE_ID"] = hostBundleID
        clean["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        clean["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "0"
        clean["CUA_TELEMETRY_ENABLED"] = "0"
        clean["CUA_DRIVER_RS_UPDATE_CHECK"] = "0"
        // AIM owns the permission experience; the driver must never open System Settings.
        clean["CUA_DRIVER_RS_PERMISSIONS_GATE"] = "0"
        return clean
    }

    /// `serve` arguments. Standard mode is immutable for the daemon lifetime;
    /// unrestricted mode is never selected by AIM.
    public static func serveArguments(socketPath: String, hostBundleID: String) -> [String] {
        ["serve", "--embedded", "--parent-liveness-stdio", "--no-permissions-gate",
         "--host-bundle-id", hostBundleID, "--socket", socketPath]
    }
}

public struct CuaDriverConnection: Sendable, Equatable {
    public let generation: UUID
    public let socketPath: String
    public let version: String
}

public enum CuaDriverHostError: LocalizedError, Sendable {
    case unavailable, wrongVersion, launchFailed, exited, socketTimedOut, stopped

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The pinned CUA Driver is not bundled with AIM. The native desktop route remains available."
        case .wrongVersion: "The bundled CUA Driver version does not match AIM's qualified version."
        case .launchFailed: "CUA Driver could not start as an AIM child process."
        case .exited: "CUA Driver exited before its private connection became ready."
        case .socketTimedOut: "CUA Driver did not create its private connection in time."
        case .stopped: "CUA Driver was stopped while starting."
        }
    }
}

/// Owns the host-responsible daemon. This is deliberately separate from the
/// model tool registry: a process being ready does not qualify any gesture.
public actor EmbeddedCuaDriverHost {
    public static let qualifiedVersion = "0.28.2"

    private let executable: URL
    private let hostBundleID: String
    private let supervisor: ProcessSupervisor
    private var daemon: Process?
    /// The daemon exits when this pipe closes, including when AIM itself dies.
    private var liveness: Pipe?
    private var registrationID: UUID?
    private var socketDirectory: URL?
    private var connection: CuaDriverConnection?
    private var starting: Task<CuaDriverConnection, Error>?
    private var generation = UUID()

    public init(executable: URL? = nil, hostBundleID: String? = nil,
                supervisor: ProcessSupervisor = .shared) {
        self.executable = executable ?? HostBundleResources.resourceURL!
            .appendingPathComponent("CuaDriver/cua-driver")
        self.hostBundleID = hostBundleID ?? Bundle.main.bundleIdentifier ?? ""
        self.supervisor = supervisor
    }

    public func start() async throws -> CuaDriverConnection {
        try RuntimePrivacyPolicy.requireNetwork()
        if let connection, daemon?.isRunning == true { return connection }
        if let starting { return try await starting.value }
        if daemon != nil { await stop() }
        let task = Task { try await launch() }
        starting = task
        do {
            let ready = try await task.value
            starting = nil
            return ready
        } catch {
            starting = nil
            throw error
        }
    }

    public func currentConnection() -> CuaDriverConnection? {
        guard daemon?.isRunning == true else { return nil }
        return connection
    }

    public func stop() async {
        starting?.cancel()
        starting = nil
        generation = UUID() // invalidate every old connection before cleanup
        connection = nil
        let process = daemon
        daemon = nil
        let livenessPipe = liveness
        liveness = nil
        let directory = socketDirectory
        socketDirectory = nil
        let registered = registrationID
        registrationID = nil
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<40 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        try? livenessPipe?.fileHandleForWriting.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let registered { supervisor.finish(id: registered) }
    }

    /// Diagnostics only: the PID lets qualification verify the daemon has no network sockets.
    public func daemonProcessIdentifier() -> Int32? {
        guard let daemon, daemon.isRunning else { return nil }
        return daemon.processIdentifier
    }

    public func restart() async throws -> CuaDriverConnection {
        await stop()
        return try await start()
    }

    private func launch() async throws -> CuaDriverConnection {
        try RuntimePrivacyPolicy.requireNetwork()
        let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("CUA daemon")
        defer { withExtendedLifetime(privacyLease) {} }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverHostError.unavailable
        }
        try await verifyVersion()
        try Task.checkCancellation()
        let id = UUID()
        let directory = URL(fileURLWithPath: "/private/tmp/aim-cua-\(getpid())-\(id.uuidString.prefix(8))", isDirectory: true)
        let socket = directory.appendingPathComponent("daemon.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.terminationHandler = { [privacyLease] _ in privacyLease.finish() }
        let livenessPipe = Pipe()
        process.executableURL = executable
        process.arguments = CuaDriverEnvironment.serveArguments(socketPath: socket.path,
            hostBundleID: hostBundleID)
        process.standardInput = livenessPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = CuaDriverEnvironment.make(hostBundleID: hostBundleID)
        do {
            try process.run() // direct child: never LaunchServices or a shell
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw CuaDriverHostError.launchFailed
        }
        try? livenessPipe.fileHandleForReading.close()
        daemon = process
        liveness = livenessPipe
        socketDirectory = directory
        generation = id
        do {
            try supervisor.register(id: id) { [weak self] in
                Task { await self?.stop() }
            }
            registrationID = id
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard generation == id else { throw CuaDriverHostError.stopped }
                guard process.isRunning else { throw CuaDriverHostError.exited }
                if FileManager.default.fileExists(atPath: socket.path) {
                    let ready = CuaDriverConnection(generation: id, socketPath: socket.path,
                        version: Self.qualifiedVersion)
                    connection = ready
                    return ready
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CuaDriverHostError.socketTimedOut
        } catch {
            if process.isRunning { process.terminate() }
            if generation == id {
                daemon = nil
                try? liveness?.fileHandleForWriting.close()
                liveness = nil
                socketDirectory = nil
                connection = nil
                registrationID = nil
            }
            try? FileManager.default.removeItem(at: directory)
            supervisor.finish(id: id)
            throw error
        }
    }

    private func verifyVersion() async throws {
        try RuntimePrivacyPolicy.requireNetwork()
        let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("CUA version probe")
        let probe = Process()
        let output = Pipe()
        probe.terminationHandler = { [privacyLease] _ in privacyLease.finish() }
        probe.executableURL = executable
        probe.arguments = ["--version"]
        probe.environment = CuaDriverEnvironment.make(hostBundleID: hostBundleID)
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() }
        catch { throw CuaDriverHostError.launchFailed }
        do {
            for _ in 0..<30 where probe.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if probe.isRunning { probe.terminate() }
            throw error
        }
        guard !probe.isRunning else {
            probe.terminate()
            throw CuaDriverHostError.wrongVersion
        }
        let version = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.terminationStatus == 0, version == "cua-driver \(Self.qualifiedVersion)" else {
            throw CuaDriverHostError.wrongVersion
        }
    }
}
