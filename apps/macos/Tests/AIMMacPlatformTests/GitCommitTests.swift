import AIMAgentKit
import AIMMacPlatform
import XCTest

final class GitCommitTests: XCTestCase {
    func testInitialAndSubsequentCommitUseReviewedIndexWithoutTouchingWorkingEdits() async throws {
        let root = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "notes.txt"], at: root)
        let service = GitCommitService()
        let initial = try await service.preview(workspace: root.path)
        XCTAssertNil(initial.head)
        XCTAssertEqual(initial.branch, "main")
        XCTAssertEqual(initial.entries.map(\.path), ["notes.txt"])
        let first = try await service.commit(workspace: root.path, expected: initial, message: "Initial notes")
        let recordedHead = try await git(["rev-parse", "HEAD"], at: root)
        let cleanStatus = try await git(["status", "--porcelain"], at: root)
        XCTAssertEqual(recordedHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines), first)
        XCTAssertTrue(cleanStatus.stdout.isEmpty)

        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "notes.txt"], at: root)
        let second = try await service.preview(workspace: root.path)
        try "working edit\n".write(to: file, atomically: true, encoding: .utf8)
        let hash = try await service.commit(workspace: root.path, expected: second, message: "Save staged notes")
        XCTAssertNotEqual(hash, first)
        let committedFile = try await git(["show", "HEAD:notes.txt"], at: root)
        XCTAssertEqual(committedFile.stdout, "staged\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "working edit\n")
        let remainingIndex = try await git(["diff", "--cached", "--name-only"], at: root)
        XCTAssertEqual(remainingIndex.stdout, "")
    }

    func testChangedIndexAndBranchAreRefusedBeforeWritingCommit() async throws {
        let root = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "file.txt"], at: root)
        let service = GitCommitService()
        let old = try await service.preview(workspace: root.path)
        try "two".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "file.txt"], at: root)
        do { _ = try await service.commit(workspace: root.path, expected: old, message: "Stale")
            XCTFail("A changed index must be rejected")
        } catch GitCommitError.changedIndex { }
        let current = try await service.preview(workspace: root.path)
        _ = try await git(["commit", "-m", "External commit"], at: root)
        do { _ = try await service.commit(workspace: root.path, expected: current, message: "Stale branch")
            XCTFail("A changed branch must be rejected")
        } catch GitCommitError.changedIndex { }
    }

    func testRepositoryRootAndMessageRequirements() async throws {
        let root = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "draft".write(to: sub.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "sub/draft.txt"], at: root)
        let service = GitCommitService()
        do { _ = try await service.preview(workspace: sub.path); XCTFail("Subfolder could hide staged files") }
        catch GitCommitError.chooseRepositoryRoot { }
        let preview = try await service.preview(workspace: root.path)
        do { _ = try await service.commit(workspace: root.path, expected: preview, message: "  "); XCTFail("Empty message") }
        catch GitCommitError.invalidMessage { }
        _ = try await git(["reset", "--", "sub/draft.txt"], at: root)
        do { _ = try await service.preview(workspace: root.path); XCTFail("Nothing staged") }
        catch GitCommitError.nothingStaged { }
    }

    func testChangedHeadWithUnchangedStagedIndexIsRefused() async throws {
        let root = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "file.txt"], at: root)
        let service = GitCommitService()
        let first = try await service.preview(workspace: root.path)
        _ = try await service.commit(workspace: root.path, expected: first, message: "Base")
        try "next".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "file.txt"], at: root)
        let stale = try await service.preview(workspace: root.path)
        let parent = try await git(["rev-parse", "HEAD"], at: root)
        let tree = try await git(["rev-parse", "HEAD^{tree}"], at: root)
        let external = try await git(["commit-tree", tree.stdout.trimmingCharacters(in: .newlines), "-p", parent.stdout.trimmingCharacters(in: .newlines), "-m", "Parallel"], at: root)
        _ = try await git(["update-ref", "refs/heads/main", external.stdout.trimmingCharacters(in: .newlines), parent.stdout.trimmingCharacters(in: .newlines)], at: root)
        do { _ = try await service.commit(workspace: root.path, expected: stale, message: "Stale parent")
            XCTFail("A changed branch must be rejected even if the index is identical")
        } catch GitCommitError.changedIndex { }
    }

    func testRepositoryReferenceHookDoesNotRun() async throws {
        let root = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("hook-ran")
        let hook = root.appendingPathComponent(".git/hooks/reference-transaction")
        try "#!/bin/sh\n: > '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "safe".write(to: root.appendingPathComponent("safe.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "--", "safe.txt"], at: root)
        let service = GitCommitService()
        let preview = try await service.preview(workspace: root.path)
        _ = try await service.commit(workspace: root.path, expected: preview, message: "No hooks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private func temporaryRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-git-commit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-b", "main", root.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitCommitError.unavailable }
        for pair in [["user.name", "AIM Test"], ["user.email", "aim@example.invalid"]] {
            let setting = Process()
            setting.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            setting.arguments = ["-C", root.path, "config"] + pair
            try setting.run(); setting.waitUntilExit()
            guard setting.terminationStatus == 0 else { throw GitCommitError.unavailable }
        }
        return root
    }

    private func git(_ arguments: [String], at root: URL) async throws -> ProcessOutput {
        let output = try await MacProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: root, timeout: .seconds(10)))
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        return output
    }
}
