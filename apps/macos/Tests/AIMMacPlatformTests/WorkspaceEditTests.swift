import AIMMacPlatform
import XCTest

final class WorkspaceEditTests: XCTestCase {
    func testCreationPublishesOnlyAfterApplyAndNeverOverwrites() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceEditService()
        let file = root.appendingPathComponent("new.txt")
        let proposal = try await service.prepareCreation(workspace: root.path, path: "new.txt", content: "New contents")
        XCTAssertTrue(proposal.isCreation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await service.apply(proposal.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "New contents")
        let conflict = try await service.prepareCreation(workspace: root.path, path: "conflict.txt", content: "Agent")
        let conflictingFile = root.appendingPathComponent("conflict.txt")
        try Data("User".utf8).write(to: conflictingFile)
        do { try await service.apply(conflict.id); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: conflictingFile, encoding: .utf8), "User")
        try Data("Newer work".utf8).write(to: file)
        do { try await service.undo(proposal.id); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Newer work")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".aim-create-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCreationRejectsExistingEntriesMissingParentsAndSymlinkParents() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceEditService()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: root.appendingPathComponent("missing").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: root.path)
        for path in ["file.txt", "dangling", "alias/new.txt", "missing/new.txt", "../outside", "."] {
            do { _ = try await service.prepareCreation(workspace: root.path, path: path, content: "x"); XCTFail(path) } catch {}
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Hello world\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        return root
    }

    func testPreviewApplyUndoPreservesBytesAndPermissions() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let service = WorkspaceEditService()
        let proposal = try await service.prepare(workspace: root.path, path: "file.txt", replacing: "world", with: "Mac")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello world\n")
        XCTAssertEqual(proposal.after, "Hello Mac\n")
        try await service.apply(proposal.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), proposal.after)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        try await service.undo(proposal.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), proposal.before)
        do { try await service.apply(proposal.id); XCTFail() } catch {}
    }

    func testStaleApplyAndUndoNeverOverwriteNewContents() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt"), service = WorkspaceEditService()
        let first = try await service.prepare(workspace: root.path, path: "file.txt", replacing: "world", with: "Mac")
        try Data("User changes".utf8).write(to: file)
        do { try await service.apply(first.id); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "User changes")
        let second = try await service.prepare(workspace: root.path, path: "file.txt", replacing: "User", with: "Agent")
        try await service.apply(second.id)
        try Data("More user changes".utf8).write(to: file)
        do { try await service.undo(second.id); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "More user changes")
    }

    func testAmbiguousMatchesTraversalAndLinksAreRejected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceEditService()
        for old in ["", "l", "absent"] {
            do { _ = try await service.prepare(workspace: root.path, path: "file.txt", replacing: old, with: "x"); XCTFail() } catch {}
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("file.txt").path)
        for path in ["../outside", "link", "."] {
            do { _ = try await service.prepare(workspace: root.path, path: path, replacing: "world", with: "x"); XCTFail() } catch {}
        }
    }
}
