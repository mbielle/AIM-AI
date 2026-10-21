import AIMCore
import AIMAgentKit
import AIMApplication
import Darwin
import Foundation

/// Configuration is chosen by the person, never by a model tool argument.
public struct WorkspaceExecutionEnvironment: Codable, Sendable, Equatable {
    public enum Backend: String, Codable, CaseIterable, Sendable { case host, container, ssh, virtualMachine }
    public var version = 1
    public var backend: Backend = .host
    public var executable = "/opt/homebrew/bin/docker"
    public var image = ""
    public var networkEnabled = false
    public var workspaceRoot = ""
    public var host = ""
    public var user = ""
    public var port = 22
    public var identityFile = ""
    public var knownHostsFile = ""
    public var remoteDirectory = ""
    public static let defaultsKey = "AIMWorkspaceExecutionEnvironmentV1"
    public init() {}
    public static func current() throws -> Self {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        guard let data = defaults.data(forKey: defaultsKey) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    public func validate() throws {
        guard version == 1 else { throw WorkspaceEnvironmentError.invalidConfiguration }
        guard backend != .host else { return }
        guard workspaceRoot.hasPrefix("/"), !workspaceRoot.contains("\0"), !workspaceRoot.contains(","),
              FileManager.default.fileExists(atPath: workspaceRoot),
              URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL.path == workspaceRoot else {
            throw WorkspaceEnvironmentError.invalidConfiguration
        }
        if backend == .virtualMachine { return }
        if backend == .container {
            guard executable.hasPrefix("/"), ["docker", "podman"].contains(URL(fileURLWithPath: executable).lastPathComponent),
                  FileManager.default.isExecutableFile(atPath: executable),
                  image.contains("@sha256:"), image.split(separator: ":").last?.count == 64,
                  image.split(separator: ":").last?.allSatisfy({ $0.isHexDigit }) == true,
                  !image.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw WorkspaceEnvironmentError.invalidConfiguration }
        } else {
            guard !host.isEmpty, !user.isEmpty, (host + user).allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }),
                  !host.hasPrefix("-"), !user.hasPrefix("-"), (1...65535).contains(port),
                  identityFile.hasPrefix("/"), knownHostsFile.hasPrefix("/"),
                  remoteDirectory.hasPrefix("/"), !remoteDirectory.contains("\0"),
                  FileManager.default.fileExists(atPath: identityFile), FileManager.default.fileExists(atPath: knownHostsFile) else {
                throw WorkspaceEnvironmentError.invalidConfiguration
            }
        }
    }
    public static func save(_ value: Self) throws {
        try value.validate()
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.set(try JSONEncoder().encode(value), forKey: defaultsKey); defaults.synchronize()
    }
    public static var isIsolated: Bool {
        // Malformed configuration must fail at execution rather than silently
        // sending a command back to the host account.
        let defaults = AIMInstallationContext.sharedPreferences
        guard let data = defaults.data(forKey: defaultsKey) else { return false }
        return (try? JSONDecoder().decode(Self.self, from: data).backend) != .host
    }
    private static let virtualRunner = VirtualRunnerSlot()
    public static func installVirtualMachineRunner(_ runner: (any ProcessRunning)?) { virtualRunner.set(runner) }
    public static func makeRunner() -> any ProcessRunning {
        let defaults = AIMInstallationContext.sharedPreferences
        if let data = defaults.data(forKey: defaultsKey),
           (try? JSONDecoder().decode(Self.self, from: data).backend) == .virtualMachine {
            return virtualRunner.get() ?? MissingVirtualMachineRunner()
        }
        return isIsolated ? EnvironmentProcessRunner() : MacProcessRunner()
    }
}
private final class VirtualRunnerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var runner: (any ProcessRunning)?
    func set(_ value: (any ProcessRunning)?) { lock.lock(); defer { lock.unlock() }; runner = value }
    func get() -> (any ProcessRunning)? { lock.lock(); defer { lock.unlock() }; return runner }
}
private struct MissingVirtualMachineRunner: ProcessRunning {
    func run(_ command: ProcessCommand) async throws -> ProcessOutput { throw LocalVirtualMachineError.notRunning }
    func terminateAll() async {}
}
public enum WorkspaceEnvironmentError: LocalizedError {
    case invalidConfiguration, outsideWorkspace, unsupportedCommand
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The execution environment is invalid or unavailable. No host fallback was used."
        case .outsideWorkspace: "This workspace is outside the explicitly configured execution environment."
        case .unsupportedCommand: "This environment supports foreground shell commands only; background handles and native verification need a separate backend."
        }
    }
}
public actor EnvironmentProcessRunner: ProcessRunning {
    private let runner = MacProcessRunner()
    public init() {}
    public func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        let configuration = try WorkspaceExecutionEnvironment.current()
        guard configuration.backend != .host, configuration.backend != .virtualMachine else { throw WorkspaceEnvironmentError.invalidConfiguration }
        guard command.executable.path == "/bin/zsh", command.arguments.count == 3,
              command.arguments[0] == "-f", command.arguments[1] == "-c", let cwd = command.workingDirectory else {
            throw WorkspaceEnvironmentError.unsupportedCommand
        }
        let path = cwd.resolvingSymlinksInPath().standardizedFileURL.path
        let root = configuration.workspaceRoot
        guard path == root || path.hasPrefix(root + "/"), !path.contains(","), !path.contains("\0") else { throw WorkspaceEnvironmentError.outsideWorkspace }
        let script = command.arguments[2]
        let actual: ProcessCommand
        if configuration.backend == .container {
            if configuration.networkEnabled { try RuntimePrivacyPolicy.requireNetwork() }
            let name = "aim-run-" + UUID().uuidString.lowercased()
            var args = ["run", "--rm", "--name", name, "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only",
                        "--user", "\(getuid()):\(getgid())", "--tmpfs", "/tmp:rw,nosuid,nodev", "--env", "HOME=/tmp",
                        "--network", configuration.networkEnabled ? "bridge" : "none", "--mount", "type=bind,source=\(path),target=/workspace",
                        "--workdir", "/workspace"]
            args += [configuration.image, "/bin/sh", "-c", script]
            actual = ProcessCommand(executable: URL(fileURLWithPath: configuration.executable), arguments: args,
                environment: ["PATH": "/usr/bin:/bin"], timeout: command.timeout, inheritsEnvironment: false)
            let output: ProcessOutput
            do { output = try await runner.run(actual) }
            catch {
                // Terminating a CLI does not reliably stop its container. Target
                // only the unique container created by this invocation.
                await Task.detached {
                    let cleanup = MacProcessRunner()
                    _ = try? await cleanup.run(ProcessCommand(executable: URL(fileURLWithPath: configuration.executable),
                        arguments: ["rm", "--force", name], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10), inheritsEnvironment: false))
                }.value
                throw error
            }
            // Container exit may be ambiguous on host crash. Durable tool policy
            // stays neverReplay; do not infer isolation from a successful build.
            return output
        } else {
            try RuntimePrivacyPolicy.requireNetwork()
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
            let remotePath = relative.isEmpty ? configuration.remoteDirectory : configuration.remoteDirectory + "/" + relative
            let remote = "cd -- \(quote(remotePath)) && /bin/sh -c \(quote(script))"
            actual = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes",
                            "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=\(configuration.knownHostsFile)", "-i", configuration.identityFile,
                            "-p", String(configuration.port), "--", "\(configuration.user)@\(configuration.host)", remote],
                environment: ["PATH": "/usr/bin:/bin"], timeout: command.timeout, inheritsEnvironment: false)
            return try await runner.run(actual)
        }
    }
    public func terminateAll() async { await runner.terminateAll() }
}
