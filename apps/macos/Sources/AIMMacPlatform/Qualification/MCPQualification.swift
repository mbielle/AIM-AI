#if DEBUG
import AIMAgentKit
import AIMApplication
import Foundation

/// Real MCP qualification through AIM's generic connector path: AIM's fixture
/// server and the bundled Playwright MCP server, both configured like any
/// user-added stdio server.
public enum MCPQualification {
    /// Same script as Tests/Fixtures/MCP/fixture-server.js.
    public static let fixtureScript = #"""
// Minimal stdio MCP server for AIM tests. No network, no file access.
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin });
const notes = [];
const tools = [
  { name: 'echo', description: 'Echo text back.', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'add_note', description: 'Store a note in memory.', inputSchema: { type: 'object', properties: { note: { type: 'string' }, tags: { type: 'array', items: { type: 'string' } }, meta: { type: 'object', properties: { priority: { type: 'integer' } } } }, required: ['note'] }, annotations: { readOnlyHint: false, destructiveHint: false } },
  { name: 'list_notes', description: 'List stored notes.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'token_present', description: 'Report whether FIXTURE_TOKEN reached the server.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'hidden_admin', description: 'Must be filtered out by AIM.', inputSchema: { type: 'object', properties: {} } }
];
rl.on('line', (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id === undefined) return;
  const reply = (result) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }) + '\n');
  const text = (value, isError = false) => reply({ content: [{ type: 'text', text: value }], isError });
  switch (message.method) {
    case 'initialize':
      return reply({ protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'aim-mcp-fixture', version: '1.0.0' } });
    case 'tools/list':
      return reply({ tools });
    case 'tools/call': {
      const { name, arguments: args = {} } = message.params || {};
      if (name === 'echo') return text(String(args.text));
      if (name === 'add_note') { notes.push({ note: args.note, tags: args.tags || [], priority: args.meta?.priority ?? null }); return reply({ content: [{ type: 'text', text: 'stored' }], structuredContent: { count: notes.length } }); }
      if (name === 'list_notes') return reply({ content: [{ type: 'text', text: JSON.stringify(notes) }] });
      if (name === 'token_present') return text(process.env.FIXTURE_TOKEN ? 'token:yes' : 'token:no');
      return text('unknown tool', true);
    }
    default:
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } }) + '\n');
  }
});
"""#

    public static func fixtureConfiguration(name: String = "aimfixture") -> MCPServerConfiguration? {
        guard let node = HostBundleResources.resourceURL?.appendingPathComponent("Playwright/node"),
              FileManager.default.isExecutableFile(atPath: node.path) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-mcp-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fixture-server.js")
        try? fixtureScript.write(to: script, atomically: true, encoding: .utf8)
        // A fixed identity lets a later host check reach the same running session.
        return MCPServerConfiguration(id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-00000000F1F1")!, name: name,
            transport: .stdio, command: node.path, arguments: [script.path],
            trusted: true, excludeTools: ["hidden_*"],
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    public static func run(into report: QualificationReport) async {
        var cases: [String: Bool] = [:]
        var notes: [String: String] = [:]
        let manager = MCPServerManager()
        guard let fixture = fixtureConfiguration() else {
            report.set("conclusion", "The bundled Node runtime is absent.")
            return
        }
        let service = AgentMCPToolService(servers: [fixture], manager: manager)
        func run(_ name: String, _ arguments: [String: String]) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: .computerAction))
        }
        let listed = await run("mcp_list_tools", [:])
        cases["fixture_listed"] = !listed.isError && listed.content.contains("\"add_note\"") && !listed.content.contains("hidden_admin")
        let stored = await run("mcp_call", ["server": fixture.name, "tool": "add_note",
            "arguments_json": #"{"note":"qualification é","tags":["a"],"meta":{"priority":3}}"#])
        let notesResult = await run("mcp_call", ["server": fixture.name, "tool": "list_notes"])
        cases["fixture_call_and_read"] = !stored.isError && notesResult.content.contains("qualification é") &&
            notesResult.content.contains("\"priority\":3")
        if case .connected = await manager.status(of: fixture) { cases["fixture_connected_status"] = true } else {
            cases["fixture_connected_status"] = false
        }

        // The bundled Playwright MCP server as an ordinary user-configured server.
        if let root = HostBundleResources.resourceURL?.appendingPathComponent("Playwright") {
            let playwright = MCPServerConfiguration(name: "playwright", transport: .stdio,
                command: root.appendingPathComponent("node").path,
                arguments: [root.appendingPathComponent("node_modules/@playwright/mcp/cli.js").path,
                            "--browser", "chrome", "--isolated", "--headless", "--no-webmcp"],
                trusted: false, includeTools: ["browser_*"])
            let browser = AgentMCPToolService(servers: [playwright], manager: manager)
            let tools = await browser.execute(ToolRequest(name: "mcp_list_tools",
                arguments: ["server": "playwright", "query": "navigate"], risk: .readOnly))
            cases["playwright_generic_listing"] = !tools.isError && tools.content.contains("browser_navigate")
            let navigated = await browser.execute(ToolRequest(name: "mcp_call", arguments: ["server": "playwright",
                "tool": "browser_navigate", "arguments_json": #"{"url":"data:text/html,<title>AIM MCP</title><h1>ok</h1>"}"#],
                risk: .computerAction))
            notes["playwright_navigate"] = String(navigated.content.prefix(300))
            cases["playwright_generic_call"] = !navigated.isError && navigated.content.contains("AIM MCP")
            let readRoute = await browser.execute(ToolRequest(name: "mcp_read", arguments: ["server": "playwright",
                "tool": "browser_snapshot"], risk: .externalEffect))
            cases["untrusted_read_route_refused"] = readRoute.isError
        }

        // A server that cannot start is paused after repeated failures.
        let broken = MCPServerConfiguration(name: "broken", transport: .stdio, command: "/usr/bin/false")
        let brokenService = AgentMCPToolService(servers: [broken], manager: manager)
        for _ in 0..<4 {
            _ = await brokenService.execute(ToolRequest(name: "mcp_list_tools", arguments: [:], risk: .readOnly))
        }
        if case .coolingDown = await manager.status(of: broken) { cases["circuit_breaker"] = true } else {
            cases["circuit_breaker"] = false
        }
        await manager.closeAll()
        report.set("cases", cases)
        report.set("notes", notes)
        let failed = cases.filter { !$0.value }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all MCP cases passed (\(cases.count))" : "failed: \(failed.joined(separator: ", "))")
    }
}
#endif
