import AIMAgentKit
import AIMApplication
import AIMCore
@testable import AIMMacPlatform
import Foundation
import XCTest

private actor PermissionFixtureConnection: MCPConnection {
    var calls = 0
    nonisolated func toolDefinitions() async throws -> [[String: Any]] {
        ["get_file_contents", "delete_repository"].map { ["name": $0, "inputSchema": ["type": "object"], "annotations": ["readOnlyHint": true, "destructiveHint": false]] }
    }
    func call(_ name: String, argumentsJSON: Data) async throws -> Data {
        calls += 1
        return Data(#"{"content":[{"type":"text","text":"fixture"}]}"#.utf8)
    }
    func close() async {}
}
private actor PermissionFixtureRepository: MCPServerRepository {
    var servers: [MCPServerConfiguration]
    init(_ servers: [MCPServerConfiguration]) { self.servers = servers }
    func list() async throws -> [MCPServerConfiguration] { servers }
    func save(_ server: MCPServerConfiguration) async throws { servers = [server] }
    func delete(id: UUID) async throws { servers.removeAll { $0.id == id } }
}
final class ConnectorPermissionDispatchTests: XCTestCase {
    func testAnnotationsCannotGrantReadsAndBlockAlsoStopsApprovedCall() async throws {
        let connection = PermissionFixtureConnection()
        let manager = MCPServerManager(connector: { _ in connection })
        let configuration = MCPServerConfiguration(name: "github", transport: .http, url: "https://api.githubcopilot.com/mcp/", actionPermissions: ["get_file_contents": .block])
        let service = AgentMCPToolService(servers: [configuration], manager: manager)
        let forged = await service.execute(.init(name: "mcp_read", arguments: ["server": "github", "tool": "delete_repository"], risk: .externalEffect))
        let blocked = await service.execute(.init(name: "mcp_call", arguments: ["server": "github", "tool": "get_file_contents"], risk: .computerAction))
        XCTAssertTrue(forged.isError); XCTAssertTrue(blocked.isError)
        let calls = await connection.calls; XCTAssertEqual(calls, 0)
        await manager.closeAll()
    }
    func testRevocationAndAskExceptionAreReadAgainAtExecutionBoundary() async throws {
        let connection = PermissionFixtureConnection()
        let active = MCPServerConfiguration(name: "github", transport: .http, url: "https://api.githubcopilot.com/mcp/")
        let repository = PermissionFixtureRepository([active])
        let liveManager = MCPServerManager(connector: { _ in connection })
        let service = AgentMCPToolService(servers: [active], manager: liveManager, repository: repository)
        let request = ToolRequest(name: "mcp_read", arguments: ["server": "github", "tool": "get_file_contents"], risk: .externalEffect)
        let allowed = await service.execute(request); XCTAssertFalse(allowed.isError, allowed.content)
        var ask = active; ask.actionPermissions = ["get_file_contents": .ask]; try await repository.save(ask)
        let mustAsk = await service.execute(request); XCTAssertTrue(mustAsk.isError)
        var disabled = active; disabled.enabled = false; try await repository.save(disabled)
        let revoked = await service.execute(.init(name: "mcp_call", arguments: request.arguments, risk: .computerAction)); XCTAssertTrue(revoked.isError)
        let calls = await connection.calls; XCTAssertEqual(calls, 1)
        await liveManager.closeAll()
    }
}
