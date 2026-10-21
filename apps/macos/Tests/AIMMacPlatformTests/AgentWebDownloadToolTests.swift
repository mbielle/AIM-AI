import AIMAgentKit
import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

final class AgentWebDownloadToolTests: XCTestCase {
    func testDownloadsNewFileWithReceiptAndNeverOverwritesIt() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let payload = Data("fixture download\n".utf8)
        DownloadURLProtocol.configure(status: 200, data: payload)
        let service = AgentWebDownloadToolService(session: Self.session())
        let request = ToolRequest(name: "web_download",
            arguments: ["url": "https://example.com/file.txt", "destination": "result.txt"],
            risk: .externalEffect, workspacePath: workspace.path)
        let result = await service.execute(request)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.actionOutcome, .confirmed)
        XCTAssertEqual(result.metadata["bytes"], String(payload.count))
        XCTAssertEqual(result.metadata["sha256"], "f815c8d45f251dd1b7865ac07fcf045d12d4669993db62f1c64610bbd1b419b1")
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("result.txt")), payload)

        let duplicate = await service.execute(request)
        XCTAssertTrue(duplicate.isError)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("result.txt")), payload)
    }

    func testRejectsWorkspaceEscapeAndPrivateURL() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"),
                                                    withDestinationURL: outside)
        DownloadURLProtocol.configure(status: 200, data: Data("private".utf8))
        let service = AgentWebDownloadToolService(session: Self.session())
        for destination in ["../outside.txt", "/tmp/outside.txt", "escape/file.txt"] {
            let result = await service.execute(ToolRequest(name: "web_download",
                arguments: ["url": "https://example.com/file", "destination": destination],
                risk: .externalEffect, workspacePath: workspace.path))
            XCTAssertTrue(result.isError, destination)
        }
        let privateHost = await service.execute(ToolRequest(name: "web_download",
            arguments: ["url": "http://127.0.0.1/file", "destination": "safe.txt"],
            risk: .externalEffect, workspacePath: workspace.path))
        XCTAssertTrue(privateHost.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("safe.txt").path))
    }

    func testHTTPFailureLeavesNoFile() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        DownloadURLProtocol.configure(status: 404, data: Data("missing".utf8))
        let service = AgentWebDownloadToolService(session: Self.session())
        let result = await service.execute(ToolRequest(name: "web_download",
            arguments: ["url": "https://example.com/file", "destination": "not-created.txt"],
            risk: .externalEffect, workspacePath: workspace.path))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("not-created.txt").path))
    }

    func testPartialHTTPResponseIsNotMisreportedAsComplete() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        DownloadURLProtocol.configure(status: 206, data: Data("partial".utf8))
        let service = AgentWebDownloadToolService(session: Self.session())
        let result = await service.execute(ToolRequest(name: "web_download",
            arguments: ["url": "https://example.com/file", "destination": "partial.txt"],
            risk: .computerAction, workspacePath: workspace.path))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("partial.txt").path))
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DownloadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: (Int, Data) = (200, Data())

    static func configure(status: Int, data: Data) {
        lock.withLock { response = (status, data) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock { Self.response }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
