import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class GitReviewTests: XCTestCase {
    func testHistoryParserPreservesSubjectsAndRejectsMalformedHashes() throws {
        let hash = String(repeating: "a", count: 40)
        let commits = try GitCommitSummary.parse("\(hash)\0Étoile\t subject\0date\0")
        XCTAssertEqual(commits.first?.subject, "Étoile\t subject")
        XCTAssertEqual(commits.first?.hash, hash)
        XCTAssertEqual(try GitCommitSummary.parse(""), [])
        XCTAssertThrowsError(try GitCommitSummary.parse("--all\0subject\0date\0"))
        XCTAssertThrowsError(try GitCommitSummary.parse("\(hash)\0subject\0date"))
        XCTAssertThrowsError(try GitCommitSummary.parse("\(hash)\0subject\0"))
    }

    func testRealHistoryIsWorkspaceScopedAndDoesNotMutateIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let emptyHistory = try await GitReviewService().history(workspace: root.path)
        XCTAssertTrue(emptyHistory.isEmpty)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let commit = ["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m"]
        try "initial".write(to: sub.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(commit + ["inside étoile"], at: root)
        try "outside".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(commit + ["outside change"], at: root)
        let index = root.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        let service = GitReviewService()
        let all = try await service.history(workspace: root.path)
        XCTAssertEqual(all.map(\.subject), ["outside change", "inside étoile"])
        let scoped = try await service.history(workspace: sub.path)
        XCTAssertEqual(scoped.map(\.subject), ["inside étoile"])
        let detail = try await service.commitSummary(workspace: sub.path, hash: scoped[0].hash)
        XCTAssertTrue(detail.contains("inside.txt"))
        XCTAssertFalse(detail.contains("outside.txt"))
        let patch = try await service.commitDiff(workspace: sub.path, hash: scoped[0].hash)
        XCTAssertTrue(patch.contains("+initial"))
        XCTAssertFalse(patch.contains("outside.txt"))
        for hash in ["--all", all[0].hash] {
            do {
                _ = try await service.commitSummary(workspace: sub.path, hash: hash)
                XCTFail("Must reject options and commits outside the selected workspace history")
            } catch GitReviewError.changedSelection { }
        }
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testCommitPatchComparesFirstParentAndIgnoresUncommittedChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let file = root.appendingPathComponent("file.txt")
        let commit = ["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m"]
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(commit + ["base"], at: root)
        try "after\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(commit + ["change"], at: root)
        try "unsaved-local-content\n".write(to: file, atomically: true, encoding: .utf8)
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let service = GitReviewService()
        let history = try await service.history(workspace: root.path)
        let patch = try await service.commitDiff(workspace: root.path, hash: history[0].hash)
        XCTAssertTrue(patch.contains("-before"))
        XCTAssertTrue(patch.contains("+after"))
        XCTAssertFalse(patch.contains("unsaved-local-content"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), beforeIndex)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unsaved-local-content\n")
        do {
            _ = try await service.commitDiff(workspace: root.path, hash: "HEAD")
            XCTFail("Only validated immutable commit IDs are accepted")
        } catch GitReviewError.changedSelection { }
    }

    func testMergePatchUsesFirstParent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let identity = ["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]
        try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(identity + ["commit", "-m", "base"], at: root)
        try await git(["checkout", "-b", "feature"], at: root)
        try "feature-only\n".write(to: root.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(identity + ["commit", "-m", "feature"], at: root)
        try await git(["checkout", "main"], at: root)
        try await git(identity + ["merge", "--no-ff", "feature", "-m", "merge"], at: root)
        let service = GitReviewService()
        let history = try await service.history(workspace: root.path)
        XCTAssertEqual(history.first?.subject, "merge")
        let patch = try await service.commitDiff(workspace: root.path, hash: history[0].hash)
        XCTAssertTrue(patch.contains("+feature-only"))
        XCTAssertFalse(patch.contains("+base"))
    }

    func testPorcelainPreservesUnusualNamesRenamesAndConflicts() throws {
        let state = try GitReviewSnapshot.parse("## main\0R  new\nname.swift\0old\tname.swift\0 M space name.txt\0?? étoile.txt\0UU conflict.txt\0")
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(state.changes.count, 4)
        XCTAssertEqual(state.changes[0].path, "new\nname.swift")
        XCTAssertEqual(state.changes[0].originalPath, "old\tname.swift")
        XCTAssertTrue(state.changes[0].isStaged)
        XCTAssertTrue(state.changes[1].isUnstaged)
        XCTAssertTrue(state.changes[2].isUntracked)
        XCTAssertTrue(state.changes[3].isConflicted)
        XCTAssertFalse(state.changes[3].isStaged)
        let typeChange = try GitReviewSnapshot.parse("## main\0 T changed-link\0")
        XCTAssertTrue(typeChange.changes[0].isUnstaged)
        XCTAssertThrowsError(try GitReviewSnapshot.parse("## main\0R  missing-source\0"))
        XCTAssertThrowsError(try GitReviewSnapshot.parse("## main\0 M truncated"))
    }

    func testRealRepositorySeparatesIndexAndWorkingTreeWithoutChangingIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let file = root.appendingPathComponent("unusual\tname.txt")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", file.lastPathComponent], at: root)
        try await git(["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"], at: root)
        try "staged text\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", file.lastPathComponent], at: root)
        try "working text\n".write(to: file, atomically: true, encoding: .utf8)
        let indexURL = root.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: indexURL)
        let service = GitReviewService()
        let state = try await service.snapshot(workspace: root.path)
        XCTAssertEqual(state.changes.map(\.status), ["MM"])
        let staged = try await service.diff(workspace: root.path, path: file.lastPathComponent, staged: true)
        let working = try await service.diff(workspace: root.path, path: file.lastPathComponent, staged: false)
        XCTAssertTrue(staged.contains("+staged text"))
        XCTAssertFalse(staged.contains("working text"))
        XCTAssertTrue(working.contains("+working text"))
        XCTAssertEqual(try Data(contentsOf: indexURL), before)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "working text\n")
    }

    func testSubdirectoryScopeAndLiteralPathspec() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init"], at: root)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["outside.txt", "sub/[a].txt", "sub/a.txt"] {
            try "before\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git(["add", "."], at: root)
        for name in ["outside.txt", "sub/[a].txt", "sub/a.txt"] {
            try "after \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let service = GitReviewService()
        let state = try await service.snapshot(workspace: sub.path)
        XCTAssertEqual(Set(state.changes.map(\.path)), ["sub/[a].txt", "sub/a.txt"])
        let diff = try await service.diff(workspace: sub.path, path: "sub/[a].txt", staged: false)
        XCTAssertTrue(diff.contains("+after sub/[a].txt"))
        XCTAssertFalse(diff.contains("+after sub/a.txt"))
        do {
            _ = try await service.diff(workspace: sub.path, path: "outside.txt", staged: false)
            XCTFail("Outside-workspace selection must be rejected")
        } catch GitReviewError.changedSelection { }
    }

    func testRejectsTruncatedStatusAndDisablesGitHelpers() async throws {
        let runner = ReviewRunner(truncated: true)
        do {
            _ = try await GitReviewService(runner: runner).snapshot(workspace: "/tmp")
            XCTFail("A truncated status must not appear clean")
        } catch GitReviewError.outputTooLarge { }
        let commands = await runner.commands
        XCTAssertTrue(commands[0].arguments.contains("--no-optional-locks"))
        XCTAssertTrue(commands[0].arguments.contains("core.fsmonitor=false"))
        let diffRunner = ReviewRunner(truncated: false)
        _ = try await GitReviewService(runner: diffRunner).diff(workspace: "/tmp", path: "file", staged: false)
        let diffCommand = await diffRunner.commands.last!
        XCTAssertTrue(diffCommand.arguments.contains("--no-ext-diff"))
        XCTAssertTrue(diffCommand.arguments.contains("--no-textconv"))
        XCTAssertTrue(diffCommand.arguments.contains(":(top,literal)file"))
    }

    func testRenamedAndUntrackedFilesAndNonRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GitReviewService()
        do {
            _ = try await service.snapshot(workspace: root.path)
            XCTFail("A non-repository must not appear clean")
        } catch GitReviewError.unavailable { }
        try await git(["init"], at: root)
        let initial = try await service.snapshot(workspace: root.path)
        XCTAssertTrue(initial.changes.isEmpty)
        try "rename contents\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], at: root)
        try await git(["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"], at: root)
        try await git(["mv", "old.txt", "new.txt"], at: root)
        try "local only".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let snapshot = try await service.snapshot(workspace: root.path)
        XCTAssertEqual(snapshot.changes.first(where: { $0.path == "new.txt" })?.originalPath, "old.txt")
        let diff = try await service.diff(workspace: root.path, path: "new.txt", staged: true)
        XCTAssertTrue(diff.contains("+rename contents"))
        XCTAssertTrue(diff.contains("-rename contents"))
        let untracked = try await service.diff(workspace: root.path, path: "untracked.txt", staged: false)
        XCTAssertTrue(untracked.contains("Untracked file"))
        XCTAssertTrue(untracked.contains("1  local only"))
        XCTAssertTrue(untracked.contains("not staged"))
    }

    func testUntrackedPreviewIsScopedBoundedAndNeverFollowsNewSymlinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init"], at: root)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "outside secret".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try "α\nβ".write(to: sub.appendingPathComponent("[new].txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: sub.appendingPathComponent("link").path, withDestinationPath: "../outside.txt")
        let service = GitReviewService()
        let preview = try await service.diff(workspace: sub.path, path: "sub/[new].txt", staged: false)
        XCTAssertTrue(preview.contains("1  α\n2  β"))
        let link = try await service.diff(workspace: sub.path, path: "sub/link", staged: false)
        XCTAssertFalse(link.contains("outside secret"))
        for (path, staged) in [("outside.txt", false), ("sub/[new].txt", true)] {
            do { _ = try await service.diff(workspace: sub.path, path: path, staged: staged); XCTFail("Invalid selection") }
            catch GitReviewError.changedSelection { }
        }
        try String(repeating: "x", count: 256 * 1_024 + 1).write(to: sub.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        do { _ = try await service.diff(workspace: sub.path, path: "sub/large.txt", staged: false); XCTFail("Oversize preview") }
        catch GitReviewError.outputTooLarge { }
        try Data([0, 1, 2]).write(to: sub.appendingPathComponent("binary"))
        do { _ = try await service.diff(workspace: sub.path, path: "sub/binary", staged: false); XCTFail("Binary preview") }
        catch WorkspaceError.unsupportedEncoding { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index").path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-git-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func git(_ arguments: [String], at root: URL) async throws {
        let result = try await MacProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: root, timeout: .seconds(10)
        ))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }
}

private actor ReviewRunner: ProcessRunning {
    let truncated: Bool
    var commands: [ProcessCommand] = []
    init(truncated: Bool) { self.truncated = truncated }
    func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        commands.append(command)
        return ProcessOutput(stdout: command.arguments.contains("status") ? "## main\0 M file\0" : "diff", stderr: "", exitCode: 0, wasTruncated: truncated)
    }
    func terminateAll() async { }
}
