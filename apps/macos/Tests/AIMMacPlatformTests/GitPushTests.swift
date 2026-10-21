import AIMAgentKit
import AIMMacPlatform
import XCTest

final class GitPushTests: XCTestCase {
    func testPreviewAndPushExactBranchToExplicitLocalRemote() async throws {
        let fixture = try repository()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = GitPushService()
        let remotes = try await service.remotes(workspace: fixture.work.path)
        XCTAssertEqual(remotes.map(\.name), ["origin"])
        XCTAssertEqual(remotes[0].destination, fixture.bare.absoluteString)
        let preview = try await service.preview(workspace: fixture.work.path, remote: "origin")
        XCTAssertEqual(preview.branch, "main")
        XCTAssertEqual(preview.refspec, "refs/heads/main:refs/heads/main")
        try await service.push(workspace: fixture.work.path, expected: preview)
        let remoteHead = try await git(["--git-dir", fixture.bare.path, "rev-parse", "refs/heads/main"], at: fixture.work)
        XCTAssertEqual(remoteHead.stdout.trimmingCharacters(in: .newlines), preview.head)
    }

    func testChangedHeadAndRemoteRejectStaleConfirmation() async throws {
        let fixture = try repository()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = GitPushService()
        let preview = try await service.preview(workspace: fixture.work.path, remote: "origin")
        try "more\n".write(to: fixture.work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "notes.txt"], at: fixture.work)
        _ = try await git(["commit", "-m", "Second"], at: fixture.work)
        do { try await service.push(workspace: fixture.work.path, expected: preview); XCTFail("Stale HEAD pushed") }
        catch GitPushError.changedSincePreview {}

        let fresh = try await service.preview(workspace: fixture.work.path, remote: "origin")
        _ = try await git(["remote", "set-url", "--push", "origin", "file:///private/tmp/another-repo.git"], at: fixture.work)
        do { try await service.push(workspace: fixture.work.path, expected: fresh); XCTFail("Changed remote pushed") }
        catch GitPushError.changedSincePreview {}
    }

    func testCredentialsInRemoteURLAreRejectedWithoutNetworkAccess() async throws {
        let fixture = try repository()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try await git(["remote", "set-url", "--push", "origin", "https://user:secret@example.com/project.git"], at: fixture.work)
        do { _ = try await GitPushService().preview(workspace: fixture.work.path, remote: "origin"); XCTFail("Credential URL accepted") }
        catch GitPushError.unsafeDestination {}
    }

    func testCommonSSHRemoteFormsCanBePreviewedWithoutConnecting() async throws {
        let fixture = try repository()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        for address in ["git@example.com:team/project.git", "ssh://git@example.com/team/project.git"] {
            _ = try await git(["remote", "set-url", "--push", "origin", address], at: fixture.work)
            let preview = try await GitPushService().preview(workspace: fixture.work.path, remote: "origin")
            XCTAssertEqual(preview.remote.destination, address)
        }
    }

    func testRemoteDivergenceIsRejectedWithoutForce() async throws {
        let fixture = try repository()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = GitPushService()
        let initial = try await service.preview(workspace: fixture.work.path, remote: "origin")
        try await service.push(workspace: fixture.work.path, expected: initial)

        let other = fixture.base.appendingPathComponent("other", isDirectory: true)
        _ = try await git(["clone", fixture.bare.absoluteString, other.path], at: fixture.base)
        _ = try await git(["config", "user.name", "Other Test"], at: other)
        _ = try await git(["config", "user.email", "other@example.invalid"], at: other)
        try "remote work\n".write(to: other.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "remote.txt"], at: other)
        _ = try await git(["commit", "-m", "Remote advance"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)

        try "local work\n".write(to: fixture.work.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "local.txt"], at: fixture.work)
        _ = try await git(["commit", "-m", "Local advance"], at: fixture.work)
        let preview = try await service.preview(workspace: fixture.work.path, remote: "origin")
        do { try await service.push(workspace: fixture.work.path, expected: preview); XCTFail("Non-fast-forward pushed") }
        catch GitPushError.rejected {}
        let remoteHead = try await git(["--git-dir", fixture.bare.path, "rev-parse", "refs/heads/main"], at: fixture.work)
        XCTAssertNotEqual(remoteHead.stdout.trimmingCharacters(in: .newlines), preview.head)
    }

    private func repository() throws -> (base: URL, work: URL, bare: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aim-git-push-\(UUID().uuidString)", isDirectory: true)
        let work = base.appendingPathComponent("work", isDirectory: true)
        let bare = base.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func setup(_ args: [String]) throws {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = args
            try command.run(); command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw GitPushError.unavailable }
        }
        try setup(["init", "-b", "main", work.path])
        try setup(["init", "--bare", "-b", "main", bare.path])
        try setup(["-C", work.path, "config", "user.name", "AIM Test"])
        try setup(["-C", work.path, "config", "user.email", "aim@example.invalid"])
        try "first\n".write(to: work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try setup(["-C", work.path, "add", "notes.txt"])
        try setup(["-C", work.path, "commit", "-m", "Initial"])
        try setup(["-C", work.path, "remote", "add", "origin", bare.absoluteString])
        return (base, work, bare)
    }

    private func git(_ arguments: [String], at root: URL) async throws -> ProcessOutput {
        let output = try await MacProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            workingDirectory: root, timeout: .seconds(10)))
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        return output
    }
}
