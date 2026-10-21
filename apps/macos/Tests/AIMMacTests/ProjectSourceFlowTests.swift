@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ProjectSourceFlowTests: XCTestCase {
    func testLinkRescanAndRemoveFolderWithoutTouchingOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-project-flow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try Data("first project snapshot".utf8).write(to: file)
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let saved = await model.saveProject(id: nil, name: "App", instructions: "")
        XCTAssertTrue(saved)
        let project = try XCTUnwrap(model.projects.first)
        let first = try await model.indexProjectFolder(root, projectID: project.id)
        XCTAssertEqual(first.indexedFiles, 1)
        var sources = try await model.sources(for: project.id)
        XCTAssertEqual(sources.count, 1)
        let id = try XCTUnwrap(sources.first?.id)
        try Data("updated project snapshot".utf8).write(to: file)
        let second = try await model.indexProjectFolder(root, projectID: project.id)
        XCTAssertEqual(second.indexedFiles, 1)
        sources = try await model.sources(for: project.id)
        XCTAssertEqual(sources.map(\.id), [id])
        try await model.removeProjectSource(sources[0])
        let removed = try await model.sources(for: project.id)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "updated project snapshot")
    }

    func testFailedScanDoesNotLeaveLinkedSource() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let created = await model.saveProject(id: nil, name: "App", instructions: "")
        XCTAssertTrue(created)
        let saved = try XCTUnwrap(model.projects.first)
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        do { _ = try await model.indexProjectFolder(absent, projectID: saved.id); XCTFail("Expected unreadable folder") }
        catch { XCTAssertTrue(error is ProjectSourceScannerError) }
        let sources = try await model.sources(for: saved.id)
        XCTAssertTrue(sources.isEmpty)
    }
}
