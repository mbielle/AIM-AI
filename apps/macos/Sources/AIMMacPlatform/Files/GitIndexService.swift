import AIMAgentKit
import Foundation

public enum GitIndexError: LocalizedError {
    case changedSelection, conflicted, unavailable

    public var errorDescription: String? {
        switch self {
        case .changedSelection: "The selected Git change or its preview changed. Refresh and review it again."
        case .conflicted: "Resolve the conflict before staging this file."
        case .unavailable: "Git could not update the index. Check the repository and try again."
        }
    }
}

/// Explicit index mutations for one reviewed file. Never uses a shell or touches the worktree.
/// The exact status and preview are checked again before invoking Git; external writes after
/// that check remain possible, so the UI must not describe this as an atomic snapshot.
public actor GitIndexService {
    private let runner: any ProcessRunning
    private let review: GitReviewService

    public init(runner: any ProcessRunning = MacProcessRunner()) {
        self.runner = runner
        self.review = GitReviewService(runner: runner)
    }

    public func stage(workspace: String, change: GitChange, reviewedDiff: String) async throws {
        guard !change.isConflicted else { throw GitIndexError.conflicted }
        guard change.isUnstaged else { throw GitIndexError.changedSelection }
        let paths = try await validate(workspace: workspace, change: change, reviewedDiff: reviewedDiff, staged: false)
        try await mutate(["add", "-A", "--"] + paths, workspace: workspace)
    }

    public func unstage(workspace: String, change: GitChange, reviewedDiff: String) async throws {
        guard change.isStaged, !change.isConflicted else { throw GitIndexError.changedSelection }
        let paths = try await validate(workspace: workspace, change: change, reviewedDiff: reviewedDiff, staged: true)
        let head = try await execute(["rev-parse", "--verify", "--quiet", "HEAD"], workspace: workspace)
        if head.exitCode == 0 {
            try await mutate(["restore", "--staged", "--"] + paths, workspace: workspace)
        } else if head.exitCode == 1, change.indexStatus == "A", change.originalPath == nil {
            // On an unborn branch there is no HEAD to restore. --cached never deletes the file.
            try await mutate(["rm", "--cached", "-f", "--"] + paths, workspace: workspace)
        } else {
            throw GitIndexError.unavailable
        }
    }

    private func validate(workspace: String, change: GitChange, reviewedDiff: String, staged: Bool) async throws -> [String] {
        try Task.checkCancellation()
        guard !reviewedDiff.isEmpty,
              try await review.snapshot(workspace: workspace).changes.contains(change),
              try await review.diff(workspace: workspace, path: change.path, staged: staged) == reviewedDiff else {
            throw GitIndexError.changedSelection
        }
        let prefix = try await execute(["rev-parse", "--show-prefix"], workspace: workspace)
        guard prefix.exitCode == 0, !prefix.wasTruncated else { throw GitIndexError.unavailable }
        let scope = prefix.stdout.hasSuffix("\n") ? String(prefix.stdout.dropLast()) : prefix.stdout
        let selected = [change.path] + (change.originalPath.map { [$0] } ?? [])
        guard selected.allSatisfy({ path in
            !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
            !path.split(separator: "/").contains("..") && path.hasPrefix(scope)
        }) else { throw GitIndexError.changedSelection }
        try Task.checkCancellation()
        return selected.map { ":(top,literal)\($0)" }
    }

    private func mutate(_ arguments: [String], workspace: String) async throws {
        let output = try await execute(arguments, workspace: workspace)
        guard output.exitCode == 0, !output.wasTruncated else { throw GitIndexError.unavailable }
    }

    private func execute(_ arguments: [String], workspace: String) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"],
            timeout: .seconds(15)
        ))
        try Task.checkCancellation()
        guard !output.wasTruncated else { throw GitIndexError.unavailable }
        return output
    }
}
