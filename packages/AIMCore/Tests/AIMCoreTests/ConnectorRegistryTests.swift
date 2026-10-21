import Foundation
import Testing
@testable import AIMCore

@Suite("Connector directory discovery")
struct ConnectorRegistryTests {
    @Test func searchAndCursorAreEncodedAsValues() {
        let url = ConnectorRegistry.requestURL(query: "design & docs", cursor: "a+b&next=x")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "search" }?.value == "design & docs")
        #expect(items.first { $0.name == "cursor" }?.value == "a+b&next=x")
        #expect(items.count == 3)
    }

    @Test func registryCannotInstallLocalOrInsecureTransports() throws {
        let json = #"{"servers":[{"server":{"name":"org/good","remotes":[{"type":"streamable-http","url":"https://example.com/mcp"}]}},{"server":{"name":"org/sse","remotes":[{"type":"sse","url":"https://example.org/events"}]}},{"server":{"name":"org/local","remotes":[{"type":"stdio","url":"file:///etc/passwd"}]}},{"server":{"name":"org/template","remotes":[{"type":"streamable-http","url":"https://example.net/{secret}"}]}},{"server":{"name":"org/secret","remotes":[{"type":"streamable-http","url":"https://user:password@example.net/mcp"}]}}],"metadata":{"nextCursor":"page2"}}"#
        let page = try ConnectorRegistry.decode(Data(json.utf8))
        #expect(page.connectors.map(\.id) == ["registry:org/good", "registry:org/sse"])
        #expect(page.connectors[0].supportsIPhone)
        #expect(!page.connectors[1].supportsIPhone)
        #expect(page.nextCursor == "page2")
    }

    @Test func iPhoneTransportWinsWhenServerOffersBoth() throws {
        let json = #"{"servers":[{"server":{"name":"org/both","remotes":[{"type":"sse","url":"https://example.org/sse"},{"type":"streamable-http","url":"https://example.org/mcp"}]}}]}"#
        let page = try ConnectorRegistry.decode(Data(json.utf8))
        #expect(page.connectors.first?.url == "https://example.org/mcp")
        #expect(page.connectors.first?.supportsIPhone == true)
    }

    @Test func curatedIdentityWinsAndRegistryPagesDeduplicate() {
        let known = ConnectorCatalog.connectors.first { $0.id == "notion" }!
        let duplicate = PortableConnector(id: "registry:notion", name: "Other title", description: "", url: "https://MCP.NOTION.COM/mcp/", category: "Registry", publisher: "other")
        let result = ConnectorRegistry.merged(curated: [known], discovered: [duplicate, duplicate])
        #expect(result == [known])
    }

    @Test func historicalConnectorDecodesWithoutTransport() throws {
        let encoded = try JSONEncoder().encode(ConnectorCatalog.connectors[0])
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "transport")
        let decoded = try JSONDecoder().decode(PortableConnector.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.transport == nil)
        #expect(decoded.supportsIPhone)
    }
}
