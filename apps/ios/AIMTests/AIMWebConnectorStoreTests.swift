import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class ConnectorTestSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failingKey: String?
    func store(_ data: Data, forKey key: String) throws {
        try lock.withLock { if key == failingKey { throw CocoaError(.fileWriteUnknown) }; values[key] = data }
    }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
@MainActor final class AIMWebConnectorStoreTests: XCTestCase {
    private let endpoint = URL(string: "https://connector.example/mcp")!
    private func tokens(_ token: String, resource: URL? = nil) throws -> MCPAuthorizationTokens {
        let json: [String: String] = ["accessToken": token, "clientID": "fixture", "tokenEndpoint": "https://auth.example/token", "resource": (resource ?? endpoint).absoluteString]
        return try JSONDecoder().decode(MCPAuthorizationTokens.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testMultipleAccountsAndExplicitReconnectKeepCredentialsSeparate() throws {
        let account = UUID(), secrets = ConnectorTestSecrets(), store = AIMWebConnectorStore(accountID: UUID(), credentials: ConnectorTestSecrets())
        // The account above is deliberately different: another store never observes the same list by URL.
        XCTAssertTrue(store.servers.isEmpty)
        let firstStore = AIMWebConnectorStore(accountID: account, credentials: secrets)
        let first = try firstStore.saveOAuth(name: "Work account", url: endpoint, tokens: tokens("first"))
        let second = try firstStore.saveOAuth(name: "Work account", url: endpoint, tokens: tokens("second"))
        XCTAssertEqual(firstStore.servers.count, 2); XCTAssertNotEqual(first.id, second.id); XCTAssertNotEqual(first.name, second.name)
        _ = try firstStore.saveOAuth(name: first.name, url: endpoint, tokens: tokens("renewed"), reconnecting: first.id)
        func saved(_ id: UUID) throws -> MCPAuthorizationTokens {
            try JSONDecoder().decode(MCPAuthorizationTokens.self, from: XCTUnwrap(secrets.readData(forKey: account.uuidString + "." + id.uuidString + ".oauth")))
        }
        XCTAssertEqual(try saved(first.id).accessToken, "renewed"); XCTAssertEqual(try saved(second.id).accessToken, "second")
        XCTAssertEqual(AIMWebConnectorStore(accountID: account, credentials: secrets).servers.count, 2)
        XCTAssertTrue(AIMWebConnectorStore(accountID: UUID(), credentials: secrets).servers.isEmpty)
    }
    func testFailedPersistenceDoesNotReplaceOrLoseExistingOAuthAccount() throws {
        let account = UUID(), secrets = ConnectorTestSecrets(), first = AIMWebConnectorStore(accountID: UUID(), credentials: ConnectorTestSecrets())
        XCTAssertTrue(first.servers.isEmpty)
        let store = AIMWebConnectorStore(accountID: account, credentials: secrets)
        let existing = try store.saveOAuth(name: "Work", url: endpoint, tokens: tokens("original"))
        secrets.failingKey = "servers." + account.uuidString
        XCTAssertThrowsError(try store.saveOAuth(name: "Another", url: endpoint, tokens: tokens("new")))
        XCTAssertThrowsError(try store.saveOAuth(name: "Work", url: endpoint, tokens: tokens("changed"), reconnecting: existing.id))
        XCTAssertEqual(store.servers.map(\.id), [existing.id])
        let data = try XCTUnwrap(secrets.readData(forKey: account.uuidString + "." + existing.id.uuidString + ".oauth"))
        XCTAssertEqual(try JSONDecoder().decode(MCPAuthorizationTokens.self, from: data).accessToken, "original")
    }
    func testPermissionsStayOnTheirConnectionAndForeignReconnectIsRejected() throws {
        let secrets = ConnectorTestSecrets(), account = UUID(), store = AIMWebConnectorStore(accountID: UUID(), credentials: ConnectorTestSecrets())
        XCTAssertTrue(store.servers.isEmpty)
        let owner = AIMWebConnectorStore(accountID: account, credentials: secrets)
        let url = URL(string: "https://api.githubcopilot.com/mcp/")!
        let first = try owner.add(name: "GitHub", url: url.absoluteString, token: "fixture")
        let second = try owner.add(name: "GitHub", url: url.absoluteString, token: "fixture-2")
        owner.setPermission(serverID: first.id, action: "get_file_contents", decision: .block)
        XCTAssertEqual(owner.assessment(serverID: first.id, action: "get_file_contents").authorization, .deny)
        XCTAssertEqual(owner.assessment(serverID: second.id, action: "get_file_contents").authorization, .allow)
        XCTAssertThrowsError(try owner.saveOAuth(name: "Foreign", url: endpoint, tokens: tokens("bad"), reconnecting: first.id))
        XCTAssertEqual(owner.servers.count, 2)
        let reloaded = AIMWebConnectorStore(accountID: account, credentials: secrets)
        XCTAssertEqual(reloaded.assessment(serverID: first.id, action: "get_file_contents").authorization, .deny)
    }
}
