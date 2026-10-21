import AIMAgentKit
import AIMMacPlatform
import XCTest

final class GitIndexTests: XCTestCase {
    func testTrackedStageAndUnstagePreserveWorkingFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let file = root.appendingPathComponent("[review].txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", file.lastPathComponent], at: root)
        try await git(["-c", "user.name=AIM Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base"], at: root)
        try "after\n".write(to: file, atomically: true, encoding: .utf8)

        let review = GitReviewService(), index = GitIndexService()
        let beforeSnapshot = try await review.snapshot(workspace: root.path)
        let before = try XCTUnwrap(beforeSnapshot.changes.first)
        let workingDiff = try await review.diff(workspace: root.path, path: before.path, staged: false)
        try await index.stage(workspace: root.path, change: before, reviewedDiff: workingDiff)
        let stagedSnapshot = try await review.snapshot(workspace: root.path)
        let staged = try XCTUnwrap(stagedSnapshot.changes.first)
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(staged.isUnstaged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")

        let stagedDiff = try await review.diff(workspace: root.path, path: staged.path, staged: true)
        try await index.unstage(workspace: root.path, change: staged, reviewedDiff: stagedDiff)
        let unstagedSnapshot = try await review.snapshot(workspace: root.path)
        let unstaged = try XCTUnwrap(unstagedSnapshot.changes.first)
        XCTAssertFalse(unstaged.isStaged)
        XCTAssertTrue(unstaged.isUnstaged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
    }

    func testChangedPreviewAndOutsideWorkspaceSelectionCannotStage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inside = sub.appendingPathComponent("inside.txt")
        let outside = root.appendingPathComponent("outside.txt")
        try "first\n".write(to: inside, atomically: true, encoding: .utf8)
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)

        let review = GitReviewService(), index = GitIndexService()
        let rootChanges = try await review.snapshot(workspace: root.path).changes
        let outsideChange = try XCTUnwrap(rootChanges.first { $0.path == "outside.txt" })
        let outsideDiff = try await review.diff(workspace: root.path, path: outsideChange.path, staged: false)
        do {
            try await index.stage(workspace: sub.path, change: outsideChange, reviewedDiff: outsideDiff)
            XCTFail("An outside file must not be staged")
        } catch GitIndexError.changedSelection { }

        let insideSnapshot = try await review.snapshot(workspace: sub.path)
        let insideChange = try XCTUnwrap(insideSnapshot.changes.first)
        let oldPreview = try await review.diff(workspace: sub.path, path: insideChange.path, staged: false)
        try "changed after review\n".write(to: inside, atomically: true, encoding: .utf8)
        do {
            try await index.stage(workspace: sub.path, change: insideChange, reviewedDiff: oldPreview)
            XCTFail("A stale preview must not be staged")
        } catch GitIndexError.changedSelection { }
        let finalSnapshot = try await review.snapshot(workspace: sub.path)
        XCTAssertTrue(finalSnapshot.changes.allSatisfy { !$0.isStaged })
    }

    func testUnbornBranchCanUnstageNewFileWithoutDeletingIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], at: root)
        let file = root.appendingPathComponent("new.txt")
        try "new contents\n".write(to: file, atomically: true, encoding: .utf8)
        let review = GitReviewService(), index = GitIndexService()
        let untrackedSnapshot = try await review.snapshot(workspace: root.path)
        let untracked = try XCTUnwrap(untrackedSnapshot.changes.first)
        let preview = try await review.diff(workspace: root.path, path: untracked.path, staged: false)
        try await index.stage(workspace: root.path, change: untracked, reviewedDiff: preview)
        let stagedSnapshot = try await review.snapshot(workspace: root.path)
        let staged = try XCTUnwrap(stagedSnapshot.changes.first)
        XCTAssertEqual(staged.indexStatus, "A")
        let stagedDiff = try await review.diff(workspace: root.path, path: staged.path, staged: true)
        try await index.unstage(workspace: root.path, change: staged, reviewedDiff: stagedDiff)
        let finalSnapshot = try await review.snapshot(workspace: root.path)
        let final = try XCTUnwrap(finalSnapshot.changes.first)
        XCTAssertTrue(final.isUntracked)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new contents\n")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-git-index-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func git(_ arguments: [String], at root: URL) async throws {
        let output = try await MacProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: root,
            timeout: .seconds(10)
        ))
        XCTAssertEqual(output.exitCode, 0, output.stderr)
    }
}
