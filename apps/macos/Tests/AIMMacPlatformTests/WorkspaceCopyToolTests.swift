import AIMAgentKit
import AIMMacPlatform
import XCTest

final class WorkspaceCopyToolTests: XCTestCase {
    func testCopiesNestedRegularFileWithoutChangingSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: false)
        let contents = Data(repeating: 0x41, count: 180_000)
        try contents.write(to: root.appendingPathComponent("source/original.bin"))
        let result = await copy(root, from: "source/original.bin", to: "target/copy.bin")
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target/copy.bin")), contents)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source/original.bin")), contents)
    }

    func testRefusesExistingDestinationAndInvalidRelativePaths() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "original".write(to: root.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        try "keep".write(to: root.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        for (source, destination) in [
            ("source.txt", "target.txt"), ("source.txt", "source.txt"),
            ("../source.txt", "new.txt"), ("source.txt", "../escape.txt"),
            ("source.txt", "/tmp/escape.txt"), ("source.txt", "missing/new.txt")
        ] {
            let result = await copy(root, from: source, to: destination)
            XCTAssertTrue(result.isError, "\(source) → \(destination)")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target.txt"), encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    func testRefusesSymlinkSourceAndParentWithoutReadingOutside() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aim-copy-symlink-\(UUID())")
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base.appendingPathComponent("secret.txt")
        try "outside marker".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: base)
        try "inside".write(to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        for (source, destination) in [
            ("link.txt", "copied.txt"), ("outside/secret.txt", "copied.txt"),
            ("inside.txt", "outside/copied.txt")
        ] {
            let result = await copy(root, from: source, to: destination)
            XCTAssertTrue(result.isError, "\(source) → \(destination)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("copied.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copied.txt").path))
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "outside marker")
    }

    func testLegacyGeneralFileExecutorExposesOnlyReads() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileToolService()
        XCTAssertEqual(service.supportedTools, Set(["read_file", "list_dir", "search_files", "find_files"]))
        XCTAssertTrue(WorkspaceToolRegistry.fileTools().allSatisfy { $0.risk == .readOnly })
        let result = await service.execute(ToolRequest(name: "write_file", arguments: ["path": "unsafe.txt", "content": "x"], risk: .localMutation, workspacePath: root.path))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe.txt").path))
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func copy(_ root: URL, from source: String, to destination: String) async -> ToolResult {
        await WorkspaceCopyToolService().execute(ToolRequest(name: "copy_file",
            arguments: ["source": source, "destination": destination], risk: .localMutation, workspacePath: root.path))
    }
}
