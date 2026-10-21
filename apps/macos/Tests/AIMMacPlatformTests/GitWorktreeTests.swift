import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class GitWorktreeTests: XCTestCase {
    func testPorcelainParserPreservesPathsAndStates() throws {
        let hash = String(repeating: "a", count: 40)
        let output = "worktree /tmp/space name\0HEAD \(hash)\0branch refs/heads/main\0\0"
            + "worktree /tmp/detached\0HEAD \(hash)\0detached\0locked checked out for review\0\0"
            + "worktree /tmp/bare\0HEAD \(hash)\0bare\0\0"
        let entries = try GitWorktreeService.parse(output)
        XCTAssertEqual(entries.map(\.path), ["/tmp/space name", "/tmp/detached", "/tmp/bare"])
        XCTAssertEqual(entries[0].branch, "refs/heads/main")
        XCTAssertTrue(entries[0].isAvailable)
        XCTAssertTrue(entries[1].isDetached)
        XCTAssertEqual(entries[1].lockedReason, "checked out for review")
        XCTAssertFalse(entries[1].isAvailable)
        XCTAssertTrue(entries[2].isBare)
        XCTAssertFalse(entries[2].isAvailable)
        XCTAssertThrowsError(try GitWorktreeService.parse("worktree /tmp/a\0HEAD bad\0\0"))
        XCTAssertThrowsError(try GitWorktreeService.parse("worktree relative\0HEAD \(hash)\0\0"))
        XCTAssertThrowsError(try GitWorktreeService.parse("worktree /tmp/a\0HEAD \(hash)\0"))
    }

    func testListsAndValidatesOnlyCurrentRepositoryWorktrees() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("aim-worktrees-\(UUID())")
        let root = parent.appendingPathComponent("main")
        let feature = parent.appendingPathComponent("feature branch")
        let unrelated = parent.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await git(["init", "-b", "main", root.path], at: parent)
        try "initial\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "file.txt"], at: root)
        try await git(["-c", "user.name=AIM Test", "-c", "user.email=aim@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Initial"], at: root)
        try await git(["worktree", "add", "-b", "feature", feature.path], at: root)
        try await git(["init", unrelated.path], at: parent)

        let service = GitWorktreeService()
        let entries = try await service.list(workspace: root.path)
        XCTAssertEqual(Set(entries.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }),
                       Set([root, feature].map { $0.resolvingSymlinksInPath().path }))
        let validated = try await service.validatedWorkspace(currentWorkspace: root.path, selectedPath: feature.path)
        XCTAssertEqual(validated, feature.resolvingSymlinksInPath().path)
        do {
            _ = try await service.validatedWorkspace(currentWorkspace: root.path, selectedPath: unrelated.path)
            XCTFail("Another repository cannot be selected")
        } catch GitWorktreeError.changedSelection { }
        try await git(["worktree", "remove", feature.path], at: root)
        do {
            _ = try await service.validatedWorkspace(currentWorkspace: root.path, selectedPath: feature.path)
            XCTFail("A removed worktree cannot be selected")
        } catch GitWorktreeError.changedSelection { }
    }

    func testReviewedCreationNeverOverwritesBranchOrSiblingFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("aim-create-worktree-\(UUID())")
        let root = parent.appendingPathComponent("main")
        let target = parent.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await git(["init", "-b", "main", root.path], at: parent)
        try "initial\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "--", "file.txt"], at: root)
        try await git(["-c", "user.name=AIM Test", "-c", "user.email=aim@example.invalid",
                       "-c", "commit.gpgsign=false", "commit", "-m", "Initial"], at: root)

        let service = GitWorktreeService()
        let preview = try await service.previewCreation(workspace: root.path, folderName: "feature",
                                                        branch: "codex/feature")
        XCTAssertEqual(preview.targetPath, target.path)
        let created = try await service.create(workspace: root.path, expected: preview)
        XCTAssertTrue(created.path.hasSuffix("/feature"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(created.branch, "refs/heads/codex/feature")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8), "initial\n")
        do {
            _ = try await service.create(workspace: root.path, expected: preview)
            XCTFail("Existing worktree was reused")
        } catch GitWorktreeError.targetExists {}
        do {
            _ = try await service.previewCreation(workspace: root.path, folderName: "another",
                                                  branch: "codex/feature")
            XCTFail("Existing branch was accepted")
        } catch GitWorktreeError.branchExists {}
        do {
            _ = try await service.previewCreation(workspace: root.path, folderName: "../escape",
                                                  branch: "codex/another")
            XCTFail("Invalid path was accepted")
        } catch GitWorktreeError.invalidFolderName {}
    }

    private func git(_ arguments: [String], at directory: URL) async throws {
        let output = try await MacProcessRunner(supervisor: ProcessSupervisor()).run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-c", "core.hooksPath=/dev/null"] + arguments,
            workingDirectory: directory, timeout: .seconds(15)))
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        if output.exitCode != 0 { throw GitWorktreeError.unavailable }
    }
}
