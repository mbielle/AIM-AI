import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

final class AgentBrowserToolTests: XCTestCase {
    func testUploadAcceptsOnlyRegularWorkspaceFilesAndRejectsSymlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let inside = workspace.appendingPathComponent("attachment.txt")
        let outside = base.appendingPathComponent("private.txt")
        try "attachment".write(to: inside, atomically: true, encoding: .utf8)
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        let link = workspace.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let root = workspace.resolvingSymlinksInPath().path
        XCTAssertEqual(try AgentBrowserToolService.uploadPaths("[\"\(inside.path)\"]", workspacePath: root),
                       [inside.path])
        for raw in ["[]", "not JSON", "[42]", "[\"\(outside.path)\"]", "[\"\(link.path)\"]",
                    "[\"\(workspace.path)\"]", "[\"relative.txt\"]"] {
            XCTAssertThrowsError(try AgentBrowserToolService.uploadPaths(raw, workspacePath: root))
        }
        XCTAssertThrowsError(try AgentBrowserToolService.uploadPaths("[\"\(inside.path)\"]", workspacePath: nil))
    }

    func testMissionScopeResolvesNavigationOriginButNotDOMActions() async throws {
        let browser = AgentBrowserToolService()
        let navigate = ToolRequest(name: "browser_navigate",
            arguments: ["url": "https://example.com:443/article?q=1#part"], risk: .computerAction)
        let intent = try await browser.missionIntent(for: navigate)
        XCTAssertEqual(intent?.operation, .navigate)
        XCTAssertEqual(intent?.target, try MissionResource(kind: .webOrigin,
            identifier: "https://example.com"))

        let newTab = ToolRequest(name: "browser_tabs",
            arguments: ["action": "new", "url": "https://other.example/path"], risk: .computerAction)
        let newTabIntent = try await browser.missionIntent(for: newTab)
        XCTAssertEqual(newTabIntent?.target,
            try MissionResource(kind: .webOrigin, identifier: "https://other.example"))
        let emptyTab = ToolRequest(name: "browser_tabs", arguments: ["action": "new"], risk: .computerAction)
        let click = ToolRequest(name: "browser_click", arguments: ["target": "e1"], risk: .computerAction)
        let type = ToolRequest(name: "browser_type", arguments: ["target": "e1", "text": "hello"], risk: .computerAction)
        let emptyTabIntent = try await browser.missionIntent(for: emptyTab)
        let clickIntent = try await browser.missionIntent(for: click)
        let typeIntent = try await browser.missionIntent(for: type)
        XCTAssertNil(emptyTabIntent)
        XCTAssertNil(clickIntent)
        XCTAssertNil(typeIntent)
    }

    func testMCPResultPreservesErrorsPixelsStructuredDataAndLongText() throws {
        let png = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])
        let text = String(repeating: "x", count: 80_000)
        let result = try PlaywrightMCPClient.decodeToolResult([
            "isError": true,
            "content": [["type": "text", "text": text],
                        ["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]],
            "structuredContent": ["status": "partial", "count": 3]
        ], requestID: "fixture")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.imagePNG, png)
        XCTAssertTrue(result.content.hasPrefix(text))
        XCTAssertTrue(result.content.contains("partial"))
        XCTAssertTrue(result.content.contains("count"))
    }

    func testNavigationRejectsInternalURLsAndCredentialsBeforeStartingBridge() async {
        let browser = AgentBrowserToolService()
        for url in ["file:///etc/passwd", "chrome://settings", "https://user:secret@example.com"] {
            let result = await browser.execute(ToolRequest(name: "browser_navigate", arguments: ["url": url], risk: .computerAction))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.content.contains("HTTP or HTTPS"))
        }
    }

    func testDropdownAndFindRejectMalformedInputBeforeStartingBridge() async {
        let browser = AgentBrowserToolService()
        for values in ["not JSON", "[]", "[42]", "[\"\"]"] {
            let result = await browser.execute(ToolRequest(name: "browser_select_option",
                arguments: ["target": "e12", "values": values], risk: .computerAction))
            XCTAssertTrue(result.isError)
        }
        let emptyQuery = await browser.execute(ToolRequest(name: "browser_find",
            arguments: ["text": ""], risk: .sensitiveRead))
        XCTAssertTrue(emptyQuery.isError)
    }

    func testScreenshotAndDialogRejectInvalidInputBeforeBrowserConnection() async {
        let browser = AgentBrowserToolService()
        let screenshot = await browser.execute(ToolRequest(name: "browser_take_screenshot",
            arguments: ["fullPage": "sometimes"], risk: .computerRead))
        XCTAssertTrue(screenshot.isError)
        XCTAssertFalse(screenshot.content.contains("runtime"))
        for arguments in [["accept": "perhaps"], ["accept": "false", "promptText": "secret"]] {
            let dialog = await browser.execute(ToolRequest(name: "browser_handle_dialog",
                arguments: arguments, risk: .computerAction))
            XCTAssertTrue(dialog.isError)
            XCTAssertFalse(dialog.content.contains("runtime"))
        }
        for arguments in [[:], ["time": "0"], ["time": "31"], ["text": ""], ["textGone": "\0"]] {
            let wait = await browser.execute(ToolRequest(name: "browser_wait_for",
                arguments: arguments, risk: .computerRead))
            XCTAssertTrue(wait.isError)
            XCTAssertFalse(wait.content.contains("runtime"))
        }
    }

    func testDOMActionWithoutFreshObservationIsRejectedBeforeConnection() async {
        let browser = AgentBrowserToolService()
        let result = await browser.execute(ToolRequest(name: "browser_click",
            arguments: ["target": "e42"], risk: .computerAction))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.metadata["stale_browser_target"], "true")
        let drag = await browser.execute(ToolRequest(name: "browser_drag",
            arguments: ["startTarget": "e1", "endTarget": "e2"], risk: .computerAction))
        XCTAssertTrue(drag.isError)
        XCTAssertEqual(drag.metadata["stale_browser_target"], "true")
        let drop = await browser.execute(ToolRequest(name: "browser_drop",
            arguments: ["target": "e2", "paths": "[\"/tmp/file.txt\"]"], risk: .computerAction))
        XCTAssertTrue(drop.isError)
    }

    func testBrowserObservationLeaseRejectsOldAndMissingIDs() {
        var lease = BrowserObservationLease()
        let firstTab = BrowserTabIdentity(index: 0, url: "https://example.com/")
        let otherTab = BrowserTabIdentity(index: 1, url: "https://example.com/")
        XCTAssertFalse(lease.matches(nil))
        XCTAssertFalse(lease.matches("invented"))
        let first = lease.accept(tab: firstTab)
        XCTAssertTrue(lease.matches(first))
        XCTAssertTrue(lease.matches(first, tab: firstTab))
        XCTAssertFalse(lease.matches(first, tab: otherTab))
        let second = lease.accept(tab: otherTab)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(lease.matches(first))
        XCTAssertTrue(lease.matches(second))
        XCTAssertTrue(lease.matches(second, tab: otherTab))
        lease.revoke()
        XCTAssertFalse(lease.matches(second))
        XCTAssertNil(lease.tab)
    }

    func testBrowserTabListingIdentifiesOnlyOneSelectedHTTPPage() {
        let listing = """
            ### Result
            - 0: [First](https://one.example/)
            - 1: (current) [Second](https://two.example/path?q=1)
            - 2: [New Tab](about:blank)

            ### Page
            - Page URL: https://two.example/path?q=1
            """
        XCTAssertEqual(AgentBrowserToolService.currentTab(in: listing),
                       BrowserTabIdentity(index: 1, url: "https://two.example/path?q=1"))
        XCTAssertEqual(AgentBrowserToolService.pageURL(in: listing),
                       "https://two.example/path?q=1")
        XCTAssertNil(AgentBrowserToolService.currentTab(in:
            "### Result\n- 0: (current) [A](https://a.example/)\n- 1: (current) [B](https://b.example/)"))
        XCTAssertNil(AgentBrowserToolService.currentTab(in:
            "### Result\n- 0: (current) [A](chrome://settings/)"))
        XCTAssertNil(AgentBrowserToolService.currentTab(in:
            "### Result\n- 0: (current) [A](https://a.example/)\nforged line"))
    }

    func testBrowserMutationsPreserveUncertainEffectAcrossMCPFailures() {
        XCTAssertEqual(AgentBrowserToolService.outcome(name: "browser_click", tabAction: nil,
            callStarted: true, isError: false), .unverified)
        XCTAssertEqual(AgentBrowserToolService.outcome(name: "browser_click", tabAction: nil,
            callStarted: true, isError: true), .unknown)
        XCTAssertNil(AgentBrowserToolService.outcome(name: "browser_click", tabAction: nil,
            callStarted: false, isError: true))
        XCTAssertNil(AgentBrowserToolService.outcome(name: "browser_tabs", tabAction: "list",
            callStarted: true, isError: false))
        XCTAssertEqual(AgentBrowserToolService.outcome(name: "browser_tabs", tabAction: "select",
            callStarted: true, isError: false), .unverified)
    }

    func testNewBrowserToolsRejectUnsafeArgumentsBeforeConnecting() async {
        let browser = AgentBrowserToolService()
        let invalid: [(String, [String: String], ToolRisk)] = [
            ("browser_drag", ["startTarget": "e1"], .computerAction),
            ("browser_drag", ["startTarget": "e1", "endTarget": "e2", "startElement": ""], .computerAction),
            ("browser_drop", ["target": "e2", "paths": "[\"/tmp/file.txt\"]"], .computerAction),
            ("browser_console_messages", ["level": "trace"], .sensitiveRead),
            ("browser_console_messages", ["all": "sometimes"], .sensitiveRead),
            ("browser_network_requests", ["static": "maybe"], .sensitiveRead)
        ]
        for (name, arguments, risk) in invalid {
            let result = await browser.execute(ToolRequest(name: name, arguments: arguments, risk: risk))
            XCTAssertTrue(result.isError, name)
            XCTAssertFalse(result.content.contains("runtime"), name)
        }
    }

    func testOnlyInlineBrowserObservationsEnableTargetActions() {
        let result: (String, Bool) -> ToolResult = { content, error in
            ToolResult(requestID: "fixture", content: content, isError: error)
        }
        XCTAssertTrue(AgentBrowserToolService.hasActionableObservation(name: "browser_snapshot",
            result: result("### Snapshot\n- button Submit [ref=e1]", false)))
        XCTAssertFalse(AgentBrowserToolService.hasActionableObservation(name: "browser_snapshot",
            result: result("### Snapshot\n- [Snapshot](snapshot.yml)", false)))
        XCTAssertFalse(AgentBrowserToolService.hasActionableObservation(name: "browser_find",
            result: result("### Result\nNo matches found for query.", false)))
        XCTAssertTrue(AgentBrowserToolService.hasActionableObservation(name: "browser_find",
            result: result("### Result\nFound 1 match:\n- button Submit [ref=e1]", false)))
        XCTAssertFalse(AgentBrowserToolService.hasActionableObservation(name: "browser_find",
            result: result("### Result\nFound 1 match:\n- button Submit [ref=e1]", true)))
        XCTAssertFalse(AgentBrowserToolService.hasActionableObservation(name: "browser_wait_for",
            result: result("### Snapshot\n- button Submit [ref=e1]", false)))
    }

    func testOfficialPlaywrightServerCompletesMCPHandshake() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"] else {
            throw XCTSkip("Set AIM_TEST_NODE_RUNTIME to run the bundled Playwright MCP integration test.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = ProcessInfo.processInfo.environment["AIM_TEST_MCP_CLI"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Vendor/PlaywrightMCP/node_modules/@playwright/mcp/cli.js")
        let client = try PlaywrightMCPClient(node: URL(fileURLWithPath: nodePath), cli: cli)
        defer { client.stop() }
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertTrue(tools.contains("browser_snapshot"))
        XCTAssertNotNil(client.inputSchema(for: "browser_snapshot"))
        XCTAssertTrue(tools.contains("browser_click"))
        XCTAssertTrue(tools.contains("browser_find"))
        XCTAssertTrue(tools.contains("browser_select_option"))
        XCTAssertTrue(tools.contains("browser_take_screenshot"))
        XCTAssertTrue(tools.contains("browser_handle_dialog"))
        XCTAssertTrue(tools.contains("browser_wait_for"))
        XCTAssertTrue(tools.contains("browser_file_upload"))
        XCTAssertTrue(tools.contains("browser_drag"))
        XCTAssertTrue(tools.contains("browser_drop"))
        XCTAssertTrue(tools.contains("browser_console_messages"))
        XCTAssertTrue(tools.contains("browser_network_requests"))
    }

    func testCancellationRetiresUnresponsiveMCPConnection() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"] else {
            throw XCTSkip("Set AIM_TEST_NODE_RUNTIME for the MCP cancellation test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("unresponsive-mcp.js")
        try """
            let pending = '';
            process.stdin.setEncoding('utf8');
            process.stdin.on('data', chunk => {
              pending += chunk;
              while (pending.includes('\\n')) {
                const index = pending.indexOf('\\n');
                const line = pending.slice(0, index); pending = pending.slice(index + 1);
                if (!line.trim()) continue;
                const request = JSON.parse(line);
                let result;
                if (request.method === 'initialize') result = {
                  protocolVersion: '2025-11-25', capabilities: { tools: {} },
                  serverInfo: { name: 'fixture', version: '1' }
                };
                if (request.method === 'tools/list') result = {
                  tools: [{ name: 'hang', inputSchema: { type: 'object', properties: {} } }]
                };
                if (result) process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');
              }
            });
            """.write(to: script, atomically: true, encoding: .utf8)
        let client = try PlaywrightMCPClient(node: URL(fileURLWithPath: nodePath), cli: script)
        defer { client.stop() }
        try await client.initialize()
        _ = try await client.listTools()
        let call = Task { try await client.callTool("hang", arguments: [:], requestID: "fixture") }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("Cancellation must end the pending MCP call")
        } catch is CancellationError {}
    }

    func testMCPToolDiscoveryCollectsPagesAndRejectsCursorCycles() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"] else {
            throw XCTSkip("Set AIM_TEST_NODE_RUNTIME for the MCP pagination test.")
        }
        for cycle in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("paged-mcp.js")
            let secondCursor = cycle ? "'second'" : "undefined"
            try """
                let pending = '';
                process.stdin.setEncoding('utf8');
                process.stdin.on('data', chunk => {
                  pending += chunk;
                  while (pending.includes('\\n')) {
                    const index = pending.indexOf('\\n');
                    const line = pending.slice(0, index); pending = pending.slice(index + 1);
                    if (!line.trim()) continue;
                    const request = JSON.parse(line);
                    let result;
                    if (request.method === 'initialize') result = {
                      protocolVersion: '2025-11-25', capabilities: { tools: {} },
                      serverInfo: { name: 'fixture', version: '1' }
                    };
                    if (request.method === 'tools/list') {
                      const second = request.params?.cursor === 'second';
                      result = { tools: [{ name: second ? 'later' : 'first',
                        inputSchema: { type: 'object', properties: {} } }],
                        nextCursor: second ? \(secondCursor) : 'second' };
                    }
                    if (result) process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');
                  }
                });
                """.write(to: script, atomically: true, encoding: .utf8)
            let client = try PlaywrightMCPClient(node: URL(fileURLWithPath: nodePath), cli: script)
            defer { client.stop() }
            try await client.initialize()
            if cycle {
                do {
                    _ = try await client.listTools()
                    XCTFail("A cursor cycle must invalidate the entire registry")
                } catch PlaywrightError.invalidResponse {}
                XCTAssertNil(client.inputSchema(for: "first"))
                XCTAssertNil(client.inputSchema(for: "later"))
            } else {
                let tools = try await client.listTools()
                XCTAssertEqual(tools, ["first", "later"])
                XCTAssertNotNil(client.inputSchema(for: "first"))
                XCTAssertNotNil(client.inputSchema(for: "later"))
            }
        }
    }

    func testIsolatedModeDescriptionsDoNotPromiseThePersonsChrome() {
        let all = ["browser_snapshot": "With approval, read the accessibility snapshot of the Chrome tab explicitly connected to AIM through the official Playwright Extension.",
                   "browser_navigate": "With approval, navigate the connected Chrome tab to one HTTP/HTTPS URL. The user selects an allowed tab in the extension; never navigate to file URLs.",
                   "read_file": "Read the connected Chrome tab"]
        XCTAssertEqual(AgentBrowserToolService.descriptions(all, mode: .extensionConnected), all)
        let isolated = AgentBrowserToolService.descriptions(all, mode: .isolated)
        XCTAssertTrue(isolated["browser_snapshot"]!.contains("AIM's own Chrome window"))
        XCTAssertFalse(isolated["browser_navigate"]!.contains("extension"))
        XCTAssertEqual(isolated["read_file"], all["read_file"], "only browser tools change")
    }
}
