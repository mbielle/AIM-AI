import AIMApplication
@testable import AIMMacPlatform
import XCTest

final class SubagentWorkspaceServiceTests: XCTestCase {
    private var scratch: URL!
    private var repository: URL!
    private var service: SubagentWorkspaceService!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aim-subagent-ws-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        repository = scratch.appendingPathComponent("repo with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("app"), withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Fixture")
        try git("config", "user.email", "fixture@example.invalid")
        try write("tracked.txt", "one\ntwo\nthree\n")
        try write("app/main.txt", "main\n")
        try write(".gitignore", "build/\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "initial")
        service = SubagentWorkspaceService(root: scratch.appendingPathComponent("Worktrees", isDirectory: true))
    }

    override func tearDownWithError() throws {
        _ = try? git("worktree", "prune")
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? repository
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus)) }
        return output
    }

    private func write(_ path: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? repository).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in base: URL? = nil) -> String? {
        try? String(contentsOf: (base ?? repository).appendingPathComponent(path), encoding: .utf8)
    }

    func testChildStartsFromParentsCurrentFilesWithoutTouchingItsIndex() async throws {
        try write("tracked.txt", "one\nTWO (parent edit)\nthree\n")
        try write("notes/untracked.md", "draft\n")
        try write("build/output.bin", "ignored\n")
        try git("add", "tracked.txt")
        let stagedBefore = try git("diff", "--cached", "--name-only")
        let branchesBefore = try git("branch", "--list")

        let record = try await service.prepare(workspace: repository.appendingPathComponent("app").path,
                                               jobID: UUID(), conversationID: UUID(), title: "t")
        XCTAssertEqual(record.relativeWorkspace, "app")
        XCTAssertTrue(record.childWorkspace.hasSuffix("/app"))
        let child = URL(fileURLWithPath: record.worktreePath)
        XCTAssertEqual(read("tracked.txt", in: child), "one\nTWO (parent edit)\nthree\n")
        XCTAssertEqual(read("notes/untracked.md", in: child), "draft\n")
        XCTAssertNil(read("build/output.bin", in: child), "ignored files stay out of the snapshot")
        XCTAssertEqual(try git("diff", "--cached", "--name-only"), stagedBefore, "the parent's index is untouched")
        XCTAssertEqual(read("tracked.txt"), "one\nTWO (parent edit)\nthree\n")
        XCTAssertTrue(try git("branch", "--list").contains(record.branch))
        XCTAssertTrue(branchesBefore.contains("main"))
        try await service.remove(record)
    }

    func testReviewedPatchMergesIntoWorkingTreeAndWorktreeIsRemoved() async throws {
        var record = try await service.prepare(workspace: repository.path, jobID: UUID(), conversationID: UUID(), title: "t")
        let child = URL(fileURLWithPath: record.worktreePath)
        try write("tracked.txt", "one\ntwo\nthree\nfour (child)\n", in: child)
        try write("new/feature.txt", "feature\n", in: child)
        try FileManager.default.removeItem(at: child.appendingPathComponent("app/main.txt"))

        do { _ = try await service.merge(record); XCTFail("merge needs a review") }
        catch let error as SubagentWorkspaceError { XCTAssertEqual(error, .notReviewed) }

        let changes = try await service.changes(record)
        XCTAssertEqual(Set(changes.files.map { "\($0.status) \($0.path)" }),
                       ["M tracked.txt", "A new/feature.txt", "D app/main.txt"])
        XCTAssertTrue(changes.deletesFiles)
        XCTAssertEqual(changes.files.first { $0.path == "tracked.txt" }?.insertions, 1)
        record.reviewedPatchSHA256 = changes.patchSHA256

        // A later child edit invalidates the review.
        try write("late.txt", "late\n", in: child)
        do { _ = try await service.merge(record); XCTFail("changed after review") }
        catch let error as SubagentWorkspaceError { XCTAssertEqual(error, .changedSinceReview) }
        try FileManager.default.removeItem(at: child.appendingPathComponent("late.txt"))

        // Unrelated parent edits elsewhere do not block the merge.
        try write("parent-only.txt", "mine\n")
        let merged = try await service.merge(record)
        XCTAssertEqual(merged.files.count, 3)
        XCTAssertEqual(read("tracked.txt"), "one\ntwo\nthree\nfour (child)\n")
        XCTAssertEqual(read("new/feature.txt"), "feature\n")
        XCTAssertNil(read("app/main.txt"))
        XCTAssertEqual(read("parent-only.txt"), "mine\n")
        XCTAssertEqual(try git("diff", "--cached", "--name-only"), "", "merge changes the working tree, not the index")

        try await service.remove(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertFalse(try git("branch", "--list").contains(record.branch))
    }

    func testConflictingParentEditLeavesEverythingUnchanged() async throws {
        var record = try await service.prepare(workspace: repository.path, jobID: UUID(), conversationID: UUID(), title: "t")
        try write("tracked.txt", "one\nchild\nthree\n", in: URL(fileURLWithPath: record.worktreePath))
        record.reviewedPatchSHA256 = try await service.changes(record).patchSHA256
        try write("tracked.txt", "one\nparent\nthree\n")
        do {
            _ = try await service.merge(record)
            XCTFail("conflict expected")
        } catch let error as SubagentWorkspaceError {
            guard case .conflict = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(read("tracked.txt"), "one\nparent\nthree\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.worktreePath), "the child's work is kept")
        try await service.remove(record)
    }

    func testRefusesNonRepositoriesAndForeignWorktrees() async throws {
        let plain = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        do { _ = try await service.prepare(workspace: plain.path, jobID: UUID(), conversationID: UUID(), title: "t"); XCTFail() }
        catch let error as SubagentWorkspaceError { XCTAssertEqual(error, .notRepository) }

        let foreign = SubagentWorkspaceRecord(jobID: UUID(), conversationID: UUID(), title: "t",
            repositoryRoot: repository.path, relativeWorkspace: "", worktreePath: repository.path,
            branch: "aim/subagent-deadbeef", baseCommit: String(repeating: "a", count: 40))
        do { try await service.remove(foreign); XCTFail() }
        catch let error as SubagentWorkspaceError { XCTAssertEqual(error, .notOwned) }
        XCTAssertNotNil(read("tracked.txt"))
    }
}
