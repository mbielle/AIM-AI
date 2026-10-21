import AIMAgentKit
@testable import AIMMacPlatform
import AppKit
import CoreText
import Foundation
import XCTest

private final class PDFFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AgentWebFetchPDFTests: XCTestCase {
    /// A one-page PDF with real, selectable text.
    private func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        return data as Data
    }

    func testArxivStylePDFIsReadAsText() async {
        PDFFixture.body = pdf("REFLEX decision cascade abstract")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PDFFixture.self]
        let tool = AgentWebFetchToolService(session: URLSession(configuration: config))
        let result = await tool.execute(ToolRequest(id: "paper", name: "web_fetch",
            arguments: ["url": "https://arxiv.org/pdf/2609.26532"], risk: .externalEffect))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("REFLEX decision cascade abstract"), result.content)
        XCTAssertTrue(result.content.contains("--- Page 1 ---"))
    }

    func testLongTextIsReadPageByPageWithOffsets() {
        let text = String(repeating: "a", count: 150_000) + "END"
        let first = AgentWebFetchToolService.page(text, offset: 0)
        XCTAssertTrue(first.contains("Call web_fetch again with offset 100000"))
        let second = AgentWebFetchToolService.page(text, offset: 100_000)
        XCTAssertTrue(second.hasPrefix("[Text from character 100000.]"))
        XCTAssertTrue(second.contains("END"))
        XCTAssertFalse(second.contains("Text continues"))
        XCTAssertEqual(AgentWebFetchToolService.page("short", offset: 0), "short")
        XCTAssertTrue(AgentWebFetchToolService.page("short", offset: 99).hasPrefix("[No more text"))
    }

    func testRedirectsStayOnPublicPagesAndNeverDowngrade() {
        let https = URL(string: "https://arxiv.org/abs/1")
        XCTAssertTrue(AgentWebFetchToolService.isPublic(URL(string: "https://arxiv.org/pdf/1v2")!))
        XCTAssertFalse(AgentWebFetchToolService.isPublic(URL(string: "http://127.0.0.1/admin")!))
        XCTAssertFalse(AgentWebFetchToolService.isPublic(URL(string: "http://router.local/")!))
        _ = https
    }
}
