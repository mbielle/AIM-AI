import AIMAgentKit
import AIMApplication
import XCTest
@testable import AIMMacPlatform

private final class SearchLimitFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var sent: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        Self.lock.withLock { Self.sent = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        let rows = (0..<12).map { ["title": "Result \($0)", "url": "https://example.com/\($0)", "snippet": String(repeating: "text", count: 200)] }
        let bytes = try! JSONSerialization.data(withJSONObject: ["results": rows])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AgentWebSearchLimitTests: XCTestCase {
    func testEngineDefaultKeepsLongQueryAllResultsAndCompleteSnippets() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchLimitFixture.self]
        let service = AgentWebSearchToolService(backends: .init(perplexityKey: "fixture", allowKeyless: false), session: URLSession(configuration: config))
        let query = String(repeating: "long query ", count: 100)
        let response = await service.execute(.init(name: "web_search", arguments: ["query": query], risk: .readOnly))
        XCTAssertFalse(response.isError); XCTAssertEqual(response.metadata["result_count"], "12")
        XCTAssertTrue(response.content.contains(String(repeating: "text", count: 200)))
        let sent = SearchLimitFixture.lock.withLock { SearchLimitFixture.sent }
        XCTAssertEqual(sent["query"] as? String, query.trimmingCharacters(in: .whitespacesAndNewlines)); XCTAssertNil(sent["max_results"])
    }
    func testExplicitResultLimitIsPreservedWithoutTenResultClamp() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchLimitFixture.self]
        let service = AgentWebSearchToolService(backends: .init(perplexityKey: "fixture", allowKeyless: false), session: URLSession(configuration: config))
        let response = await service.execute(.init(name: "web_search", arguments: ["query": "fixture", "max_results": "11"], risk: .readOnly))
        XCTAssertFalse(response.isError); XCTAssertEqual(response.metadata["result_count"], "11")
        XCTAssertEqual(SearchLimitFixture.lock.withLock { SearchLimitFixture.sent["max_results"] as? Int }, 11)
    }
}
