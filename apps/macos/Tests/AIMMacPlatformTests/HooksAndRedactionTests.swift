import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

private actor EchoTool: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["echo"]
    private(set) var calls = 0
    func execute(_ request: ToolRequest) async -> ToolResult {
        calls += 1
        return ToolResult(requestID: request.id, content: request.arguments["text"] ?? "")
    }
    func cancel(requestID: String) async {}
}

final class HooksAndRedactionTests: XCTestCase {
    func testRedactorMasksCredentialsButNotCode() {
        let key = "sk-ant-" + String(repeating: "a1B2", count: 8)
        let input = """
        OPENAI_API_KEY=\(key)
        DATABASE_PASSWORD=hunter2hunter2
        let apiKey = config.apiKey
        password: "correct-horse-battery"
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
        """
        let (output, count) = SecretRedactor.redact(input)
        XCTAssertFalse(output.contains(key))
        XCTAssertFalse(output.contains("hunter2hunter2"))
        XCTAssertFalse(output.contains("correct-horse-battery"))
        XCTAssertFalse(output.contains("abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertTrue(output.contains("let apiKey = config.apiKey"))
        XCTAssertTrue(output.contains("DATABASE_PASSWORD=[redacted secret]"), output)
        XCTAssertTrue(output.contains("password: [redacted secret]"), output)
        XCTAssertEqual(count, 4)
        // Already-redacted text stays stable.
        XCTAssertEqual(SecretRedactor.redact(output).count, 0)
        XCTAssertEqual(SecretRedactor.redact("No secrets here, just code: token = nextToken()").count, 0)
    }

    func testDispatcherRedactsResultsAndRunsHooks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aim-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let global = folder.appendingPathComponent("hooks.json")
        try Data("""
        {"hooks": [
          {"event": "PreToolUse", "matcher": "echo", "command": "grep -q forbidden && { echo 'no forbidden words' >&2; exit 2; }; exit 0"},
          {"event": "PostToolUse", "matcher": "ec.*", "command": "echo \\"checked $AIM_TOOL_NAME\\""},
          {"event": "SessionStart", "command": "echo 'branch: main'"},
          {"event": "Stop", "command": "cat > \(folder.path)/stop.json"}
        ]}
        """.utf8).write(to: global)
        let hooks = try XCTUnwrap(AgentHookRunner.load(workspace: nil, globalFile: global))
        let tool = EchoTool()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "echo", risk: .readOnly,
            requiredArguments: ["text"], approvalExempt: true, executor: tool)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        await dispatcher.setHooks(hooks)

        let blocked = await dispatcher.execute(id: "1", name: "echo", arguments: ["text": "a forbidden word"])
        XCTAssertTrue(blocked.isError)
        XCTAssertTrue(blocked.content.contains("no forbidden words"), blocked.content)
        let afterBlock = await tool.calls
        XCTAssertEqual(afterBlock, 0, "a blocked call must not execute")

        let secret = "ghp_" + String(repeating: "Z9", count: 18)
        let allowed = await dispatcher.execute(id: "2", name: "echo", arguments: ["text": "token \(secret)"])
        XCTAssertFalse(allowed.isError, allowed.content)
        XCTAssertFalse(allowed.content.contains(secret))
        XCTAssertTrue(allowed.content.contains("[redacted secret]"))
        XCTAssertTrue(allowed.content.contains("checked echo"), allowed.content)

        let context = await hooks.sessionStart(workspace: nil, prompt: "hi")
        XCTAssertEqual(context, "branch: main")
        await hooks.stop(workspace: nil, answer: "Done.")
        let stop = try Data(contentsOf: folder.appendingPathComponent("stop.json"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: stop) as? [String: Any])
        XCTAssertEqual(payload["event"] as? String, "Stop")
        XCTAssertEqual(payload["answer"] as? String, "Done.")
    }

    func testProjectHooksRequireTrustAndInstructionsAreLoaded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aim-proj-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".aim"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"hooks": [{"event": "PreToolUse", "command": "exit 2"}]}"#.utf8)
            .write(to: project.appendingPathComponent(".aim/hooks.json"))
        try Data("Run `make check` before finishing.".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let global = folder.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: global)
        XCTAssertNil(AgentHookRunner.load(workspace: project.path, globalFile: global), "untrusted project hooks never load")
        try Data(#"{"trusted_projects": ["\#(project.path)"]}"#.utf8).write(to: global)
        XCTAssertEqual(AgentHookRunner.load(workspace: project.path, globalFile: global)?.hooks.count, 1)

        let message = try XCTUnwrap(ProjectInstructionsContext.message(workspace: project.path, conversationID: UUID()))
        XCTAssertTrue(message.content.contains("## AGENTS.md"))
        XCTAssertTrue(message.content.contains("make check"))
        XCTAssertNil(ProjectInstructionsContext.message(workspace: folder.path, conversationID: UUID()))
    }
}
