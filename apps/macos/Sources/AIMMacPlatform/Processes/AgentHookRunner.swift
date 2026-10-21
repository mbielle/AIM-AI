import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation

/// Person-defined lifecycle hooks, like Claude Code's: shell commands run on
/// PreToolUse (exit code 2 blocks the call, stderr is the reason), PostToolUse
/// (stdout is appended to the result), SessionStart (stdout becomes context) and
/// Stop (end of an Agent turn). Each receives a JSON description on stdin.
///
/// Configuration: `~/Library/Application Support/com.aimai.macos/hooks.json`.
/// A project's `.aim/hooks.json` runs only if that project is listed under
/// `trusted_projects` there, so a cloned repository cannot run commands silently.
public struct AgentHookRunner: ToolHookRunning {
    public struct Hook: Codable, Equatable, Sendable {
        public let event: String
        public let matcher: String?
        public let command: String
        public let timeout: Int?
        public init(event: String, matcher: String?, command: String, timeout: Int?) {
            self.event = event; self.matcher = matcher; self.command = command; self.timeout = timeout
        }
    }

    public static let events = ["PreToolUse", "PostToolUse", "SessionStart", "Stop"]

    /// The editable file (Settings › Hooks).
    public struct Configuration: Codable, Equatable, Sendable {
        public var hooks: [Hook]?
        public var trusted_projects: [String]?
        public init(hooks: [Hook]? = nil, trusted_projects: [String]? = nil) { self.hooks = hooks; self.trusted_projects = trusted_projects }
    }

    public static func readConfiguration(_ file: URL? = globalFile) -> Configuration {
        guard let file, let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Configuration.self, from: data) else { return Configuration() }
        return value
    }

    public static func writeConfiguration(_ configuration: Configuration, to file: URL? = globalFile) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configuration).write(to: file, options: .atomic)
    }

    public let hooks: [Hook]

    public static var globalFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/hooks.json")
    }

    public init(hooks: [Hook]) { self.hooks = hooks }

    /// Loads global hooks plus a trusted project's; nil when no hook is defined.
    public static func load(workspace: String?, globalFile: URL? = AgentHookRunner.globalFile) -> AgentHookRunner? {
        let decoder = JSONDecoder()
        let global = globalFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(Configuration.self, from: $0) }
        var hooks = global?.hooks ?? []
        if let workspace {
            let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
            let trusted = (global?.trusted_projects ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path }
            if trusted.contains(root),
               let data = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".aim/hooks.json")),
               let project = try? decoder.decode(Configuration.self, from: data) {
                hooks += project.hooks ?? []
            }
        }
        hooks = hooks.filter { ["PreToolUse", "PostToolUse", "SessionStart", "Stop"].contains($0.event) && !$0.command.isEmpty }
        return hooks.isEmpty ? nil : AgentHookRunner(hooks: Array(hooks.prefix(32)))
    }

    // MARK: ToolHookRunning

    public func beforeTool(name: String, arguments: [String: String], workspace: String?) async -> String? {
        for hook in matching("PreToolUse", tool: name) {
            let outcome = await Self.run(hook, payload: ["event": "PreToolUse", "tool": name, "arguments": arguments,
                                                         "workspace": workspace ?? ""], workspace: workspace)
            if outcome.status == 2 {
                return outcome.stderr.isEmpty ? "the hook refused this call" : String(outcome.stderr.prefix(1_000))
            }
        }
        return nil
    }

    public func afterTool(name: String, arguments: [String: String], result: ToolResult, workspace: String?) async -> String? {
        var notes: [String] = []
        for hook in matching("PostToolUse", tool: name) {
            let outcome = await Self.run(hook, payload: ["event": "PostToolUse", "tool": name, "arguments": arguments,
                                                         "is_error": result.isError, "result": String(result.content.prefix(20_000)),
                                                         "workspace": workspace ?? ""], workspace: workspace)
            let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notes.append(text) }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    /// SessionStart output, added to the turn as context.
    public func sessionStart(workspace: String?, prompt: String) async -> String? {
        var notes: [String] = []
        for hook in matching("SessionStart", tool: nil) {
            let outcome = await Self.run(hook, payload: ["event": "SessionStart", "prompt": String(prompt.prefix(4_000)),
                                                         "workspace": workspace ?? ""], workspace: workspace)
            let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notes.append(String(text.prefix(8_000))) }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    public func stop(workspace: String?, answer: String) async {
        for hook in matching("Stop", tool: nil) {
            _ = await Self.run(hook, payload: ["event": "Stop", "answer": String(answer.prefix(8_000)),
                                               "workspace": workspace ?? ""], workspace: workspace)
        }
    }

    func matching(_ event: String, tool: String?) -> [Hook] {
        hooks.filter { hook in
            guard hook.event == event else { return false }
            guard let tool, let matcher = hook.matcher, !matcher.isEmpty, matcher != "*" else { return true }
            return tool.range(of: "^(?:\(matcher))$", options: .regularExpression) != nil
        }
    }

    // MARK: Process

    struct Outcome { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ hook: Hook, payload: [String: Any], workspace: String?) async -> Outcome {
        let lease: AIMNetworkPrivacyLease
        do {
            try RuntimePrivacyPolicy.requireNetwork()
            lease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation()
        } catch { return Outcome(status: -1, stdout: "", stderr: "Private mode blocks opaque hooks.") }
        let timeout = Double(min(max(hook.timeout ?? 20, 1), 120))
        let stdin = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let event = payload["event"] as? String
        let tool = payload["tool"] as? String
        return await Task.detached(priority: .userInitiated) { [lease] () -> Outcome in
            defer { withExtendedLifetime(lease) {} }
            guard !RuntimePrivacyPolicy.isEnabled else { return Outcome(status: -1, stdout: "", stderr: "Private mode blocks opaque hooks.") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", hook.command]
            process.currentDirectoryURL = URL(fileURLWithPath: workspace ?? NSHomeDirectory(), isDirectory: true)
            var environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].contains($0.key) }
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            environment["AIM_HOOK_EVENT"] = event
            if let tool { environment["AIM_TOOL_NAME"] = tool }
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch { return Outcome(status: -1, stdout: "", stderr: "hook could not start") }
            // Drain both pipes while the hook runs: a full pipe would otherwise block it until the timeout.
            let outBox = PipeDrain(output.fileHandleForReading, limit: 64_000)
            let errBox = PipeDrain(errors.fileHandleForReading, limit: 16_000)
            // A hook that exits without reading stdin must not raise SIGPIPE in AIM or block the write.
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
            let deadline = Date.now.addingTimeInterval(timeout)
            while process.isRunning && Date.now < deadline { usleep(20_000) }
            if process.isRunning { process.terminate(); return Outcome(status: -1, stdout: "", stderr: "hook timed out") }
            return Outcome(status: process.terminationStatus, stdout: outBox.finish(), stderr: errBox.finish())
        }.value
    }
}

/// Reads a pipe on a background thread, keeping at most `limit` bytes.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, limit: Int) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.withLock { if data.count < limit { data.append(chunk.prefix(limit - data.count)) } }
            }
            done.signal()
        }
    }

    func finish() -> String {
        _ = done.wait(timeout: .now() + 2)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
