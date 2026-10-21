import AIMAgentKit
import AIMMacPlatform
import XCTest

final class PlatformFoundationTests: XCTestCase {
    func testLoggerRedactsCommonSecrets() {
        let input = "Authorization: Bearer abc123 api_key=secret token=my-token"
        let redacted = RedactedLogger.redact(input)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("my-token"))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testProcessRunnerCapturesOutput() async throws {
        let runner = MacProcessRunner()
        let output = try await runner.run(ProcessCommand(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["native"]
        ))
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "native")
    }

    func testFileServiceRejectsTraversalOutsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileToolService()
        let result = await service.execute(ToolRequest(
            name: "read_file",
            arguments: ["path": "../outside.txt"],
            risk: .readOnly,
            workspacePath: root.path
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("outside"))
    }
}
