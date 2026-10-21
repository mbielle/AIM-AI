import AIMAgentKit
import Foundation

public struct GitPushRemote: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let destination: String
}

public struct GitPushPreview: Sendable, Equatable {
    public let repositoryRoot: String
    public let remote: GitPushRemote
    public let branch: String
    public let head: String
    public var refspec: String { "refs/heads/\(branch):refs/heads/\(branch)" }
}

public enum GitPushError: LocalizedError {
    case chooseRepositoryRoot, detachedHead, noCommit, noRemotes, invalidRemote, unsafeDestination
    case changedSincePreview, rejected, unavailable

    public var errorDescription: String? {
        switch self {
        case .chooseRepositoryRoot: "Choose the repository root as the workspace before pushing."
        case .detachedHead: "Select a local branch before pushing."
        case .noCommit: "Create a local commit before pushing."
        case .noRemotes: "This repository has no Git remote. Add one in Git before pushing."
        case .invalidRemote: "Choose a Git remote from this repository."
        case .unsafeDestination: "The remote URL contains credentials, an unsupported scheme or control characters. Configure a safe Git remote first."
        case .changedSincePreview: "The branch, commit or remote changed after the preview. Refresh before pushing."
        case .rejected: "Git rejected the non-force push. Fetch and review remote changes or check your credentials before retrying."
        case .unavailable: "Git could not complete the push. Check network access and the remote configuration."
        }
    }
}

/// The only push route in the native UI: a selected, visible remote and branch,
/// a fresh local-state check, an explicit user confirmation, and never --force.
public actor GitPushService {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = MacProcessRunner()) { self.runner = runner }

    public func remotes(workspace: String) async throws -> [GitPushRemote] {
        let root = try await repositoryRoot(workspace: workspace)
        let listed = try await git(["remote"], workspace: root)
        guard listed.exitCode == 0 else { throw GitPushError.unavailable }
        let names = listed.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !names.isEmpty else { throw GitPushError.noRemotes }
        var remotes: [GitPushRemote] = []
        for name in names {
            guard Self.validRemoteName(name) else { throw GitPushError.invalidRemote }
            remotes.append(GitPushRemote(name: name, destination: try await destination(for: name, workspace: root)))
        }
        return remotes
    }

    public func preview(workspace: String, remote name: String) async throws -> GitPushPreview {
        let root = try await repositoryRoot(workspace: workspace)
        guard Self.validRemoteName(name) else { throw GitPushError.invalidRemote }
        let available = try await remotes(workspace: root)
        guard let remote = available.first(where: { $0.name == name }) else { throw GitPushError.invalidRemote }
        let branchOutput = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], workspace: root)
        guard branchOutput.exitCode == 0 else { throw GitPushError.detachedHead }
        let branch = branchOutput.stdout.trimmingCharacters(in: .newlines)
        guard !branch.isEmpty, branch.utf8.count <= 255, !branch.contains("\n"), !branch.contains("\0") else {
            throw GitPushError.detachedHead
        }
        let headOutput = try await git(["rev-parse", "--verify", "HEAD"], workspace: root)
        guard headOutput.exitCode == 0 else { throw GitPushError.noCommit }
        let head = headOutput.stdout.trimmingCharacters(in: .newlines)
        guard GitCommitSummary.validHash(head) else { throw GitPushError.unavailable }
        return GitPushPreview(repositoryRoot: root, remote: remote, branch: branch, head: head)
    }

    public func push(workspace: String, expected: GitPushPreview) async throws {
        let current = try await preview(workspace: workspace, remote: expected.remote.name)
        guard current == expected else { throw GitPushError.changedSincePreview }
        let output = try await git(["push", "--porcelain", "--no-verify", "--", expected.remote.destination, expected.refspec],
                                   workspace: current.repositoryRoot, timeout: .seconds(120))
        guard output.exitCode == 0 else { throw GitPushError.rejected }
    }

    private func repositoryRoot(workspace: String) async throws -> String {
        let selected = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let output = try await git(["rev-parse", "--show-toplevel"], workspace: selected)
        guard output.exitCode == 0 else { throw GitPushError.unavailable }
        let root = URL(fileURLWithPath: output.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard selected == root else { throw GitPushError.chooseRepositoryRoot }
        return root
    }

    private func destination(for remote: String, workspace: String) async throws -> String {
        let output = try await git(["remote", "get-url", "--push", remote], workspace: workspace)
        guard output.exitCode == 0 else { throw GitPushError.invalidRemote }
        let value = output.stdout.trimmingCharacters(in: .newlines)
        guard !value.isEmpty, value.utf8.count <= 2_048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\n"), !value.contains("\r") else { throw GitPushError.unsafeDestination }
        if value.contains("://") {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "ssh", "file"].contains(scheme),
                  (scheme == "file" || components.host?.isEmpty == false),
                  components.password == nil,
                  components.query == nil, components.fragment == nil else { throw GitPushError.unsafeDestination }
            if scheme == "file" {
                guard (components.host ?? "").isEmpty || components.host == "localhost",
                      components.path.hasPrefix("/") else { throw GitPushError.unsafeDestination }
            }
            if scheme == "ssh" {
                if let user = components.user {
                    guard !user.isEmpty, user.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }) else {
                        throw GitPushError.unsafeDestination
                    }
                }
            } else if components.user != nil { throw GitPushError.unsafeDestination }
        } else if value.hasPrefix("/") {
            // Explicit local bare repositories are useful for offline workflows.
        } else {
            let parts = value.split(separator: ":", maxSplits: 1)
            let authority = parts.first?.split(separator: "@", maxSplits: 1) ?? []
            guard parts.count == 2, authority.count == 2,
                  !authority[0].isEmpty,
                  authority[0].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }),
                  !authority[1].isEmpty,
                  authority[1].first?.isLetter == true || authority[1].first?.isNumber == true,
                  authority[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) }),
                  !parts[1].isEmpty else {
                throw GitPushError.unsafeDestination
            }
        }
        return value
    }

    private static func validRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.first != "-" && name != "." && name != ".." &&
        name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/").contains($0) }
    }

    private func git(_ arguments: [String], workspace: String, timeout: Duration = .seconds(20)) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
                          "GIT_SSH_COMMAND": "/usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes", "GIT_PAGER": "cat"],
            timeout: timeout
        ))
        try Task.checkCancellation()
        guard !output.wasTruncated else { throw GitPushError.unavailable }
        return output
    }
}
