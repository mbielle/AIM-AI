import AIMAgentKit
import Foundation

/// Snapshots a working tree's files (tracked edits and untracked, non-ignored
/// files) as Git objects through a private temporary index, so the person's
/// index, branches and files are never touched.
struct GitWorkingTreeSnapshot: Sendable {
    let runner: any ProcessRunning

    struct Failure: Error { let detail: String }

    /// Commit object for the directory's current files on top of HEAD; HEAD itself when nothing differs.
    func commit(repository: String, message: String) async throws -> (sha: String, changed: Bool) {
        let head = try await git(["rev-parse", "HEAD"], in: repository)
        let headSHA = head.stdout.trimmingCharacters(in: .newlines)
        guard head.exitCode == 0, GitCommitSummary.validHash(headSHA) else { throw Failure(detail: "no commit") }
        let tree = try await tree(of: repository, startingFrom: "HEAD")
        let headTree = try await git(["rev-parse", "HEAD^{tree}"], in: repository).stdout.trimmingCharacters(in: .newlines)
        guard tree != headTree else { return (headSHA, false) }
        let identity = ["GIT_AUTHOR_NAME": "AIM", "GIT_AUTHOR_EMAIL": "aim@localhost.invalid",
                        "GIT_COMMITTER_NAME": "AIM", "GIT_COMMITTER_EMAIL": "aim@localhost.invalid"]
        let commit = try await git(["commit-tree", "--no-gpg-sign", tree, "-p", headSHA, "-m", message],
                                   in: repository, environment: identity)
        let sha = commit.stdout.trimmingCharacters(in: .newlines)
        guard commit.exitCode == 0, GitCommitSummary.validHash(sha) else { throw Failure(detail: Self.excerpt(commit.stderr)) }
        return (sha, true)
    }

    /// Tree of a working directory's files (respecting .gitignore) via a private index.
    func tree(of directory: String, startingFrom base: String) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aim-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]
        let read = try await git(["read-tree", base], in: directory, environment: index)
        let add = try await git(["add", "-A", "--", "."], in: directory, environment: index, timeout: .seconds(180))
        let write = try await git(["write-tree"], in: directory, environment: index)
        let tree = write.stdout.trimmingCharacters(in: .newlines)
        guard read.exitCode == 0, add.exitCode == 0, write.exitCode == 0, GitCommitSummary.validHash(tree) else {
            throw Failure(detail: Self.excerpt(read.stderr + add.stderr + write.stderr))
        }
        return tree
    }

    /// Saves the current files under `refs/aim/recovery/<stamp>` when they differ from HEAD.
    func recoveryPoint(in workspace: String) async throws -> (reference: String, sha: String)? {
        let top = try await git(["rev-parse", "--show-toplevel"], in: workspace)
        guard top.exitCode == 0 else { return nil }
        let root = top.stdout.trimmingCharacters(in: .newlines)
        let snapshot = try await commit(repository: root, message: "AIM recovery point before a command that discards local changes")
        guard snapshot.changed else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let reference = "refs/aim/recovery/\(formatter.string(from: .now))-\(snapshot.sha.prefix(7))"
        let update = try await git(["update-ref", reference, snapshot.sha], in: root)
        guard update.exitCode == 0 else { throw Failure(detail: Self.excerpt(update.stderr)) }
        return (reference, snapshot.sha)
    }

    func git(_ arguments: [String], in directory: String, environment: [String: String] = [:],
             timeout: Duration = .seconds(30)) async throws -> ProcessOutput {
        try Task.checkCancellation()
        return try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + arguments,
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            environment: environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat",
                                              "GIT_OPTIONAL_LOCKS": "0"]) { current, _ in current },
            timeout: timeout))
    }

    static func excerpt(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }
}
