import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

private actor ScriptedRunner: ProcessRunning {
    var commands: [String] = []
    let exits: [String: Int32]
    init(exits: [String: Int32]) { self.exits = exits }
    func run(_ command: ProcessCommand) -> ProcessOutput {
        let text = command.arguments.last ?? ""
        commands.append(text)
        let code = exits[text] ?? 0
        return ProcessOutput(stdout: code == 0 ? "Executed 12 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds" :
                                "Sources/x.swift:3: error: -[T testA] : XCTAssertEqual failed\nExecuted 12 tests, with 1 failure (0 unexpected) in 0.1 (0.1) seconds",
                             stderr: "", exitCode: code)
    }
    func terminateAll() {}
}

final class ProjectVerificationTests: XCTestCase {
    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files { try content.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecipesAreDetectedFromManifests() throws {
        XCTAssertEqual(ProjectVerificationService.recipe(for: try folder(["Package.swift": ""]))?.steps.map(\.command), ["swift build", "swift test"])
        let node = try folder(["package.json": #"{"scripts":{"build":"tsc","lint":"eslint .","test":"vitest"}}"#, "pnpm-lock.yaml": ""])
        XCTAssertEqual(ProjectVerificationService.recipe(for: node)?.steps.map(\.command), ["pnpm run build", "pnpm run lint", "pnpm test"])
        let placeholder = try folder(["package.json": #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#])
        XCTAssertNil(ProjectVerificationService.recipe(for: placeholder))
        XCTAssertEqual(ProjectVerificationService.recipe(for: try folder(["Cargo.toml": ""]))?.steps.last?.command, "cargo test")
        XCTAssertEqual(ProjectVerificationService.recipe(for: try folder(["go.mod": ""]))?.steps.first?.command, "go build ./...")
        XCTAssertEqual(ProjectVerificationService.recipe(for: try folder(["pyproject.toml": ""]))?.steps.map(\.command), ["python3 -m pytest -q"])
        XCTAssertEqual(ProjectVerificationService.recipe(for: try folder(["Makefile": "all:\n\ttrue\ntest:\n\ttrue\n"]))?.steps.map(\.command), ["make", "make test"])
        XCTAssertNil(ProjectVerificationService.recipe(for: try folder(["README.md": "x"])))
    }

    func testXcodeProjectsAreDetected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("My App.xcodeproj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recipe = try XCTUnwrap(ProjectVerificationService.recipe(for: folder))
        XCTAssertEqual(recipe.project, "Xcode project")
        XCTAssertEqual(recipe.steps.map(\.kind), ["build", "test"])
        XCTAssertTrue(recipe.steps[0].command.contains("-project 'My App.xcodeproj'"))
        // A workspace (CocoaPods, SPM) wins over the project it contains.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("My App.xcworkspace"), withIntermediateDirectories: true)
        XCTAssertTrue(try XCTUnwrap(ProjectVerificationService.recipe(for: folder)).steps[1].command.contains("-workspace 'My App.xcworkspace'"))
    }

    func testSummariesFromCommonRunners() {
        XCTAssertEqual(ProjectVerificationService.summary(of: "x\nTests:       2 failed, 10 passed, 12 total\n"), "Tests:       2 failed, 10 passed, 12 total")
        XCTAssertEqual(ProjectVerificationService.summary(of: "===== 1 failed, 4 passed in 0.52s ====="), "===== 1 failed, 4 passed in 0.52s =====")
        XCTAssertEqual(ProjectVerificationService.summary(of: "test result: FAILED. 3 passed; 1 failed; 0 ignored"), "test result: FAILED. 3 passed; 1 failed; 0 ignored")
        XCTAssertEqual(ProjectVerificationService.summary(of: "ok  \texample.com/a\t0.1s\n--- FAIL: TestB"), "ok  \texample.com/a\t0.1s; --- FAIL: TestB")
    }

    func testRunStopsAtFirstFailureWithAVerdict() async throws {
        let workspace = try folder(["Package.swift": ""])
        let runner = ScriptedRunner(exits: ["swift test": 1])
        let service = ProjectVerificationService(runner: runner)
        let result = await service.execute(ToolRequest(name: "verify_project", arguments: [:], risk: .destructive, workspacePath: workspace.path))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.metadata["verification"], "failed")
        XCTAssertTrue(result.content.contains("Summary: Executed 12 tests, with 1 failure"))
        XCTAssertTrue(result.content.contains("XCTAssertEqual failed"))
        let commands = await runner.commands
        XCTAssertEqual(commands, ["swift build", "swift test"])
        let buildOnly = await service.execute(ToolRequest(name: "verify_project", arguments: ["scope": "build"], risk: .destructive, workspacePath: workspace.path))
        XCTAssertFalse(buildOnly.isError)
        let review = try await service.review(ToolRequest(name: "verify_project", arguments: [:], risk: .destructive, workspacePath: workspace.path))
        XCTAssertEqual(review?.after.hasPrefix("swift build\nswift test"), true)
    }
}
