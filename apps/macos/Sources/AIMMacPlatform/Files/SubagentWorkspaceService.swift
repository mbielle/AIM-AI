import AIMCore
import AIMAgentKit
import AIMApplication
import CryptoKit
import Foundation

/// The changes a writer sub-agent made in its worktree, relative to its base snapshot.
public struct SubagentChangeSet: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let status: String   // A, M, D, T
        public let path: String     // relative to the repository root
        public let insertions: Int?
        public let deletions: Int?
    }

    public let files: [File]
    public let patch: Data
    public let patchSHA256: String

    public var isEmpty: Bool { files.isEmpty }
    public var deletesFiles: Bool { files.contains { $0.status == "D" } }

    public var summary: String {
        guard !files.isEmpty else { return "No changes." }
        let lines = files.prefix(200).map { file in
            let counts = file.insertions.map { "+\($0) −\(file.deletions ?? 0)" } ?? "binary"
            return "\(file.status) \(file.path) (\(counts))"
        }
        return lines.joined(separator: "\n") + (files.count > 200 ? "\n… \(files.count - 200) more file(s)" : "")
    }
}

public enum SubagentWorkspaceError: LocalizedError, Equatable {
    case notRepository, noCommit, outsideRepository, unavailable(String), notOwned
    case changedSinceReview, notReviewed, conflict(String), tooLarge

    public var errorDescription: String? {
        switch self {
        case .notRepository: "Writer sub-agents need the workspace to be inside a Git repository."
        case .noCommit: "Writer sub-agents need a repository with at least one commit."
        case .outsideRepository: "The workspace is not inside its repository root."
        case .unavailable(let detail): "Git could not prepare the sub-agent worktree: \(detail)"
        case .notOwned: "That worktree was not created by AIM for a sub-agent; AIM will not change it."
        case .changedSinceReview: "The sub-agent's changes differ from the reviewed version. Review them again before merging."
        case .notReviewed: "Review the sub-agent's changes with review_subagent_changes before merging."
        case .conflict(let detail): "The changes no longer apply cleanly to the workspace (files changed since the sub-agent started). Nothing was merged; the worktree is kept. \(detail)"
        case .tooLarge: "The sub-agent's patch exceeds 8 MB; review and merge it manually."
        }
    }
}

/// Throwaway Git worktrees for writer sub-agents. The base is a snapshot of
/// the parent's current files (tracked edits and untracked, non-ignored files)
/// written through a temporary index, so the user's index, branches and working
/// tree are never touched until an approved merge applies the reviewed patch.
public actor SubagentWorkspaceService {
    /// Settings › Git's prefix, then "subagent-".
    public static var branchPrefix: String { IntegrationPreferences.branchPrefix + "subagent-" }
    static let maximumPatchBytes = 8 * 1_024 * 1_024
    private let runner: any ProcessRunning
    private let root: URL

    public static var defaultRoot: URL {
        if let custom = IntegrationPreferences.worktreeRoot, !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return builtInRoot
    }

    public static var builtInRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory)
            .appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Worktrees", isDirectory: true)
    }

    public init(runner: any ProcessRunning = MacProcessRunner(), root: URL = SubagentWorkspaceService.defaultRoot) {
        self.runner = runner
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public func prepare(workspace: String, jobID: UUID, conversationID: UUID, title: String) async throws -> SubagentWorkspaceRecord {
        let selected = Self.canonical(workspace)
        let top = try await git(["rev-parse", "--show-toplevel"], in: selected)
        guard top.exitCode == 0 else { throw SubagentWorkspaceError.notRepository }
        let repository = Self.canonical(top.stdout.trimmingCharacters(in: .newlines))
        guard selected == repository || selected.hasPrefix(repository + "/") else { throw SubagentWorkspaceError.outsideRepository }
        let relative = selected == repository ? "" : String(selected.dropFirst(repository.count + 1))
        guard try await git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: repository).exitCode == 0 else {
            throw SubagentWorkspaceError.noCommit
        }
        let base = try await snapshot(repository)

        let short = String(jobID.uuidString.lowercased().prefix(8))
        let digest = SHA256.hash(data: Data(repository.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
        let container = root.appendingPathComponent(String(digest), isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.appendingPathComponent(short, isDirectory: true).path
        guard !FileManager.default.fileExists(atPath: path) else { throw SubagentWorkspaceError.unavailable("the worktree folder already exists") }
        let branch = Self.branchPrefix + short
        let added = try await git(["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branch, "--", path, base],
                                  in: repository, timeout: .seconds(180))
        guard added.exitCode == 0 else { throw SubagentWorkspaceError.unavailable(Self.excerpt(added.stderr)) }
        return SubagentWorkspaceRecord(jobID: jobID, conversationID: conversationID, title: title,
            repositoryRoot: repository, relativeWorkspace: relative, worktreePath: Self.canonical(path),
            branch: branch, baseCommit: base)
    }

    /// What the child changed, as a binary-safe patch relative to the repository root.
    public func changes(_ record: SubagentWorkspaceRecord) async throws -> SubagentChangeSet {
        try owned(record)
        let tree = try await tree(of: record.worktreePath, startingFrom: record.baseCommit)
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patchFile = scratch.appendingPathComponent("changes.patch")
        let diff = try await git(["diff", "--binary", "--full-index", "--no-renames", "--no-color", "--no-ext-diff",
                                  "--output=\(patchFile.path)", record.baseCommit, tree], in: record.worktreePath, timeout: .seconds(120))
        guard diff.exitCode == 0 else { throw SubagentWorkspaceError.unavailable(Self.excerpt(diff.stderr)) }
        let patch = (try? Data(contentsOf: patchFile)) ?? Data()
        guard patch.count <= Self.maximumPatchBytes else { throw SubagentWorkspaceError.tooLarge }
        let names = try await git(["diff", "--name-status", "-z", "--no-renames", record.baseCommit, tree], in: record.worktreePath)
        let counts = try await git(["diff", "--numstat", "-z", "--no-renames", record.baseCommit, tree], in: record.worktreePath)
        guard names.exitCode == 0, counts.exitCode == 0 else { throw SubagentWorkspaceError.unavailable("diff failed") }
        var numbers: [String: (Int?, Int?)] = [:]
        for entry in counts.stdout.split(separator: "\0") {
            let parts = entry.split(separator: "\t", maxSplits: 2).map(String.init)
            if parts.count == 3 { numbers[parts[2]] = (Int(parts[0]), Int(parts[1])) }
        }
        let fields = names.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [SubagentChangeSet.File] = []
        var index = 0
        while index + 1 < fields.count, !fields[index].isEmpty {
            let path = fields[index + 1]
            files.append(.init(status: String(fields[index].prefix(1)), path: path,
                               insertions: numbers[path]?.0, deletions: numbers[path]?.1))
            index += 2
        }
        let sha = SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined()
        return SubagentChangeSet(files: files, patch: patch, patchSHA256: sha)
    }

    /// Applies exactly the reviewed patch to the parent's working tree (not its
    /// index), only if it applies cleanly; otherwise nothing changes.
    public func merge(_ record: SubagentWorkspaceRecord) async throws -> SubagentChangeSet {
        try owned(record)
        guard let reviewed = record.reviewedPatchSHA256 else { throw SubagentWorkspaceError.notReviewed }
        let changes = try await changes(record)
        guard changes.patchSHA256 == reviewed else { throw SubagentWorkspaceError.changedSinceReview }
        guard !changes.isEmpty else { return changes }
        // Reject overlap at file granularity, including compatible-looking hunks.
        // A descendant patch may only change files that its immediate parent
        // has not changed since this child's base snapshot.
        let currentParent = try await tree(of: record.repositoryRoot, startingFrom: record.baseCommit)
        let changedPaths = changes.files.map(\.path)
        guard changedPaths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") &&
            !$0.split(separator: "/").contains("..") }) else { throw SubagentWorkspaceError.notOwned }
        let overlap = try await git(["--literal-pathspecs", "diff", "--name-only", "-z", record.baseCommit,
            currentParent, "--"] + changedPaths, in: record.repositoryRoot)
        guard overlap.exitCode == 0 else { throw SubagentWorkspaceError.unavailable(Self.excerpt(overlap.stderr)) }
        guard overlap.stdout.isEmpty else {
            throw SubagentWorkspaceError.conflict("The immediate parent also changed a file in this patch. The reviewed worktree is retained; inspect the overlap or delegate from a new snapshot.")
        }
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let patchFile = scratch.appendingPathComponent("merge.patch")
        try changes.patch.write(to: patchFile)
        let check = try await git(["apply", "--check", "--binary", "--whitespace=nowarn", patchFile.path], in: record.repositoryRoot)
        guard check.exitCode == 0 else { throw SubagentWorkspaceError.conflict(Self.excerpt(check.stderr)) }
        let apply = try await git(["apply", "--binary", "--whitespace=nowarn", patchFile.path], in: record.repositoryRoot)
        guard apply.exitCode == 0 else { throw SubagentWorkspaceError.conflict(Self.excerpt(apply.stderr)) }
        return changes
    }

    /// Removes an AIM-owned worktree and its throwaway branch (the child never commits on it).
    public func remove(_ record: SubagentWorkspaceRecord) async throws {
        try owned(record)
        if FileManager.default.fileExists(atPath: record.worktreePath) {
            let removed = try await git(["worktree", "remove", "--force", "--", record.worktreePath], in: record.repositoryRoot,
                                        timeout: .seconds(60))
            guard removed.exitCode == 0 else { throw SubagentWorkspaceError.unavailable(Self.excerpt(removed.stderr)) }
        } else {
            _ = try await git(["worktree", "prune"], in: record.repositoryRoot)
        }
        let branch = try await git(["branch", "-D", record.branch], in: record.repositoryRoot)
        guard branch.exitCode == 0 || branch.stderr.contains("not found") else {
            throw SubagentWorkspaceError.unavailable(Self.excerpt(branch.stderr))
        }
        let container = URL(fileURLWithPath: record.worktreePath).deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: container.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: container)
        }
    }

    // MARK: Helpers

    private func owned(_ record: SubagentWorkspaceRecord) throws {
        let path = Self.canonical(record.worktreePath)
        // The prefix and folder are settings: a worktree made before a change stays removable.
        let builtIn = Self.builtInRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") || path.hasPrefix(builtIn + "/"),
              let marker = record.branch.range(of: "subagent-", options: .backwards),
              !record.branch[marker.upperBound...].isEmpty, record.branch[marker.upperBound...].allSatisfy({ $0.isHexDigit }),
              GitCommitSummary.validHash(record.baseCommit) else { throw SubagentWorkspaceError.notOwned }
    }

    /// Commit object for the parent's current files; HEAD itself when nothing differs.
    private func snapshot(_ repository: String) async throws -> String {
        do { return try await GitWorkingTreeSnapshot(runner: runner).commit(repository: repository, message: "AIM sub-agent base snapshot").sha }
        catch let failure as GitWorkingTreeSnapshot.Failure { throw SubagentWorkspaceError.unavailable(failure.detail) }
    }

    private func tree(of directory: String, startingFrom base: String) async throws -> String {
        do { return try await GitWorkingTreeSnapshot(runner: runner).tree(of: directory, startingFrom: base) }
        catch let failure as GitWorkingTreeSnapshot.Failure { throw SubagentWorkspaceError.unavailable(failure.detail) }
    }

    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-subagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func excerpt(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }

    private func git(_ arguments: [String], in directory: String, environment: [String: String] = [:],
                     timeout: Duration = .seconds(30)) async throws -> ProcessOutput {
        try Task.checkCancellation()
        // "." in add is relative to the working directory; run git from the directory itself.
        return try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + arguments,
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            environment: environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat",
                                              "GIT_OPTIONAL_LOCKS": "0"]) { current, _ in current },
            timeout: timeout))
    }
}
