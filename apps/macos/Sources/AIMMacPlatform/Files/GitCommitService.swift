import AIMAgentKit
import Foundation

public struct GitCommitEntry: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let status: String
    public let path: String
}

public struct GitCommitPreview: Sendable, Equatable {
    public let branch: String
    public let ref: String
    public let head: String?
    public let tree: String
    public let entries: [GitCommitEntry]
}

public enum GitCommitError: LocalizedError {
    case chooseRepositoryRoot, detachedHead, nothingStaged, changedIndex, invalidMessage, unavailable, missingIdentity

    public var errorDescription: String? {
        switch self {
        case .chooseRepositoryRoot: "Choose the Git repository root as the workspace before committing; a subfolder could hide other staged files."
        case .detachedHead: "Select a local branch before committing. Detached HEAD is not supported in AIM yet."
        case .nothingStaged: "There are no staged changes to commit. Review and stage files first."
        case .changedIndex: "The branch or staged content changed since the preview. Refresh and review before committing."
        case .invalidMessage: "Enter a commit message without control characters, up to 8 KB."
        case .unavailable: "Git could not create the commit. Inspect the repository and try again."
        case .missingIdentity: "Git needs an author identity. Configure user.name and user.email for this repository before committing."
        }
    }
}

/// Commits an exact confirmed index tree on the selected local branch. The expected HEAD is
/// compared and swapped; concurrent index edits cannot be silently added to this commit.
/// Hooks and signing are intentionally skipped and must be disclosed by the calling UI.
public actor GitCommitService {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = MacProcessRunner()) { self.runner = runner }

    public func preview(workspace: String) async throws -> GitCommitPreview {
        try Task.checkCancellation()
        let root = try await git(["rev-parse", "--show-toplevel"], workspace: workspace)
        guard root.exitCode == 0, !root.wasTruncated else { throw GitCommitError.unavailable }
        let selected = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let repoRoot = URL(fileURLWithPath: root.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard selected == repoRoot else { throw GitCommitError.chooseRepositoryRoot }

        let symbolic = try await git(["symbolic-ref", "--quiet", "HEAD"], workspace: selected)
        guard symbolic.exitCode == 0, !symbolic.wasTruncated else { throw GitCommitError.detachedHead }
        let ref = symbolic.stdout.trimmingCharacters(in: .newlines)
        guard ref.hasPrefix("refs/heads/"), ref.utf8.count < 256 else { throw GitCommitError.detachedHead }
        let headResult = try await git(["rev-parse", "--verify", "--quiet", "HEAD"], workspace: selected)
        let head: String?
        switch headResult.exitCode {
        case 0:
            let value = headResult.stdout.trimmingCharacters(in: .newlines)
            guard GitCommitSummary.validHash(value), !headResult.wasTruncated else { throw GitCommitError.unavailable }
            head = value
        case 1: head = nil
        default: throw GitCommitError.unavailable
        }

        let treeBefore = try await git(["write-tree"], workspace: selected)
        let startingTree = treeBefore.stdout.trimmingCharacters(in: .newlines)
        guard treeBefore.exitCode == 0, GitCommitSummary.validHash(startingTree) else {
            throw GitCommitError.unavailable
        }
        let staged = try await git(["diff", "--cached", "--name-status", "-z", "--no-renames"], workspace: selected)
        guard staged.exitCode == 0, !staged.wasTruncated else { throw GitCommitError.unavailable }
        let fields = staged.stdout.split(separator: "\0", omittingEmptySubsequences: true)
        guard !fields.isEmpty else { throw GitCommitError.nothingStaged }
        guard fields.count.isMultiple(of: 2) else { throw GitCommitError.unavailable }
        let entries = try stride(from: 0, to: fields.count, by: 2).map { index in
            let status = String(fields[index])
            let path = String(fields[index + 1])
            guard !status.isEmpty, !path.isEmpty else { throw GitCommitError.unavailable }
            return GitCommitEntry(status: status, path: path)
        }

        let treeResult = try await git(["write-tree"], workspace: selected)
        let tree = treeResult.stdout.trimmingCharacters(in: .newlines)
        guard treeResult.exitCode == 0, GitCommitSummary.validHash(tree) else { throw GitCommitError.unavailable }
        guard tree == startingTree else { throw GitCommitError.changedIndex }
        return GitCommitPreview(branch: String(ref.dropFirst("refs/heads/".count)), ref: ref,
                                head: head, tree: tree, entries: entries)
    }

    public func commit(workspace: String, expected: GitCommitPreview, message: String) async throws -> String {
        let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, subject.utf8.count <= 8_192,
              !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitCommitError.invalidMessage
        }
        let current: GitCommitPreview
        do { current = try await preview(workspace: workspace) }
        catch GitCommitError.nothingStaged { throw GitCommitError.changedIndex }
        guard current == expected else { throw GitCommitError.changedIndex }
        for identity in ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"] {
            let result = try await git(["var", identity], workspace: workspace)
            guard result.exitCode == 0, !result.stdout.isEmpty else { throw GitCommitError.missingIdentity }
        }
        var arguments = ["commit-tree", expected.tree]
        if let head = expected.head { arguments += ["-p", head] }
        arguments += ["-m", subject]
        let created = try await git(arguments, workspace: workspace)
        guard created.exitCode == 0 else {
            throw created.stderr.contains("unable to auto-detect email address") ? GitCommitError.missingIdentity : GitCommitError.unavailable
        }
        let hash = created.stdout.trimmingCharacters(in: .newlines)
        guard !created.wasTruncated, GitCommitSummary.validHash(hash) else { throw GitCommitError.unavailable }
        try Task.checkCancellation()
        let old = expected.head ?? String(repeating: "0", count: hash.count)
        let updated = try await git(["update-ref", "-m", "commit: \(subject)", expected.ref, hash, old], workspace: workspace)
        guard updated.exitCode == 0, !updated.wasTruncated else { throw GitCommitError.changedIndex }
        return hash
    }

    private func git(_ arguments: [String], workspace: String) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgsign=false"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"],
            timeout: .seconds(30)
        ))
        try Task.checkCancellation()
        guard !output.wasTruncated else { throw GitCommitError.unavailable }
        return output
    }
}
