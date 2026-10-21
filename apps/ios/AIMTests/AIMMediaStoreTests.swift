import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class MediaStoreURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var postCount = 0
    private nonisolated(unsafe) static var failSubmission = false
    private nonisolated(unsafe) static var pendingVideo = false
    private nonisolated(unsafe) static var pollCount = 0
    private nonisolated(unsafe) static var responseCode = 200
    static func reset(fail: Bool, pending: Bool = false, status: Int = 200) { lock.withLock { postCount = 0; pollCount = 0; failSubmission = fail; pendingVideo = pending; responseCode = status } }
    static var submissions: Int { lock.withLock { postCount } }
    static var polls: Int { lock.withLock { pollCount } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (fail, pending, code) = Self.lock.withLock {
            if request.httpMethod == "POST" { Self.postCount += 1 } else { Self.pollCount += 1 }
            return (Self.failSubmission, Self.pendingVideo, Self.responseCode)
        }
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9X8AAAAASUVORK5CYII="
        let data = pending ? Data(#"{"id":"existing-job","polling_url":"https://openrouter.ai/api/v1/videos/existing-job","status":"pending"}"#.utf8)
            : Data("{\"data\":[{\"b64_json\":\"\(png)\"}],\"usage\":{\"cost\":0.04}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class AIMMediaStoreTests: XCTestCase {
    private func transport() -> MediaTransport {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaStoreURLProtocol.self]
        return .init(session: URLSession(configuration: config))
    }
    private func model() -> MediaModel { .init(id: "fixture/image", name: "Fixture", kind: .image, route: .openRouter) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Media operation did not settle")
    }
    func testUnknownSubmissionIsNotReplayedByRestoreOrResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        MediaStoreURLProtocol.reset(fail: true)
        let account = UUID()
        let store = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        let id = try XCTUnwrap(store.create(model: model(), prompt: "Fixture only", conversationID: UUID()))
        try await waitUntil { store.jobs.first?.status == .uncertain }
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 1)
        let restored = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        XCTAssertEqual(restored.jobs.first?.status, .uncertain)
        restored.resume(jobID: id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 1); XCTAssertTrue(restored.visibleAssets.isEmpty)
    }
    func testUnbudgetedImagePersistsOneResultAndKeepsConversationIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        MediaStoreURLProtocol.reset(fail: false)
        let account = UUID(), conversation = UUID()
        var completionCount = 0
        let store = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false }, completion: { job, asset in
            XCTAssertEqual(job.conversationID, conversation); XCTAssertEqual(asset.conversationID, conversation); completionCount += 1
        })
        let id = try XCTUnwrap(store.create(model: model(), prompt: "Fixture only", conversationID: conversation))
        XCTAssertEqual(store.create(model: model(), prompt: "Fixture only", conversationID: conversation), id)
        try await waitUntil { store.jobs.first?.status == .completed }
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 1); XCTAssertEqual(completionCount, 1)
        let asset = try XCTUnwrap(store.visibleAssets.first)
        XCTAssertNotNil(store.localURL(asset: asset)); XCTAssertEqual(store.jobs.first?.costUSD, 0.04)
        let restored = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        XCTAssertEqual(restored.visibleAssets.count, 1); XCTAssertEqual(restored.visibleAssets.first?.id, asset.id)
        let foreign = AIMMediaStore(accountID: UUID(), directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        XCTAssertTrue(foreign.assets.isEmpty); XCTAssertNil(foreign.localURL(asset: asset))
        await store.delete(assetID: asset.id)
        XCTAssertTrue(store.visibleAssets.isEmpty); XCTAssertNil(store.localURL(asset: asset))
    }
    func testStrictBudgetWithoutAtomicAdmissionMakesNoRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        MediaStoreURLProtocol.reset(fail: false)
        let store = AIMMediaStore(accountID: UUID(), directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { true })
        XCTAssertNil(store.create(model: model(), prompt: "Fixture only", conversationID: UUID()))
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 0); XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(store.errorMessage, MediaGenerationError.strictBudgetUnavailable.localizedDescription)
    }
    func testKnownVideoJobRestoresAndResumesOnlyGETPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        MediaStoreURLProtocol.reset(fail: false, pending: true)
        let account = UUID()
        let store = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        var video = model(); video.kind = .video
        let id = try XCTUnwrap(store.create(model: video, prompt: "Fixture video only", conversationID: UUID()))
        try await waitUntil { store.jobs.first?.providerJobID == "existing-job" }
        store.cancelTracking(jobID: id)
        try await Task.sleep(for: .milliseconds(50))
        let before = MediaStoreURLProtocol.polls
        let restored = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
        XCTAssertEqual(restored.jobs.first?.status, .paused)
        restored.resume(jobID: id)
        try await waitUntil { MediaStoreURLProtocol.polls > before }
        restored.cancelTracking(jobID: id)
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 1)
        XCTAssertEqual(restored.jobs.first?.providerJobID, "existing-job")
    }
    func testUnwrittenIntentReleasesAdmissionWithoutSubmitting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        MediaStoreURLProtocol.reset(fail: false)
        let account = UUID()
        var reservations = 0, releases = 0
        let store = AIMMediaStore(accountID: account, directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { true }, admission: { _ in reservations += 1 }, activity: { job in
            if job.status == .failed && job.costConfirmed && job.costUSD == 0 { releases += 1 }
        })
        // An obstructed index simulates a protected/unwritable intent archive after admission succeeds.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(account.uuidString.lowercased()).appendingPathComponent("index.json"), withIntermediateDirectories: true)
        XCTAssertNil(store.create(model: model(), prompt: "Fixture cannot persist", conversationID: UUID()))
        XCTAssertEqual(reservations, 1); XCTAssertEqual(releases, 1)
        XCTAssertEqual(MediaStoreURLProtocol.submissions, 0); XCTAssertTrue(store.jobs.isEmpty)
    }
    func testServerErrorIsUncertainButDefiniteRejectionReleasesCost() async throws {
        for code in [500, 401] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            MediaStoreURLProtocol.reset(fail: false, status: code)
            let store = AIMMediaStore(accountID: UUID(), directory: directory, transport: transport(), key: { _ in "fixture-key" }, budgetEnabled: { false })
            _ = try XCTUnwrap(store.create(model: model(), prompt: "Fixture rejected", conversationID: UUID()))
            try await waitUntil { store.jobs.first?.status != .submitting }
            XCTAssertEqual(MediaStoreURLProtocol.submissions, 1)
            XCTAssertEqual(store.jobs.first?.status, code == 500 ? .uncertain : .failed)
            if code == 500 { XCTAssertNil(store.jobs.first?.costUSD) }
            else { XCTAssertEqual(store.jobs.first?.costUSD, 0); XCTAssertEqual(store.jobs.first?.costConfirmed, true) }
        }
    }

}
