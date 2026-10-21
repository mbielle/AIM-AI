import Foundation
import Supabase
import XCTest
@testable import AIMCore

private final class SnapshotAuthStorage: AuthLocalStorage, @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? { data }
    func remove(key: String) throws {}
}
private final class SnapshotUploadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var recorded: [URLRequest] { lock.withLock { requests } }
    func response(_ request: URLRequest) throws -> Data {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = bytes
        }
        lock.withLock { requests.append(request) }
        guard let url = request.url, !url.path.contains("/functions/") else { throw URLError(.unsupportedURL) }
        if url.path.contains("/storage/") { return Data(#"{"Key":"fixture","Id":"object-1"}"#.utf8) }
        if request.httpMethod == "PATCH" { return Data() }
        return Data(#"{"id":"file-1","name":"reference.pdf","mime_type":"application/pdf","size_bytes":12,"status":"completed","error_message":null,"created_at":"2026-01-01T00:00:00Z"}"#.utf8)
    }
}
private final class SnapshotUploadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders: [String: SnapshotUploadRecorder] = [:]
    static func register(_ recorder: SnapshotUploadRecorder, host: String) { lock.withLock { recorders[host] = recorder } }
    static func remove(_ host: String) { _ = lock.withLock { recorders.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let recorder = Self.lock.withLock({ Self.recorders[host] }) else { throw URLError(.unsupportedURL) }
            let data = try recorder.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ProjectFileSnapshotTests: XCTestCase {
    private func fixture() throws -> (SupabaseCloudContentService, SnapshotUploadRecorder, UUID, String) {
        let owner = UUID(), recorder = SnapshotUploadRecorder(), host = UUID().uuidString.lowercased() + ".invalid"
        SnapshotUploadProtocol.register(recorder, host: host)
        let user = User(id: owner, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
        let auth = Session(accessToken: "fixture-token", tokenType: "bearer", expiresIn: 3600, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "fixture-refresh", user: user)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SnapshotUploadProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://" + host)!, supabaseKey: "fixture-public", options: .init(auth: .init(storage: SnapshotAuthStorage(try JSONEncoder().encode(auth)), storageKey: "snapshot-fixture", autoRefreshToken: false), global: .init(session: URLSession(configuration: config))))
        return (SupabaseCloudContentService(client: client), recorder, owner, host)
    }
    func testReviewedPDFSnapshotUploadsOriginalAndPersistsTextWithoutProcessor() async throws {
        let (service, recorder, owner, host) = try fixture(); defer { SnapshotUploadProtocol.remove(host) }
        let file = try await service.uploadProjectFile(projectID: "project-1", data: Data("original PDF".utf8), name: "reference.pdf", mimeType: "application/pdf", extractedText: "Reviewed local PDF text")
        XCTAssertEqual(file.status, "completed")
        let requests = recorder.recorded
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/functions/") })
        let insert = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url!.path == "/rest/v1/project_files" })
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(insert.httpBody)) as? [String: Any])
        XCTAssertEqual(metadata["project_id"] as? String, "project-1")
        XCTAssertEqual(metadata["user_id"] as? String, owner.uuidString.lowercased())
        XCTAssertEqual(metadata["name"] as? String, "reference.pdf")
        XCTAssertEqual(metadata["mime_type"] as? String, "application/pdf")
        XCTAssertEqual(metadata["size_bytes"] as? Int, Data("original PDF".utf8).count)
        XCTAssertEqual(metadata["status"] as? String, "uploading")
        XCTAssertEqual(metadata["processing_status"] as? String, "pending")
        let upload = try XCTUnwrap(requests.first { $0.url!.path.contains("/storage/") })
        XCTAssertTrue(upload.url!.path.contains("/project-files-user/\(owner.uuidString.lowercased())/project-1/file-1/reference.pdf"))
        // Storage SDK sends multipart, preserving the original as a binary file part.
        let contentType = try XCTUnwrap(upload.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data;"))
        let multipart = try XCTUnwrap(String(data: try XCTUnwrap(upload.httpBody), encoding: .utf8))
        let filePart = try XCTUnwrap(multipart.components(separatedBy: "--" + boundary).first { $0.contains("filename=\"reference.pdf\"") })
        let separator = try XCTUnwrap(filePart.range(of: "\r\n\r\n"))
        XCTAssertTrue(filePart[..<separator.lowerBound].contains("Content-Type: application/pdf"))
        XCTAssertEqual(String(filePart[separator.upperBound...]), "original PDF\r\n")
        let update = try XCTUnwrap(requests.first { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(update.httpBody)) as? [String: Any])
        XCTAssertEqual(body["extracted_content"] as? String, "Reviewed local PDF text")
        XCTAssertEqual(body["status"] as? String, "completed")
        XCTAssertEqual(body["processing_status"] as? String, "completed")
        XCTAssertEqual(body["storage_path"] as? String, "\(owner.uuidString.lowercased())/project-1/file-1/reference.pdf")
        XCTAssertTrue(update.url!.query!.contains("user_id=eq.\(owner.uuidString.lowercased())"))
    }
    func testInvalidSnapshotIsRejectedBeforeAnyHTTP() async throws {
        let (service, recorder, _, host) = try fixture(); defer { SnapshotUploadProtocol.remove(host) }
        for text in ["", "  ", "bad\0text", String(repeating: "a", count: 64_001)] {
            do { _ = try await service.uploadProjectFile(projectID: "p", data: Data([1]), name: "a.pdf", mimeType: "application/pdf", extractedText: text); XCTFail("Invalid snapshot admitted") }
            catch {}
        }
        do { _ = try await service.uploadProjectFile(projectID: "p", data: Data(repeating: 1, count: 20_000_001), name: "a.pdf", mimeType: "application/pdf", extractedText: "text"); XCTFail("Oversized original admitted") }
        catch {}
        XCTAssertTrue(recorder.recorded.isEmpty)
    }
}
