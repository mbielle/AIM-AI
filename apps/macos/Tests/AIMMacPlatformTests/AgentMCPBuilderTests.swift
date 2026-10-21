import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import XCTest

private actor MemoryMCPRepository: MCPServerRepository {
    var servers: [MCPServerConfiguration] = []
    func list() async throws -> [MCPServerConfiguration] { servers }
    func save(_ server: MCPServerConfiguration) async throws { servers.removeAll { $0.id == server.id }; servers.append(server) }
    func delete(id: UUID) async throws { servers.removeAll { $0.id == id } }
}

final class AgentMCPBuilderTests: XCTestCase {
    private func tools(_ items: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self)
    }

    func testAuditRejectsEscapesAndSecrets() {
        func reject(_ code: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try AgentMCPBuilder.parse(["name": "x", "tools_json": tools([["name": "t", "description": "d", "code": code]])]),
                                 code, file: file, line: line)
        }
        reject("const cp = require('child_process');")
        reject("return import('node:net');")
        reject("return process.env.HOME;")
        reject("return ({}).constructor.constructor('return 1')();")
        reject("return eval('1+1');")
        reject("return globalThis;")
        reject("return '\\u0070rocess';")
        reject("const key = 'sk-ant-abcdefghijklmnopqrstuvwxyz0123456789';")
        XCTAssertThrowsError(try AgentMCPBuilder.parse(["name": "bad name!", "tools_json": tools([["name": "t", "description": "d", "code": "return 1"]])]))
        XCTAssertNoThrow(try AgentMCPBuilder.parse(["name": "ok", "allowed_hosts": "api.example.com", "secret_names": "EXAMPLE_TOKEN",
            "tools_json": tools([["name": "t", "description": "d", "code": "const r = await fetch('https://api.example.com/x', {headers: {Authorization: env.EXAMPLE_TOKEN}}); return r.status;"]])]))
    }

    func testGeneratedServerRunsSandboxedThroughTheMCPManager() async throws {
        guard let node = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"] else {
            throw XCTSkip("AIM_TEST_NODE_RUNTIME is required to run a generated server")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-mcp-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MemoryMCPRepository()
        let builder = AgentMCPBuilder(root: root, node: URL(fileURLWithPath: node), repository: repository)
        let arguments = [
            "name": "calc", "description": "Arithmetic helpers", "allowed_hosts": "example.com",
            "tools_json": tools([
                ["name": "add", "description": "Adds a and b", "input_schema": ["type": "object", "properties": ["a": ["type": "number"], "b": ["type": "number"]]],
                 "code": "return { sum: Number(args.a) + Number(args.b) };"],
                ["name": "escape", "description": "Tries to escape", "code": "const F = [].map['con' + 'structor']; return typeof F + ':' + typeof this;"],
                ["name": "blocked", "description": "Fetches a host that is not allowed", "code": "await fetch('https://evil.invalid/'); return 'reached';"]
            ])
        ]
        let review = try await builder.review(ToolRequest(id: "r", name: "create_mcp_server", arguments: arguments, risk: .missionDefinition))
        XCTAssertTrue(review?.after.contains("Number(args.a) + Number(args.b)") == true, "the approval shows the full source")
        let result = await builder.execute(ToolRequest(id: "1", name: "create_mcp_server", arguments: arguments, risk: .missionDefinition))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("3 tool(s)"), result.content)
        let saved = try await repository.list()
        let server = try XCTUnwrap(saved.first)
        XCTAssertFalse(server.trusted)
        XCTAssertTrue(server.arguments.contains("--permission"))
        defer { Task { await MCPServerManager.shared.disconnect(server.id) } }

        func call(_ tool: String, _ json: String = "{}") async throws -> String {
            String(decoding: try await MCPServerManager.shared.call(server: server, tool: tool, argumentsJSON: Data(json.utf8)), as: UTF8.self)
        }
        let sum = try await call("add", #"{"a": 2, "b": 40}"#)
        XCTAssertTrue(sum.contains("42"), sum)
        let escape = try await call("escape")
        XCTAssertTrue(escape.contains("undefined:undefined"), "Function constructor and `this` are neutered: \(escape)")
        let blocked = try await call("blocked")
        XCTAssertTrue(blocked.contains("may not contact evil.invalid"), blocked)
    }
}
