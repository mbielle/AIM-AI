import AIMApplication
import AIMAgentKit
import Foundation

/// Commands run as the signed-in user, not in a sandbox. Starting either
/// foreground or followed work requires exact approval of that command.
public actor WorkspaceShellToolService: ToolExecutor, ToolRiskClassifying, ToolSessionClosing, ToolPreflighting, ToolReviewProviding, DurableToolExecutor {
    public struct DurableSnapshot: Codable, Sendable {
        public var id: UUID
        public var state: String
        public var version: Int
        public var exitCode: Int32?
        public var failure: String?
        public var stdout: Data
        public var stderr: Data
    }
    public nonisolated let supportedTools: Set<String> = [
        "run_command", "start_command", "read_command", "write_command",
        "close_command_input", "stop_command"
    ]
    private let runner: any ProcessRunning
    private let supportsStreaming: Bool
    private nonisolated let environmentAtCreation: WorkspaceExecutionEnvironment?
    private var task: Task<ProcessOutput, Error>?
    private struct BackgroundCommand {
        var operation: Task<Void, Never>?
        var runner: MacProcessRunner?
        var spool: ProcessOutputSpool?
        var state = "running"
        var stopRequested = false
        var inputOpen = false
        var version = 0
        var exitCode: Int32?
        var failure: String?
    }
    private struct BackgroundReceipt: Encodable {
        let handle: String
        let state: String
        let version: Int
        let exitCode: Int32?
        let failure: String?
        let stdinPipeOpen: Bool
        let unchanged: Bool
        let stdoutChunk: String
        let stderrChunk: String
        let stdoutChunkBase64: String?
        let stderrChunkBase64: String?
        let nextStdoutOffset: Int64
        let nextStderrOffset: Int64
        let stdoutAvailableBytes: Int64
        let stderrAvailableBytes: Int64
        let outputLimitReached: Bool
        let outputStorageError: Bool
        let hasMore: Bool
    }
    private var background: [UUID: BackgroundCommand] = [:]
    private var closed = false
    public init(runner: any ProcessRunning = WorkspaceExecutionEnvironment.makeRunner()) {
        self.runner = runner
        self.environmentAtCreation = try? WorkspaceExecutionEnvironment.current()
        self.supportsStreaming = runner is MacProcessRunner
    }
    public func exportToolState() throws -> Data {
        guard let environmentAtCreation else { throw WorkspaceEnvironmentError.invalidConfiguration }
        return try JSONEncoder().encode(environmentAtCreation)
    }
    public func restoreToolState(_ data: Data, workspacePath: String?) throws {
        guard data.count <= 16_384, let environmentAtCreation,
              try JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: data) == environmentAtCreation,
              try WorkspaceExecutionEnvironment.current() == environmentAtCreation else { throw ExecutionStoreError.incompatibleCheckpoint }
    }
    public nonisolated func recoveryPolicy(for name: String) -> ToolRecoveryPolicy { name == "read_command" ? .readOnly : .neverReplay }
    public func reconcile(_ call: ModelToolCall, workspacePath: String?) -> ModelToolOutput? { nil }

    public func durableSnapshots() throws -> [DurableSnapshot] {
        try background.map { id, command in
            // Active processes are never claimed recoverable from an old PID/output.
            let retainOutput = command.state != "running"
            return DurableSnapshot(id: id, state: command.state, version: command.version,
                exitCode: command.exitCode, failure: command.failure,
                stdout: retainOutput ? try Self.output(command.spool, stream: 1) : Data(),
                stderr: retainOutput ? try Self.output(command.spool, stream: 2) : Data())
        }
    }
    public func restoreDurableSnapshots(_ snapshots: [DurableSnapshot]) throws {
        guard !closed else { throw ProcessExecutionError.invalidArgument }
        for snapshot in snapshots where background[snapshot.id] == nil || (background[snapshot.id]?.state == "unknown" && snapshot.state != "running") {
            let spool = try ProcessOutputSpool()
            for (stream, bytes) in [(Int32(1), snapshot.stdout), (Int32(2), snapshot.stderr)] {
                bytes.withUnsafeBytes { if let address = $0.baseAddress { spool.append(stream: stream, bytes: address, count: $0.count) } }
            }
            background[snapshot.id] = BackgroundCommand(spool: spool,
                state: snapshot.state == "running" ? "unknown" : snapshot.state,
                version: snapshot.version + (snapshot.state == "running" ? 1 : 0),
                exitCode: snapshot.exitCode,
                failure: snapshot.state == "running" ? "Interrupted runtime: process effects and identity must be reconciled by a person before retrying." : snapshot.failure)
        }
    }
    private static func output(_ spool: ProcessOutputSpool?, stream: Int32) throws -> Data {
        guard let spool else { return Data() }
        var data = Data(), offset: Int64 = 0
        while true {
            let page = try spool.page(stream: stream, offset: offset, maximumBytes: 65536)
            data.append(page.bytes); offset = page.nextOffset
            guard offset < page.availableBytes else { return data }
        }
    }

    public nonisolated static func verifiedRead(_ command: String) -> String? {
        switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "pwd": "pwd"
        case "git status", "git status --short", "git status --porcelain": "git_status"
        case "git diff", "git diff --no-ext-diff": "git_diff"
        default: nil
        }
    }
    public nonisolated func risk(for arguments: [String: String]) -> ToolRisk {
        Self.verifiedRead(arguments["command"] ?? "") == nil ? .destructive : .readOnly
    }

    public nonisolated func risk(for name: String, arguments: [String: String]) -> ToolRisk {
        switch name {
        case "read_command": .readOnly
        case "stop_command": .localMutation
        case "write_command", "close_command_input": .destructive
        case "start_command": .destructive
        default: risk(for: arguments)
        }
    }

    /// Catastrophic commands are refused before the person is asked to approve them.
    public nonisolated func preflightRefusal(_ request: ToolRequest) -> String? {
        guard request.name == "run_command" || request.name == "start_command",
              let command = request.arguments["command"],
              let reason = ShellCommandClassifier.classify(command).refusal else { return nil }
        return "AIM refuses to run this command because \(reason). Nothing was run and no approval was requested. If it is truly needed, the person must run it themselves."
    }

    /// Sensitive commands show their risks in the approval (and never get a session-wide grant).
    public nonisolated func review(_ request: ToolRequest) async throws -> ToolReview? {
        guard request.name == "run_command" || request.name == "start_command",
              let command = request.arguments["command"] else { return nil }
        let verdict = ShellCommandClassifier.classify(command)
        guard verdict.isSensitive else { return nil }
        var text = command + "\n\n" + verdict.warnings.map { "⚠︎ " + $0 }.joined(separator: "\n")
        if verdict.discardsLocalChanges { text += "\nAIM saves a Git recovery point of the current files before running it." }
        let folder = request.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "workspace"
        return ToolReview(path: "Command in \(folder)", before: "", after: text)
    }

    /// Before a command that may discard uncommitted work, saves the files under refs/aim/recovery/.
    /// Returns a note for the result, or nil when nothing needed saving; throws when saving failed.
    private func recoveryNote(for command: String, workspace: URL) async throws -> String? {
        guard ShellCommandClassifier.classify(command).discardsLocalChanges else { return nil }
        guard let point = try await GitWorkingTreeSnapshot(runner: runner).recoveryPoint(in: workspace.path) else { return nil }
        return "Recovery point saved before running: \(point.reference) (restore the files with: git restore --source=\(point.reference) --worktree -- .)"
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard !closed, !Task.isCancelled else { throw CancellationError() }
            if !["read_command", "stop_command"].contains(request.name) {
                guard let environmentAtCreation, try WorkspaceExecutionEnvironment.current() == environmentAtCreation else { throw WorkspaceEnvironmentError.invalidConfiguration }
            }
            switch request.name {
            case "run_command": return try await runForeground(request)
            case "start_command": return try await startBackground(request)
            case "read_command": return try await readBackground(request)
            case "write_command": return try await writeBackground(request)
            case "close_command_input": return try await closeBackgroundInput(request)
            case "stop_command": return try await stopBackground(request)
            default: throw ProcessExecutionError.invalidArgument
            }
        } catch let error as ProcessInputError {
            switch error {
            case .partiallyWritten(let sent, let total):
                return ToolResult(requestID: request.id,
                    content: error.localizedDescription + " The receiving process may already have acted on those bytes.",
                    isError: true,
                    metadata: ["input_bytes_accepted": String(sent), "input_bytes_total": String(total)])
            case .notRunning, .invalidInput, .inputBackpressure:
                return ToolResult(requestID: request.id,
                    content: error.localizedDescription + " No new input was accepted by this call.", isError: true,
                    metadata: ["input_bytes_accepted": "0"])
            }
        } catch {
            return ToolResult(requestID: request.id, content: "Command stopped or failed: \(error.localizedDescription). It may have made changes before stopping; inspect the workspace before retrying.", isError: true)
        }
    }

    private func command(for request: ToolRequest) throws -> (String, URL, ProcessCommand) {
        guard let command = request.arguments["command"],
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  command.utf8.count <= 16_384, !command.contains("\0"),
                  let path = request.workspacePath, path.hasPrefix("/"), !path.contains("\0") else {
                throw ProcessExecutionError.invalidArgument
        }
        let workspace = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard workspace.path == path,
              try workspace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ProcessExecutionError.invalidArgument
        }
        var environment = ["PATH": Self.toolPath(), "TERM": "dumb", "NO_COLOR": "1"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        let process = ProcessCommand(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", command],
            workingDirectory: workspace, environment: environment, timeout: nil, inheritsEnvironment: false)
        return (command, workspace, process)
    }

    /// System tools, Homebrew, and the per-user toolchains developers install (Rust, Bun, Deno,
    /// pipx/uv, Go, pyenv/rbenv shims, the active nvm Node), only when those folders exist.
    public static func toolPath(home: String? = ProcessInfo.processInfo.environment["HOME"], fileManager: FileManager = .default) -> String {
        var entries: [String] = []
        if let home {
            let personal = [".local/bin", ".cargo/bin", ".bun/bin", ".deno/bin", "go/bin", ".pyenv/shims", ".rbenv/shims",
                            ".volta/bin", "Library/pnpm"].map { home + "/" + $0 }
            entries += personal.filter { fileManager.fileExists(atPath: $0) }
            let nvm = home + "/.nvm/versions/node"
            if let versions = try? fileManager.contentsOfDirectory(atPath: nvm),
               let latest = versions.filter({ $0.hasPrefix("v") }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                entries.append(nvm + "/" + latest + "/bin")
            }
        }
        entries += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return entries.joined(separator: ":")
    }

    private func runForeground(_ request: ToolRequest) async throws -> ToolResult {
            guard task == nil else { throw ProcessExecutionError.invalidArgument }
            let (command, workspace, process) = try command(for: request)
            if let read = Self.verifiedRead(command) {
                if read == "pwd" { return ToolResult(requestID: request.id, content: workspace.path) }
                // Execute through the existing hardened Git reader, not through a shell.
                let git = MacGitToolService(runner: runner)
                return await git.execute(ToolRequest(id: request.id, name: read, arguments: [:], risk: .readOnly, workspacePath: workspace.path))
            }
            try RuntimePrivacyPolicy.requireNetwork()
            let note: String?
            do { note = try await recoveryNote(for: command, workspace: workspace) }
            catch { return Self.recoveryFailure(request) }
            let operation = Task { try await runner.run(process) }
            task = operation
            defer { task = nil }
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            let text = (note.map { $0 + "\n" } ?? "") + "Exit code: \(result.exitCode)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
                + (result.wasTruncated ? "\n[Process output truncated]" : "")
            return ToolResult(requestID: request.id, content: text, isError: result.exitCode != 0,
                              metadata: ["exit_code": String(result.exitCode)])
    }

    private static func recoveryFailure(_ request: ToolRequest) -> ToolResult {
        ToolResult(requestID: request.id, content: "AIM could not save a recovery point of the current files, so this command (which may discard uncommitted changes) was not run.", isError: true)
    }

    private func startBackground(_ request: ToolRequest) async throws -> ToolResult {
        try RuntimePrivacyPolicy.requireNetwork()
        guard supportsStreaming else { throw ProcessExecutionError.invalidArgument }
        let (commandText, workspaceURL, initialProcess) = try command(for: request)
        let allowStdin: Bool
        switch request.arguments["allow_stdin"] {
        case nil, "false": allowStdin = false
        case "true": allowStdin = true
        default: throw ProcessExecutionError.invalidArgument
        }
        var process = initialProcess
        process.acceptsStandardInput = allowStdin
        // Snapshot first: the actor may be re-entered while it runs, so count afterwards.
        let note: String?
        do { note = try await recoveryNote(for: commandText, workspace: workspaceURL) }
        catch { return Self.recoveryFailure(request) }
        let runningCount = background.values.filter { $0.state == "running" }.count
        guard runningCount < 3 else {
            return ToolResult(requestID: request.id,
                content: "Three commands are already running. Read or stop one before starting another.", isError: true)
        }
        let id = UUID()
        // One runner per handle lets Stop wait for exactly this process group,
        // without terminating other commands that happen to be running.
        let dedicatedRunner = MacProcessRunner()
        let spool = try ProcessOutputSpool()
        background[id] = BackgroundCommand(runner: dedicatedRunner, spool: spool, inputOpen: allowStdin)
        let stream = dedicatedRunner.stream(process, id: id, spool: spool)
        let operation = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    await self.record(event, handle: id)
                }
                await self?.recordEndedWithoutReceipt(handle: id, cancelled: Task.isCancelled)
            } catch {
                await self?.recordFailure(error, handle: id)
            }
        }
        background[id]?.operation = operation
        let state = background[id]?.state ?? "unknown"
        return ToolResult(requestID: request.id,
            content: (note.map { $0 + "\n" } ?? "") + "Started host command with handle \(id.uuidString). It is not sandboxed. Use read_command with this handle to inspect output and completion; Stop ends its process group. Stdin pipe: \(allowStdin ? "open" : "closed").",
            isError: state == "failed" || state == "unknown",
            metadata: ["process_handle": id.uuidString, "process_state": state])
    }

    private func readBackground(_ request: ToolRequest) async throws -> ToolResult {
        guard let id = request.arguments["handle"].flatMap(UUID.init(uuidString:)),
              background[id] != nil else { throw ProcessExecutionError.invalidArgument }
        let afterVersion: Int?
        if let raw = request.arguments["after_version"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw ProcessExecutionError.invalidArgument }
            afterVersion = parsed
        } else { afterVersion = nil }
        let wait: Int
        if let raw = request.arguments["wait_ms"] {
            guard let parsed = Int(raw), (0...30_000).contains(parsed) else {
                throw ProcessExecutionError.invalidArgument
            }
            wait = parsed
        } else { wait = 0 }
        let stdoutOffset = try Self.outputOffset(request.arguments["stdout_offset"])
        let stderrOffset = try Self.outputOffset(request.arguments["stderr_offset"])
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(wait))
        while let current = background[id], current.state == "running",
              let afterVersion, current.version <= afterVersion,
              ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if (request.arguments["stdout_offset"] != nil || request.arguments["stderr_offset"] != nil),
               let spool = current.spool {
                let out = try spool.page(stream: 1, offset: stdoutOffset, maximumBytes: 1)
                let err = try spool.page(stream: 2, offset: stderrOffset, maximumBytes: 1)
                if out.availableBytes > stdoutOffset || err.availableBytes > stderrOffset { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let current = background[id], let spool = current.spool else {
            throw ProcessExecutionError.invalidArgument
        }
        let stdout = try Self.textPage(spool, stream: 1, offset: stdoutOffset)
        let stderr = try Self.textPage(spool, stream: 2, offset: stderrOffset)
        let stdoutText = String(data: stdout.bytes, encoding: .utf8)
        let stderrText = String(data: stderr.bytes, encoding: .utf8)
        let unchanged = afterVersion.map { $0 >= current.version && current.state == "running" } == true &&
            stdout.bytes.isEmpty && stderr.bytes.isEmpty
        let receipt = BackgroundReceipt(handle: id.uuidString, state: current.state,
            version: current.version, exitCode: current.exitCode,
            failure: current.failure, stdinPipeOpen: current.inputOpen, unchanged: unchanged,
            stdoutChunk: stdoutText ?? String(decoding: stdout.bytes, as: UTF8.self),
            stderrChunk: stderrText ?? String(decoding: stderr.bytes, as: UTF8.self),
            stdoutChunkBase64: stdoutText == nil && !stdout.bytes.isEmpty ? stdout.bytes.base64EncodedString() : nil,
            stderrChunkBase64: stderrText == nil && !stderr.bytes.isEmpty ? stderr.bytes.base64EncodedString() : nil,
            nextStdoutOffset: stdout.nextOffset, nextStderrOffset: stderr.nextOffset,
            stdoutAvailableBytes: stdout.availableBytes, stderrAvailableBytes: stderr.availableBytes,
            outputLimitReached: stdout.limitReached || stderr.limitReached,
            outputStorageError: stdout.storageError || stderr.storageError,
            hasMore: stdout.nextOffset < stdout.availableBytes || stderr.nextOffset < stderr.availableBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let content = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        return ToolResult(requestID: request.id, content: content,
            isError: ["failed", "unknown"].contains(current.state) || current.exitCode.map { $0 != 0 } == true ||
                receipt.outputStorageError,
            metadata: ["process_handle": id.uuidString, "process_state": current.state,
                       "process_version": String(current.version)])
    }

    private func stopBackground(_ request: ToolRequest) async throws -> ToolResult {
        guard let id = request.arguments["handle"].flatMap(UUID.init(uuidString:)),
              let current = background[id] else { throw ProcessExecutionError.invalidArgument }
        if current.state == "running", let operation = current.operation {
            background[id]?.stopRequested = true
            operation.cancel()
            await current.runner?.terminateAll()
            await operation.value
            await current.runner?.terminateAll()
        }
        let state = background[id]?.state ?? "unknown"
        return ToolResult(requestID: request.id,
            content: "Process handle \(id.uuidString) state: \(state). Read the output and inspect any side effects before retrying.",
            isError: state == "unknown",
            metadata: ["process_handle": id.uuidString, "process_state": state])
    }

    private func writeBackground(_ request: ToolRequest) async throws -> ToolResult {
        try RuntimePrivacyPolicy.requireNetwork()
        guard let id = request.arguments["handle"].flatMap(UUID.init(uuidString:)),
              let text = request.arguments["text"],
              let current = background[id], current.state == "running", current.inputOpen,
              let runner = current.runner else { throw ProcessInputError.notRunning }
        let accepted = try await runner.send(text, to: id)
        return ToolResult(requestID: request.id,
            content: "Accepted \(accepted) UTF-8 input bytes for process \(id.uuidString). The process may have acted on them; read its output before sending more.",
            metadata: ["process_handle": id.uuidString, "input_bytes_accepted": String(accepted)])
    }

    private func closeBackgroundInput(_ request: ToolRequest) async throws -> ToolResult {
        guard let id = request.arguments["handle"].flatMap(UUID.init(uuidString:)),
              let current = background[id], current.state == "running", current.inputOpen,
              let runner = current.runner else { throw ProcessInputError.notRunning }
        try await runner.closeInput(to: id)
        background[id]?.inputOpen = false
        return ToolResult(requestID: request.id,
            content: "Closed standard input for process \(id.uuidString). It may now complete or act on previously sent data; read its result.",
            metadata: ["process_handle": id.uuidString, "stdin_closed": "true"])
    }

    private func record(_ event: ProcessStreamEvent, handle: UUID) {
        guard var current = background[handle] else { return }
        switch event {
        case .output:
            break
        case .completed(let result):
            current.exitCode = result.exitCode
            current.state = current.stopRequested ? "stopped" : "completed"
            current.inputOpen = false
        }
        current.version += 1
        background[handle] = current
    }

    private func recordFailure(_ error: Error, handle: UUID) {
        guard var current = background[handle] else { return }
        current.state = error is CancellationError || current.stopRequested ? "stopped" : "failed"
        current.inputOpen = false
        current.failure = error.localizedDescription
        current.version += 1
        background[handle] = current
    }

    private func recordEndedWithoutReceipt(handle: UUID, cancelled: Bool) {
        guard var current = background[handle], current.state == "running" else { return }
        current.state = cancelled || current.stopRequested ? "stopped" : "unknown"
        current.inputOpen = false
        current.failure = cancelled || current.stopRequested ? "The process was stopped; inspect side effects before retrying."
            : "The process stream ended without a completion receipt; inspect side effects before retrying."
        current.version += 1
        background[handle] = current
    }

    public func cancel(requestID: String) async {
        await closeSession()
    }

    public func closeSession() async {
        await closeSession(retainReceipts: false)
    }
    public func stopForRuntime() async {
        await closeSession(retainReceipts: true)
    }
    private func closeSession(retainReceipts: Bool) async {
        guard !closed else { return }
        closed = true
        let active = task
        active?.cancel()
        let runningIDs = background.compactMap { $0.value.state == "running" ? $0.key : nil }
        for id in runningIDs {
            background[id]?.stopRequested = true
        }
        let running = background.values.filter { $0.state == "running" }
        let operations = running.compactMap(\.operation)
        for operation in operations { operation.cancel() }
        for entry in running { await entry.runner?.terminateAll() }
        _ = await active?.result
        for operation in operations { await operation.value }
        for entry in running { await entry.runner?.terminateAll() }
        if !retainReceipts { background.removeAll() }
    }

    private nonisolated static func outputOffset(_ raw: String?) throws -> Int64 {
        guard let raw else { return 0 }
        guard let value = Int64(raw), value >= 0 else { throw ProcessExecutionError.invalidArgument }
        return value
    }

    /// Leave an incomplete UTF-8 scalar for the next page when the page
    /// boundary, rather than the process, split otherwise valid text. Binary
    /// pages retain their original bytes in the Base64 receipt.
    private nonisolated static func textPage(_ spool: ProcessOutputSpool, stream: Int32,
                                            offset: Int64) throws -> ProcessOutputSpool.Page {
        let page = try spool.page(stream: stream, offset: offset)
        guard page.bytes.count == 16_384, String(data: page.bytes, encoding: .utf8) == nil else {
            return page
        }
        for trailing in 1...3 {
            let shorter = Data(page.bytes.dropLast(trailing))
            if String(data: shorter, encoding: .utf8) != nil {
                return try spool.page(stream: stream, offset: offset,
                                      maximumBytes: page.bytes.count - trailing)
            }
        }
        return page
    }
}
