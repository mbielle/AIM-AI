import AIMCore
@testable import AIMMacPlatform
import XCTest

private actor DirectoryRepository: MCPServerRepository {
    let servers: [MCPServerConfiguration]
    init(_ servers: [MCPServerConfiguration]) { self.servers = servers }
    func list() -> [MCPServerConfiguration] { servers }
    func save(_ server: MCPServerConfiguration) {}
    func delete(id: UUID) {}
}

final class RemoteConnectorDirectoryTests: XCTestCase {
    func testListDoesNotConnectAndNeverExportsConfiguration() async throws {
        let active = MCPServerConfiguration(name: "slack", transport: .http,
            url: "https://example.test/mcp?secret=do-not-export", secretNames: ["AUTHORIZATION"],
            accountLabel: "Work", connectorID: "slack")
        let disabled = MCPServerConfiguration(name: "local", transport: .stdio,
            command: "/private/secret/server", arguments: ["private-argument"], enabled: false)
        let manager = MCPServerManager(connector: { _ in
            XCTFail("A directory read must not establish a connection")
            throw RemoteSecurityServiceError.invalidResponse
        })
        let raw = try await RemoteConnectorDirectoryReader.result(repository: DirectoryRepository([active, disabled]), manager: manager)
        let directory = try RemoteConnectorDirectory(json: raw)
        XCTAssertEqual(directory.connectors.map(\.status), [.saved, .disabled])
        XCTAssertEqual(directory.connectors.first?.identity, "slack")
        XCTAssertEqual(directory.connectors.first?.name, "Work")
        XCTAssertNil(directory.connectors.first?.toolCount)
        let encoded = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        for forbidden in ["do-not-export", "private-argument", "AUTHORIZATION", "/private/secret", "url", "secretNames"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testDirectoryVersionAndSectionAreValidated() throws {
        let value = RemoteConnectorDirectory(connectors: [])
        XCTAssertEqual(try RemoteConnectorDirectory(json: value.json), value)
        XCTAssertThrowsError(try RemoteConnectorDirectory(json: .object(["section": .string("skills"), "version": .number(1), "connectors": .array([])])))
        XCTAssertThrowsError(try RemoteConnectorDirectory(json: .object(["section": .string("connectors"), "version": .number(2), "connectors": .array([])])))
    }
}
