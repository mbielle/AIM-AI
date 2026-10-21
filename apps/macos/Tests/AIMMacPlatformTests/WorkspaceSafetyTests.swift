import AIMAgentKit
import AIMMacPlatform
import XCTest

final class WorkspaceSafetyTests: XCTestCase {
    func testExternalSymlinkCannotBeReadOrSearched() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base.appendingPathComponent("outside.txt")
        try "outside-private-marker".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut.txt"), withDestinationURL: secret)
        let service = WorkspaceFileToolService()
        let read = await service.execute(ToolRequest(name: "read_file", arguments: ["path": "shortcut.txt"], risk: .readOnly, workspacePath: root.path))
        XCTAssertTrue(read.isError)
        let search = await service.execute(ToolRequest(name: "search_files", arguments: ["query": "outside-private-marker"], risk: .readOnly, workspacePath: root.path))
        XCTAssertFalse(search.content.contains("outside-private-marker"))
        let entries = try await service.entries(workspace: root.path)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "outside-private-marker")
    }

    func testPreviewRejectsBinaryLargeFilesAndDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 255, 12]).write(to: root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: 1_000_001).write(to: root.appendingPathComponent("large"))
        let service = WorkspaceFileToolService()
        for path in ["binary", "large", "."] {
            let result = await service.execute(ToolRequest(name: "read_file", arguments: ["path": path], risk: .readOnly, workspacePath: root.path))
            XCTAssertTrue(result.isError, path)
        }
        try "Hello 🌍".write(to: root.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
        let valid = await service.execute(ToolRequest(name: "read_file", arguments: ["path": "small.txt"], risk: .readOnly, workspacePath: root.path))
        XCTAssertEqual(valid.content, "Hello 🌍")
        XCTAssertFalse(valid.isError)
    }
}
