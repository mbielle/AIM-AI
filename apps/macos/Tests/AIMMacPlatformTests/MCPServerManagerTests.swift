import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class MCPServerManagerTests: XCTestCase {
    private func fixtureServer(name: String = "fixture", trusted: Bool = true,
                               exclude: [String] = ["hidden_*"]) throws -> MCPServerConfiguration {
        guard let node = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"],
              FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("AIM_TEST_NODE_RUNTIME is required for the stdio MCP fixture")
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/MCP/fixture-server.js")
        return MCPServerConfiguration(name: name, transport: .stdio, command: node, arguments: [script.path],
            trusted: trusted, excludeTools: exclude)
    }

    func testCircuitBreakerPausesARepeatedlyFailingServer() async throws {
        let attempts = Counter()
        var now = Date(timeIntervalSince1970: 1_000)
        let clock = NowBox(now)
        let manager = MCPServerManager(connector: { _ in
            attempts.increment()
            throw URLError(.cannotConnectToHost)
        }, clock: { clock.value })
        let server = MCPServerConfiguration(name: "broken", transport: .stdio, command: "/usr/bin/false")
        for _ in 0..<MCPServerManager.failureThreshold {
            do { _ = try await manager.tools(of: server); XCTFail("must fail") } catch {}
        }
        do {
            _ = try await manager.tools(of: server)
            XCTFail("A paused server must not be contacted")
        } catch MCPManagerError.coolingDown {}
        XCTAssertEqual(attempts.count, MCPServerManager.failureThreshold)
        if case .coolingDown = await manager.status(of: server) {} else { XCTFail("status must show the pause") }
        now = now.addingTimeInterval(MCPServerManager.coolDown + 1)
        clock.value = now
        do { _ = try await manager.tools(of: server) } catch {}
        XCTAssertEqual(attempts.count, MCPServerManager.failureThreshold + 1, "After the pause one new attempt is allowed")
    }

    func testImportKeepsSecretsOutOfTheConfiguration() throws {
        let json = """
        {"mcpServers": {
          "github": {"command": "/usr/local/bin/github-mcp", "args": ["stdio"], "env": {"GITHUB_TOKEN": "ghp_secret"}},
          "remote": {"url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer abc"}}
        }}
        """
        let entries = try MCPServerImport.parse(Data(json.utf8))
        XCTAssertEqual(entries.map(\.configuration.name), ["github", "remote"])
        XCTAssertEqual(entries[0].configuration.secretNames, ["GITHUB_TOKEN"])
        XCTAssertEqual(entries[0].secrets["GITHUB_TOKEN"], "ghp_secret")
        let encoded = String(decoding: try JSONEncoder().encode(entries[0].configuration), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ghp_secret"), "Secret values never enter the stored configuration")
        XCTAssertEqual(entries[1].configuration.transport, .http)
        XCTAssertEqual(entries[1].configuration.secretNames, ["AUTHORIZATION"])
        XCTAssertThrowsError(try MCPServerImport.parse(Data(#"{"mcpServers":{"x":{"url":"http://example.com"}}}"#.utf8)),
            "Plain HTTP to a remote host is refused")
        XCTAssertThrowsError(try MCPServerImport.parse(Data(#"{"mcpServers":{"x":{"command":"npx"}}}"#.utf8)),
            "A bare command must be resolved to an absolute executable first")
    }

    func testToolFiltersAndNames() {
        let server = MCPServerConfiguration(name: "srv", transport: .stdio, command: "/bin/echo",
            includeTools: ["read_*", "list"], excludeTools: ["read_secret*"])
        XCTAssertTrue(server.allows(tool: "read_file"))
        XCTAssertTrue(server.allows(tool: "list"))
        XCTAssertFalse(server.allows(tool: "read_secret_key"))
        XCTAssertFalse(server.allows(tool: "write_file"))
        XCTAssertFalse(MCPServerConfiguration.isValidName("bad name"))
    }

    func testRealStdioServerThroughTheAgentSurface() async throws {
        let server = try fixtureServer()
        let manager = MCPServerManager()
        let service = AgentMCPToolService(servers: [server], manager: manager)
        func run(_ name: String, _ arguments: [String: String]) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: .computerAction))
        }
        let listed = await run("mcp_list_tools", [:])
        XCTAssertFalse(listed.isError, listed.content)
        XCTAssertTrue(listed.content.contains("\"echo\""))
        XCTAssertFalse(listed.content.contains("hidden_admin"), "Excluded tools are never offered")
        let deniedAnnotation = await run("mcp_read", ["server": "fixture", "tool": "echo", "arguments_json": #"{"text":"not sent"}"#])
        XCTAssertTrue(deniedAnnotation.isError, "A trusted stdio server's read-only annotation is not verified evidence")
        let echoed = await run("mcp_call", ["server": "fixture", "tool": "echo", "arguments_json": #"{"text":"bonjour é"}"#])
        XCTAssertFalse(echoed.isError, echoed.content)
        XCTAssertTrue(echoed.content.contains("bonjour é"))
        let readMutation = await run("mcp_read", ["server": "fixture", "tool": "add_note", "arguments_json": #"{"note":"x"}"#])
        XCTAssertTrue(readMutation.isError, "A mutation cannot use the read-only route")
        let stored = await run("mcp_call", ["server": "fixture", "tool": "add_note",
            "arguments_json": #"{"note":"live","tags":["a","b"],"meta":{"priority":2}}"#])
        XCTAssertFalse(stored.isError, stored.content)
        XCTAssertEqual(stored.actionOutcome, .unverified)
        XCTAssertTrue(stored.content.contains("\"count\":1"))
        let notes = await run("mcp_call", ["server": "fixture", "tool": "list_notes"])
        XCTAssertTrue(notes.content.contains("\"priority\":2"), "Nested JSON arguments reach the server intact")
        let missing = await run("mcp_call", ["server": "fixture", "tool": "add_note", "arguments_json": "{}"])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.actionOutcome, .suspectedAbsent, "Rejected before contacting the server")
        let filtered = await run("mcp_call", ["server": "fixture", "tool": "hidden_admin"])
        XCTAssertTrue(filtered.isError)
        let token = await run("mcp_call", ["server": "fixture", "tool": "token_present"])
        XCTAssertTrue(token.content.contains("token:no"), "Only configured secrets are passed to a server")
        await manager.closeAll()
    }

    func testUntrustedServerHasNoReadOnlyRoute() async throws {
        let server = try fixtureServer(name: "untrusted", trusted: false)
        let manager = MCPServerManager()
        let service = AgentMCPToolService(servers: [server], manager: manager)
        let result = await service.execute(ToolRequest(name: "mcp_read",
            arguments: ["server": "untrusted", "tool": "echo", "arguments_json": #"{"text":"x"}"#], risk: .externalEffect))
        XCTAssertTrue(result.isError)
        let review = try await service.review(ToolRequest(name: "mcp_call",
            arguments: ["server": "untrusted", "tool": "echo", "arguments_json": #"{"text":"x"}"#], risk: .computerAction))
        XCTAssertTrue(review?.path.contains("untrusted server") == true)
        await manager.closeAll()
    }
}

private final class NowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
