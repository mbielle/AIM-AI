import AIMCore
import AIMAgentKit
import CryptoKit
import Foundation

/// Per-turn safety net: before the first file-changing action of an Agent turn,
/// the workspace's files are recorded in a private shadow Git store kept in
/// AIM's folder (never in the project or its own Git). Works for any folder;
/// .gitignore rules apply and heavy folders are excluded. Restoring first saves
/// the current state, so a restore can itself be undone.
public actor WorkspaceCheckpointService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["list_checkpoints", "restore_checkpoint"]
    public struct Checkpoint: Equatable, Sendable {
        public let id: String
        public let date: Date
        public let label: String
    }

    public enum CheckpointError: LocalizedError {
        case unsupportedWorkspace, failed(String), unknownCheckpoint
        public var errorDescription: String? {
            switch self {
            case .unsupportedWorkspace: "Checkpoints are not kept for this folder (home folder, system folder or too large)."
            case .failed(let detail): "The checkpoint store failed: \(detail)"
            case .unknownCheckpoint: "Unknown checkpoint id; call list_checkpoints."
            }
        }
    }

    static let excluded = [".git/", "node_modules/", ".build/", "build/", "DerivedData/", "Pods/", ".venv/", "venv/",
                           "__pycache__/", "dist/", "target/", ".next/", ".gradle/", "*.xcarchive/", ".DS_Store"]
    private let runner: any ProcessRunning
    private let storeRoot: URL
    private let workspace: String
    private let trash: @Sendable (URL) throws -> Void
    private var disabled = false

    public static var defaultStoreRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory).appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Checkpoints", isDirectory: true)
    }

    public init(workspace: String, runner: any ProcessRunning = MacProcessRunner(),
                storeRoot: URL = WorkspaceCheckpointService.defaultStoreRoot,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.workspace = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        self.runner = runner
        self.storeRoot = storeRoot
        self.trash = trash
    }

    private var gitDirectory: URL {
        let digest = SHA256.hash(data: Data(workspace.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return storeRoot.appendingPathComponent("\(digest).git", isDirectory: true)
    }

    private var supported: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return !disabled && workspace != "/" && workspace != home &&
            !["/System", "/Library", "/Applications", "/usr", "/private", "/Users"].contains(workspace)
    }

    /// Records the current files; returns the checkpoint id (unchanged files reuse the last one).
    @discardableResult
    public func checkpoint(label: String) async throws -> String {
        guard supported else { throw CheckpointError.unsupportedWorkspace }
        try await prepareStore()
        let add = try await git(["add", "-A", "--", "."], timeout: .seconds(90))
        guard add.exitCode == 0 else {
            disabled = true
            throw CheckpointError.failed(String(add.stderr.prefix(300)))
        }
        let commit = try await git(["-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "--quiet", "-m",
                                    String(label.prefix(200))],
                                   environment: ["GIT_AUTHOR_NAME": "AIM", "GIT_AUTHOR_EMAIL": "aim@localhost.invalid",
                                                 "GIT_COMMITTER_NAME": "AIM", "GIT_COMMITTER_EMAIL": "aim@localhost.invalid"])
        var head = try await git(["rev-parse", "HEAD"])
        if head.exitCode != 0 {
            // An empty folder still gets a first checkpoint to restore to.
            _ = try await git(["-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "--quiet", "--allow-empty", "-m",
                               String(label.prefix(200))],
                              environment: ["GIT_AUTHOR_NAME": "AIM", "GIT_AUTHOR_EMAIL": "aim@localhost.invalid",
                                            "GIT_COMMITTER_NAME": "AIM", "GIT_COMMITTER_EMAIL": "aim@localhost.invalid"])
            head = try await git(["rev-parse", "HEAD"])
        }
        let id = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.exitCode == 0, id.count == 40 else {
            throw CheckpointError.failed(String((commit.stderr + head.stderr).prefix(300)))
        }
        return id
    }

    public func list(limit: Int = 30) async throws -> [Checkpoint] {
        guard FileManager.default.fileExists(atPath: gitDirectory.path) else { return [] }
        let log = try await git(["log", "-n", String(min(max(limit, 1), 100)), "--format=%H%x09%ct%x09%s"])
        guard log.exitCode == 0 else { return [] }
        return log.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let seconds = TimeInterval(parts[1]) else { return nil }
            return Checkpoint(id: parts[0], date: Date(timeIntervalSince1970: seconds), label: parts[2])
        }
    }

    /// Puts the workspace back to a checkpoint: files created since are moved to
    /// the Trash, changed or deleted files get their recorded content back.
    public func restore(_ id: String) async throws -> (restored: Int, trashed: [String], safety: String) {
        guard id.count == 40, id.allSatisfy(\.isHexDigit),
              try await git(["cat-file", "-e", "\(id)^{commit}"]).exitCode == 0 else { throw CheckpointError.unknownCheckpoint }
        let safety = try await checkpoint(label: "Before restoring checkpoint \(id.prefix(8))")
        let added = try await git(["diff", "--name-only", "-z", "--diff-filter=A", id, safety])
        let changed = try await git(["diff", "--name-only", "-z", "--diff-filter=MDT", id, safety])
        var trashed: [String] = []
        for path in added.stdout.split(separator: "\0").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: workspace).appendingPathComponent(path)
            if (try? trash(url)) != nil { trashed.append(path) }
        }
        let paths = changed.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        if !paths.isEmpty {
            for batch in stride(from: 0, to: paths.count, by: 200) {
                let slice = Array(paths[batch..<min(batch + 200, paths.count)])
                let checkout = try await git(["checkout", id, "--"] + slice, timeout: .seconds(90))
                guard checkout.exitCode == 0 else { throw CheckpointError.failed(String(checkout.stderr.prefix(300))) }
            }
        }
        return (paths.count, trashed, safety)
    }

    // MARK: Tools

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            switch request.name {
            case "list_checkpoints":
                let items = try await list()
                guard !items.isEmpty else { return ToolResult(requestID: request.id, content: "No checkpoint yet for this workspace.") }
                let formatter = ISO8601DateFormatter()
                return ToolResult(requestID: request.id, content: items.map { "\($0.id)  \(formatter.string(from: $0.date))  \($0.label)" }
                    .joined(separator: "\n"))
            case "restore_checkpoint":
                let outcome = try await restore(request.arguments["checkpoint_id"] ?? "")
                return ToolResult(requestID: request.id,
                    content: "Restored \(outcome.restored) changed or deleted file(s); moved \(outcome.trashed.count) file(s) created since then to the Trash\(outcome.trashed.isEmpty ? "" : " (\(outcome.trashed.prefix(20).joined(separator: ", ")))"). The state just before this restore is checkpoint \(outcome.safety), so this can be undone.")
            default:
                throw CheckpointError.unknownCheckpoint
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    // MARK: Git

    private func prepareStore() async throws {
        let directory = gitDirectory
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("HEAD").path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let initialized = try await git(["init", "--quiet"])
            guard initialized.exitCode == 0 else { throw CheckpointError.failed(String(initialized.stderr.prefix(300))) }
        }
        let exclude = directory.appendingPathComponent("info/exclude")
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Self.excluded.joined(separator: "\n") + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String], environment: [String: String] = [:],
                     timeout: Duration = .seconds(30)) async throws -> ProcessOutput {
        try Task.checkCancellation()
        return try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "--git-dir=\(gitDirectory.path)", "--work-tree=\(workspace)",
                        "-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-c", "core.autocrlf=false",
                        "-c", "gc.auto=0"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GIT_OPTIONAL_LOCKS": "0"]) { current, _ in current },
            timeout: timeout))
    }
}
