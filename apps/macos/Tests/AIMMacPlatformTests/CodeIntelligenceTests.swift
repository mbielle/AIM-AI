import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class CodeIntelligenceTests: XCTestCase {
    func testSourceKitDiagnosticsSymbolsAndDefinition() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
              CodeIntelligenceToolService.server(forExtension: "swift") != nil else { throw XCTSkip("No Xcode toolchain") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-lsp-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        struct Greeter {
            func greet(_ name: String) -> String { "Hi " + name }
        }

        func run() -> Int {
            let text = Greeter().greet("AIM")
            let wrong: Int = text
            return wrong
        }

        """.write(to: root.appendingPathComponent("Sources/Demo/Demo.swift"), atomically: true, encoding: .utf8)
        let service = CodeIntelligenceToolService()
        func run(_ name: String, _ arguments: [String: String]) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: .readOnly, workspacePath: root.path))
        }
        let diagnostics = await run("code_diagnostics", ["path": "Sources/Demo/Demo.swift"])
        XCTAssertFalse(diagnostics.isError, diagnostics.content)
        XCTAssertTrue(diagnostics.content.contains("Sources/Demo/Demo.swift:7:") && diagnostics.content.contains("error"), diagnostics.content)
        let symbols = await run("code_symbols", ["path": "Sources/Demo/Demo.swift"])
        XCTAssertTrue(symbols.content.contains("struct Greeter (line 1)"), symbols.content)
        XCTAssertTrue(symbols.content.contains("greet"), symbols.content)
        let definition = await run("code_definition", ["path": "Sources/Demo/Demo.swift", "line": "6", "column": "26"])
        XCTAssertTrue(definition.content.contains("Sources/Demo/Demo.swift:2:"), definition.content)
        let outside = await run("code_diagnostics", ["path": "/etc/hosts"])
        XCTAssertTrue(outside.isError)
        await service.closeSession()
    }
}

extension CodeIntelligenceTests {
    func testClosedServerInputReturnsAnErrorWithoutTerminatingTheHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-lsp-closed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try LanguageServerClient(command: ["/bin/sh", "-c", "exec 0<&-; : > stdin-closed; sleep 3"], workspace: root)
        defer { client.stop() }
        let marker = root.appendingPathComponent("stdin-closed")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: marker.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try client.notify("fixture/closed", [:]))
        client.stop()
        XCTAssertThrowsError(try client.notify("fixture/stopped", [:]))
    }
}
