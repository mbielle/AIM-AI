import AIMAgentKit
import Foundation

public struct GitChange: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let workingStatus: Character
    public var isUntracked: Bool { indexStatus == "?" }
    public var isConflicted: Bool {
        ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains("\(indexStatus)\(workingStatus)")
    }
    public var isStaged: Bool { !isUntracked && indexStatus != " " && !isConflicted }
    public var isUnstaged: Bool { isUntracked || workingStatus != " " || isConflicted }
    public var status: String { "\(indexStatus)\(workingStatus)" }
}

public struct GitReviewSnapshot: Sendable, Equatable {
    public let branch: String
    public let changes: [GitChange]

    /// Porcelain v1 -z is unquoted; rename/copy records store destination then source.
    public static func parse(_ output: String) throws -> Self {
        guard output.hasSuffix("\0") else { throw GitReviewError.invalidStatus }
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        fields.removeLast()
        guard let header = fields.first, header.hasPrefix("## ") else { throw GitReviewError.invalidStatus }
        var changes: [GitChange] = []
        var cursor = 1
        while cursor < fields.count {
            let record = Array(fields[cursor])
            guard record.count > 3, record[2] == " " else { throw GitReviewError.invalidStatus }
            let x = record[0], y = record[1]
            guard " MTADRCU?!".contains(x), " MTADRCU?!".contains(y) else { throw GitReviewError.invalidStatus }
            let path = String(record.dropFirst(3))
            cursor += 1
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard cursor < fields.count, !fields[cursor].isEmpty else { throw GitReviewError.invalidStatus }
                original = String(fields[cursor])
                cursor += 1
            }
            changes.append(GitChange(path: path, originalPath: original, indexStatus: x, workingStatus: y))
        }
        return Self(branch: String(header.dropFirst(3)), changes: changes)
    }
}

public struct GitCommitSummary: Identifiable, Sendable, Equatable {
    public var id: String { hash }
    public let hash: String
    public let subject: String
    public let authoredAt: String

    static func parse(_ output: String) throws -> [Self] {
        guard !output.isEmpty else { return [] }
        guard output.hasSuffix("\0") else { throw GitReviewError.invalidStatus }
        let fields = output.dropLast().split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count % 3 == 0, fields.count <= 300 else { throw GitReviewError.invalidStatus }
        return try stride(from: 0, to: fields.count, by: 3).map { index in
            let hash = String(fields[index])
            guard validHash(hash) else { throw GitReviewError.invalidStatus }
            return Self(hash: hash, subject: String(fields[index + 1]), authoredAt: String(fields[index + 2]))
        }
    }

    static func validHash(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum GitReviewError: LocalizedError {
    case invalidStatus, unavailable, changedSelection, outputTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidStatus: "Git returned an unreadable status. Refresh the review."
        case .unavailable: "This workspace is not an accessible Git repository, or Git could not read it."
        case .changedSelection: "This file is no longer in the workspace changes. Refresh the review."
        case .outputTooLarge: "This Git result exceeds the preview limit. Use an external Git client to inspect it."
        }
    }
}

/// Read-only, local review. Never invokes shell, hooks, external diff or text conversion helpers.
public actor GitReviewService {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = MacProcessRunner()) { self.runner = runner }

    /// Latest 100 commits reachable from HEAD that affect the selected directory.
    public func history(workspace: String) async throws -> [GitCommitSummary] {
        let head = try await execute(["rev-parse", "--verify", "--quiet", "HEAD"], workspace: workspace)
        if head.exitCode == 1 { return [] } // An initialized repository's unborn branch.
        guard head.exitCode == 0 else { throw GitReviewError.unavailable }
        let text = try await run(["log", "-100", "--full-history", "--show-pulls", "-z", "--format=%H%x00%s%x00%aI", "--no-color", "--", "."], workspace: workspace)
        guard text.utf8.count <= 512 * 1_024 else { throw GitReviewError.outputTooLarge }
        return try GitCommitSummary.parse(text)
    }

    public func commitSummary(workspace: String, hash: String) async throws -> String {
        try await validateCommit(workspace: workspace, hash: hash)
        let text = try await run(["show", "--format=fuller", "--stat", "--no-color", "--no-ext-diff", "--no-textconv", hash, "--", "."], workspace: workspace)
        guard text.utf8.count <= 512 * 1_024 else { throw GitReviewError.outputTooLarge }
        return text
    }

    /// Read-only patch against the first parent; root commits compare with the empty tree.
    public func commitDiff(workspace: String, hash: String) async throws -> String {
        try await validateCommit(workspace: workspace, hash: hash)
        let lineage = try await run(["rev-list", "--parents", "-n", "1", hash, "--"], workspace: workspace)
        let objects = lineage.split(whereSeparator: \.isWhitespace).map(String.init)
        guard objects.first == hash, objects.allSatisfy(GitCommitSummary.validHash) else {
            throw GitReviewError.invalidStatus
        }
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3", "--submodule=short"]
        let args: [String]
        if objects.count > 1 {
            args = ["diff"] + options + [objects[1], hash, "--", "."]
        } else {
            args = ["diff-tree", "--root", "--no-commit-id", "-r", "-p"] + options + [hash, "--", "."]
        }
        let text = try await run(args, workspace: workspace)
        guard text.utf8.count <= 512 * 1_024 else { throw GitReviewError.outputTooLarge }
        return text.isEmpty ? "No differences in this workspace against the first parent (or empty tree for a root commit)." : text
    }

    private func validateCommit(workspace: String, hash: String) async throws {
        guard GitCommitSummary.validHash(hash) else { throw GitReviewError.changedSelection }
        // Accept only a commit currently offered by this workspace's bounded history.
        guard try await history(workspace: workspace).contains(where: { $0.hash == hash }) else {
            throw GitReviewError.changedSelection
        }
    }

    public func snapshot(workspace: String) async throws -> GitReviewSnapshot {
        let text = try await run(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--", "."], workspace: workspace)
        return try GitReviewSnapshot.parse(text)
    }

    public func diff(workspace: String, path: String, staged: Bool) async throws -> String {
        // Revalidate selection against the workspace-scoped status, not caller-provided paths.
        let state = try await snapshot(workspace: workspace)
        guard let change = state.changes.first(where: { $0.path == path }) else { throw GitReviewError.changedSelection }
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw GitReviewError.changedSelection }
        if change.isUntracked {
            guard !staged else { throw GitReviewError.changedSelection }
            let prefixText = try await run(["rev-parse", "--show-prefix"], workspace: workspace)
            let prefix = prefixText.hasSuffix("\n") ? String(prefixText.dropLast()) : prefixText
            guard path.hasPrefix(prefix) else { throw GitReviewError.changedSelection }
            let relative = String(path.dropFirst(prefix.count))
            let url = URL(fileURLWithPath: workspace, isDirectory: true).appendingPathComponent(relative)
            // A new symlink represents the link itself, never the target's contents.
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                return "Untracked symbolic link — target contents are not previewed."
            }
            let text = try await WorkspaceFileToolService().previewText(workspace: workspace, path: relative)
            try Task.checkCancellation()
            guard text.utf8.count <= 256 * 1_024 else { throw GitReviewError.outputTooLarge }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            // Explicit local snapshot, not a patch that can be applied or staged.
            let content = lines.enumerated().map { index, line in "\(index + 1)  \(line)" }.joined(separator: "\n")
            let preview = "Untracked file · local text snapshot · not staged\n\n" + (text.isEmpty ? "[Empty file]" : content)
            guard preview.utf8.count <= 512 * 1_024 else { throw GitReviewError.outputTooLarge }
            return preview
        }
        // Status paths are repository-relative even when the chosen workspace is a subdirectory.
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3"]
        if staged { args.append("--cached") }
        args += ["--", ":(top,literal)\(path)"]
        // Show the old side of a rename only if it is still inside the chosen workspace.
        if let original = change.originalPath {
            let prefixText = try await run(["rev-parse", "--show-prefix"], workspace: workspace)
            let prefix = prefixText.hasSuffix("\n") ? String(prefixText.dropLast()) : prefixText
            if original.hasPrefix(prefix), !original.hasPrefix("/"), !original.split(separator: "/").contains("..") {
                args.append(":(top,literal)\(original)")
            }
        }
        let result = try await run(args, workspace: workspace)
        guard result.utf8.count <= 512 * 1_024 else { throw GitReviewError.outputTooLarge }
        return result.isEmpty ? "No textual differences on this side. The file may have changed since the last refresh." : result
    }

    private func run(_ arguments: [String], workspace: String) async throws -> String {
        let output = try await execute(arguments, workspace: workspace)
        guard output.exitCode == 0 else { throw GitReviewError.unavailable }
        return output.stdout
    }

    private func execute(_ arguments: [String], workspace: String) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"],
            timeout: .seconds(15)
        ))
        try Task.checkCancellation()
        guard !output.wasTruncated else { throw GitReviewError.outputTooLarge }
        return output
    }
}
