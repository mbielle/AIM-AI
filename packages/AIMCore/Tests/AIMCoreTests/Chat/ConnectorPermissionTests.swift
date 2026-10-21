import Foundation
import XCTest
@testable import AIMCore

final class ConnectorPermissionTests: XCTestCase {
    private let github = "https://api.githubcopilot.com/mcp/"
    func testRemoteAnnotationsNeverAuthorizeUnknownOrChangedEndpoints() {
        for endpoint in ["https://attacker.example/mcp", "http://api.githubcopilot.com/mcp/", "https://api.githubcopilot.com:8443/mcp/",
                         "https://api.githubcopilot.com/mcp/?proxy=1", "https://api.githubcopilot.com//mcp/", "https://fixture-user-1@example.invalid/mcp/", ""] {
            XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: endpoint, action: "get_file_contents", serverClaimsReadOnly: true).authorization, .confirm, endpoint)
        }
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "delete_repository", serverClaimsReadOnly: true).authorization, .confirm)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "get_file_contents", serverClaimsReadOnly: false).authorization, .allow)
    }
    func testPolymorphicReadsRequireAnAuditedMethodAndExceptionsTightenPolicy() {
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "issue_read").authorization, .confirm)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "issue_read", arguments: .object(["method": .string("get_comments")])).authorization, .allow)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "issue_read", arguments: .object(["method": .string("new_method")])).authorization, .confirm)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "merge_pull_request").effect, .modification)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "add_issue_comment").effect, .send)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "get_file_contents", exception: .ask).authorization, .confirm)
        XCTAssertEqual(ConnectorPermissionPolicy.assess(endpoint: github, action: "get_file_contents", exception: .block).authorization, .deny)
    }
    func testExecutionBoundaryEnforcesEnabledFiltersAndPerConnectionExceptions() {
        var first = MCPServerConfiguration(name: "github", transport: .http, url: github, actionPermissions: ["get_file_contents": .block])
        let second = MCPServerConfiguration(name: "github-2", transport: .http, url: github)
        XCTAssertEqual(ConnectorPermissionService.assess(server: first, action: "get_file_contents").authorization, .deny)
        XCTAssertEqual(ConnectorPermissionService.assess(server: second, action: "get_file_contents").authorization, .allow)
        first.actionPermissions = nil; first.excludeTools = ["get_*"]
        XCTAssertEqual(ConnectorPermissionService.assess(server: first, action: "get_file_contents").authorization, .deny)
        first.excludeTools = []; first.enabled = false
        XCTAssertEqual(ConnectorPermissionService.assess(server: first, action: "get_file_contents").authorization, .deny)
        let stdio = MCPServerConfiguration(name: "github", transport: .stdio, command: "/usr/bin/true", trusted: true)
        XCTAssertEqual(ConnectorPermissionService.assess(server: stdio, action: "get_file_contents", serverClaimsReadOnly: true).authorization, .confirm)
    }
    func testSameEndpointKeepsAccountsDistinctAndPreservesLegacyConfigurations() throws {
        let url = URL(string: github)!
        let first = MCPConnectionIdentity.new(name: "GitHub Account", endpoint: url, existing: [])
        let second = MCPConnectionIdentity.new(name: "GitHub Account", endpoint: url, existing: [first])
        XCTAssertNotEqual(first.id, second.id); XCTAssertNotEqual(first.name, second.name)
        XCTAssertEqual(first.url, second.url); XCTAssertTrue(first.isValid); XCTAssertTrue(second.isValid)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        for key in ["accountLabel", "connectorID", "actionPermissions"] { json[key] = nil }
        let legacy = try JSONDecoder().decode(MCPServerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.id, first.id); XCTAssertNil(legacy.actionPermissions); XCTAssertEqual(legacy.displayName, first.name)
    }
}
