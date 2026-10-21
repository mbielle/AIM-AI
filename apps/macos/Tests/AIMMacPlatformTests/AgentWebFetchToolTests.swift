import AIMAgentKit
import AIMMacPlatform
import Foundation
import XCTest

private final class WebFetchFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<h1>Useful heading</h1><script>ignore me</script><p>Readable content</p>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AgentWebFetchToolTests: XCTestCase {
    func testReturnsBoundedReadableTextWithoutScripts() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebFetchFixture.self]
        let tool = AgentWebFetchToolService(session: URLSession(configuration: config))
        let result = await tool.execute(ToolRequest(id: "page", name: "web_fetch",
            arguments: ["url": "https://example.com/page"], risk: .externalEffect))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Useful heading"))
        XCTAssertTrue(result.content.contains("Readable content"))
        XCTAssertFalse(result.content.contains("ignore me"))
        XCTAssertEqual(result.metadata["url"], "https://example.com/page")
    }

    func testRejectsCredentialsAndNonWebSchemesWithoutNetwork() async {
        let tool = AgentWebFetchToolService()
        for address in ["file:///private/etc/passwd", "https://user:secret@example.com/", "javascript:alert(1)", "not a URL",
                        "http://localhost:8080/", "http://127.0.0.1/", "http://169.254.169.254/", "http://[::ffff:127.0.0.1]/"] {
            let result = await tool.execute(ToolRequest(id: UUID().uuidString, name: "web_fetch",
                arguments: ["url": address], risk: .readOnly))
            XCTAssertTrue(result.isError, address)
        }
    }
}
