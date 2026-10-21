import AIMApplication
import Foundation
import XCTest

final class ProjectSourceRefreshTests: XCTestCase {
    func testNestedEditAndDeletionAreDetectedWithoutRootTimestampChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-nested-refresh-\(UUID())")
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = nested.appendingPathComponent("Main.swift")
        try Data("original".utf8).write(to: file)
        let scannedAt = Date.now
        let old = scannedAt.addingTimeInterval(-10)
        for path in [root.path, nested.path, file.path] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        XCTAssertFalse(try ProjectSourceScanner.refreshRequired(root, scannedAt: scannedAt))

        try Data("changed".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: scannedAt.addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertTrue(try ProjectSourceScanner.refreshRequired(root, scannedAt: scannedAt))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.modificationDate: scannedAt.addingTimeInterval(10)], ofItemAtPath: nested.path)
        XCTAssertTrue(try ProjectSourceScanner.refreshRequired(root, scannedAt: scannedAt))
    }

    func testRefreshesEditedAndRemovedFilesButSkipsUnchangedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("README.md")
        try Data("oldword".utf8).write(to: file)
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Refresh")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: root.path, displayName: "refresh")
        try await projects.save(source: source)
        let index = SQLiteProjectSourceIndex(database: db)
        let refresh = ProjectSourceRefreshService(projects: projects, index: index)

        try await refresh.refresh(projectID: project.id)
        let initial = try await index.passages(projectID: project.id, query: "oldword")
        XCTAssertEqual(initial.first?.relativePath, "README.md")
        try await index.replace(source: source, chunks: [ProjectSourceChunk(relativePath: "README.md", startLine: 1, content: "sentinelword")])
        try await refresh.refresh(projectID: project.id)
        let unchanged = try await index.passages(projectID: project.id, query: "sentinelword")
        XCTAssertEqual(unchanged.count, 1)

        try Data("newword".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: file.path)
        try await refresh.refresh(projectID: project.id)
        let updated = try await index.passages(projectID: project.id, query: "newword")
        XCTAssertEqual(updated.first?.content.trimmingCharacters(in: .whitespacesAndNewlines), "newword")
        let stale = try await index.passages(projectID: project.id, query: "sentinelword")
        XCTAssertTrue(stale.isEmpty)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(10)], ofItemAtPath: root.path)
        try await refresh.refresh(projectID: project.id)
        let remaining = try await index.chunkCount(sourceID: source.id)
        XCTAssertEqual(remaining, 0)
    }

    func testUnavailableLinkedFolderFailsRatherThanReusingStalePassages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-missing-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("private old snapshot".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Missing")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: root.path, displayName: "missing")
        try await projects.save(source: source)
        let index = SQLiteProjectSourceIndex(database: db)
        let refresh = ProjectSourceRefreshService(projects: projects, index: index)
        try await refresh.refresh(projectID: project.id)
        try FileManager.default.removeItem(at: root)
        do {
            try await refresh.refresh(projectID: project.id)
            XCTFail("Missing linked source should stop the provider turn")
        } catch let error as ProjectSourceRefreshError {
            XCTAssertTrue(error.localizedDescription.contains("outdated snapshot was not sent"))
        }
    }

    func testStoredScanTimeIsTheStartSoConcurrentEditsRemainDetectable() async throws {
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Scan race")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: "/tmp/scan-race", displayName: "scan-race")
        try await projects.save(source: source)
        let startedAt = Date.now.addingTimeInterval(-30)
        try await SQLiteProjectSourceIndex(database: db).replace(source: source,
            chunks: [ProjectSourceChunk(relativePath: "main.swift", startLine: 1, content: "snapshot")],
            scanStartedAt: startedAt)
        let saved = try await projects.sources(projectID: project.id)
        let timestamp = try XCTUnwrap(saved.first?.lastScannedAt)
        XCTAssertEqual(timestamp.timeIntervalSince1970, startedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRetargetedLinkedFolderIsNotIndexed() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("aim-retarget-\(UUID())")
        let linked = parent.appendingPathComponent("linked")
        let replacement = parent.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("safe original".utf8).write(to: linked.appendingPathComponent("original.txt"))
        try Data("unrelated replacement".utf8).write(to: replacement.appendingPathComponent("unrelated.txt"))
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Retarget")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: linked.path, displayName: "linked")
        try await projects.save(source: source)
        let index = SQLiteProjectSourceIndex(database: db)
        let refresh = ProjectSourceRefreshService(projects: projects, index: index)
        try await refresh.refresh(projectID: project.id)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: replacement)
        do {
            try await refresh.refresh(projectID: project.id)
            XCTFail("A retargeted folder must be relinked explicitly")
        } catch is ProjectSourceRefreshError {}
        let unrelated = try await index.passages(projectID: project.id, query: "unrelated")
        XCTAssertTrue(unrelated.isEmpty)
    }
}
