import AIMAgentKit
import Foundation

public struct GitWorktree: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let head: String?
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let lockedReason: String?
    public let prunableReason: String?

    public var isAvailable: Bool { !isBare && lockedReason == nil && prunableReason == nil }
}

public struct GitWorktreeCreationPreview: Sendable, Equatable {
    public let repositoryRoot: String
    public let targetPath: String
    public let branch: String
    public let startCommit: String
}

public enum GitWorktreeError: LocalizedError {
    case invalidOutput, unavailable, changedSelection, chooseRepositoryRoot
    case invalidFolderName, invalidBranch, targetExists, branchExists, noCommit
    case changedSincePreview, creationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidOutput: "Git returned an unreadable worktree list. Refresh and try again."
        case .unavailable: "Git could not read worktrees for this workspace."
        case .changedSelection: "This worktree is no longer available in the selected repository. Refresh the list."
        case .chooseRepositoryRoot: "Choose a Git repository root as the workspace before creating a worktree."
        case .invalidFolderName: "Choose a single folder name using letters, numbers, dots, underscores or hyphens."
        case .invalidBranch: "Choose a valid new Git branch name."
        case .targetExists: "The target folder already exists. Choose another name; AIM will not overwrite it."
        case .branchExists: "This branch already exists. Choose a new branch name."
        case .noCommit: "Create an initial commit before adding a worktree."
        case .changedSincePreview: "The repository, commit, branch or target changed after the preview. Review it again."
        case .creationFailed: "Git could not create the worktree. Refresh the list and inspect the target folder before retrying."
        }
    }
}

/// Worktree selection and explicitly confirmed creation. Existing branches and
/// paths are never overwritten; removal and force operations are not exposed.
public actor GitWorktreeService {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = MacProcessRunner()) { self.runner = runner }

    public func list(workspace: String) async throws -> [GitWorktree] {
        let output = try await git(["worktree", "list", "--porcelain", "-z"], workspace: workspace)
        guard output.exitCode == 0 else { throw GitWorktreeError.unavailable }
        return try Self.parse(output.stdout)
    }

    public func previewCreation(workspace: String, folderName: String,
                                branch: String) async throws -> GitWorktreeCreationPreview {
        let selected = URL(fileURLWithPath: workspace, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let rootOutput = try await git(["rev-parse", "--show-toplevel"], workspace: selected)
        guard rootOutput.exitCode == 0 else { throw GitWorktreeError.unavailable }
        let root = URL(fileURLWithPath: rootOutput.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard selected == root else { throw GitWorktreeError.chooseRepositoryRoot }

        guard !folderName.isEmpty, folderName.utf8.count <= 64, folderName != ".", folderName != "..",
              folderName.first?.isLetter == true || folderName.first?.isNumber == true,
              folderName.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
              }) else { throw GitWorktreeError.invalidFolderName }
        let target = URL(fileURLWithPath: root, isDirectory: true)
            .deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true).path
        guard !Self.pathExistsIncludingSymlink(target) else { throw GitWorktreeError.targetExists }

        guard !branch.isEmpty, branch.utf8.count <= 255, !branch.hasPrefix("-"),
              !branch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitWorktreeError.invalidBranch
        }
        let branchCheck = try await git(["check-ref-format", "--branch", branch], workspace: root)
        guard branchCheck.exitCode == 0 else { throw GitWorktreeError.invalidBranch }
        let existing = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], workspace: root)
        guard existing.exitCode == 1 else {
            if existing.exitCode == 0 { throw GitWorktreeError.branchExists }
            throw GitWorktreeError.unavailable
        }
        let head = try await git(["rev-parse", "--verify", "HEAD"], workspace: root)
        guard head.exitCode == 0 else { throw GitWorktreeError.noCommit }
        let commit = head.stdout.trimmingCharacters(in: .newlines)
        guard GitCommitSummary.validHash(commit) else { throw GitWorktreeError.invalidOutput }
        return GitWorktreeCreationPreview(repositoryRoot: root, targetPath: target,
                                          branch: branch, startCommit: commit)
    }

    public func create(workspace: String, expected: GitWorktreeCreationPreview) async throws -> GitWorktree {
        let current = try await previewCreation(
            workspace: workspace,
            folderName: URL(fileURLWithPath: expected.targetPath).lastPathComponent,
            branch: expected.branch)
        guard current == expected else { throw GitWorktreeError.changedSincePreview }
        let output = try await git(["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b",
                                    current.branch, current.targetPath, current.startCommit],
                                   workspace: current.repositoryRoot, timeout: .seconds(120))
        guard output.exitCode == 0 else { throw GitWorktreeError.creationFailed }
        let validated = try await validatedWorkspace(currentWorkspace: current.repositoryRoot,
                                                     selectedPath: current.targetPath)
        guard let entry = try await list(workspace: current.repositoryRoot)
            .first(where: {
                URL(fileURLWithPath: $0.path, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL.path == validated
            }), entry.branch == "refs/heads/\(current.branch)",
              entry.head == current.startCommit else { throw GitWorktreeError.creationFailed }
        return entry
    }

    private static func pathExistsIncludingSymlink(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Return the canonical selected root only if it still belongs to this Git worktree list.
    public func validatedWorkspace(currentWorkspace: String, selectedPath: String) async throws -> String {
        let current = try await list(workspace: currentWorkspace)
        let selected = URL(fileURLWithPath: selectedPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        guard let entry = current.first(where: {
            URL(fileURLWithPath: $0.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path == selected
        }), entry.isAvailable else { throw GitWorktreeError.changedSelection }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitWorktreeError.changedSelection
        }
        let root = try await git(["rev-parse", "--show-toplevel"], workspace: selected)
        guard root.exitCode == 0,
              URL(fileURLWithPath: root.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path == selected else {
            throw GitWorktreeError.changedSelection
        }
        let originalCommonDir = try await commonDirectory(workspace: currentWorkspace)
        let selectedCommonDir = try await commonDirectory(workspace: selected)
        guard originalCommonDir == selectedCommonDir else { throw GitWorktreeError.changedSelection }
        return selected
    }

    private func commonDirectory(workspace: String) async throws -> String {
        let result = try await git(["rev-parse", "--git-common-dir"], workspace: workspace)
        guard result.exitCode == 0 else { throw GitWorktreeError.changedSelection }
        let raw = result.stdout.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else { throw GitWorktreeError.changedSelection }
        return URL(fileURLWithPath: raw,
                   relativeTo: URL(fileURLWithPath: workspace, isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func parse(_ text: String) throws -> [GitWorktree] {
        guard text.hasSuffix("\0\0") else { throw GitWorktreeError.invalidOutput }
        let records = text.components(separatedBy: "\0\0").dropLast()
        guard !records.isEmpty, records.count <= 1_000 else { throw GitWorktreeError.invalidOutput }
        return try records.map { record in
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard let first = fields.first, first.hasPrefix("worktree "), fields.count >= 2 else {
                throw GitWorktreeError.invalidOutput
            }
            let path = String(first.dropFirst("worktree ".count))
            guard path.hasPrefix("/"), !path.contains("\0"), !path.isEmpty else {
                throw GitWorktreeError.invalidOutput
            }
            var head: String?, branch: String?, bare = false, detached = false
            var locked: String?, prunable: String?
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
                else if field.hasPrefix("branch ") { branch = String(field.dropFirst(7)) }
                else if field == "bare" { bare = true }
                else if field == "detached" { detached = true }
                else if field == "locked" || field.hasPrefix("locked ") {
                    locked = field == "locked" ? "Locked" : String(field.dropFirst(7))
                } else if field == "prunable" || field.hasPrefix("prunable ") {
                    prunable = field == "prunable" ? "Prunable" : String(field.dropFirst(9))
                } else { throw GitWorktreeError.invalidOutput }
            }
            guard head.map(GitCommitSummary.validHash) ?? bare,
                  branch == nil || branch!.hasPrefix("refs/heads/"),
                  !bare || branch == nil else { throw GitWorktreeError.invalidOutput }
            return GitWorktree(path: path, head: head, branch: branch, isBare: bare,
                               isDetached: detached, lockedReason: locked, prunableReason: prunable)
        }
    }

    private func git(_ arguments: [String], workspace: String,
                     timeout: Duration = .seconds(15)) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"],
            timeout: timeout
        ))
        try Task.checkCancellation()
        guard !output.wasTruncated, output.stdout.utf8.count <= 512 * 1_024 else { throw GitWorktreeError.invalidOutput }
        return output
    }
}
