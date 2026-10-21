import Foundation
import XCTest
@testable import AIMCore

final class MediaRound20Tests: XCTestCase {
    private let account = UUID()
    private func job(kind: MediaKind = .image, route: MediaRoute = .openRouter) -> MediaJob {
        .init(accountID: account, conversationID: UUID(), model: .init(id: "test/model", name: "Test", kind: kind, route: route), prompt: "A test landscape")
    }
    func testInterruptedSubmissionIsUncertainAndCannotResumeWithoutProviderID() {
        var value = job(); value.recoverAfterInterruption()
        XCTAssertEqual(value.status, .uncertain); XCTAssertFalse(value.canResume)
        value.status = .awaiting; value.providerJobID = "known-job"; value.pollingURL = URL(string: "https://openrouter.ai/api/v1/videos/known-job")
        value.recoverAfterInterruption(); XCTAssertEqual(value.status, .paused); XCTAssertTrue(value.canResume)
    }
    func testPollingURLsCannotExfiltrateProviderKeys() {
        for raw in ["https://evil.example/api/v1/videos/id", "http://openrouter.ai/api/v1/videos/id", "https://openrouter.ai.evil.example/api/v1/videos/id", "https://user:fixture-user-1@example.invalid/api/v1/videos/id"] {
            XCTAssertThrowsError(try MediaTransport.authorized(URL(string: raw)!, route: .openRouter, key: "secret"))
        }
        let bfl = URL(string: "https://delivery.eu.bfl.ai/result.jpg?token=example")!
        let request = try! MediaTransport.authorized(bfl, route: .blackForestLabs, key: "secret", download: true)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-key")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testImageDiscoveryIncludesMixedModalitiesAndOptionsFromProvider() throws {
        let data = Data(#"{"data":[{"id":"maker/mixed","name":"Mixed","architecture":{"input_modalities":["text","image"],"output_modalities":["text","image"]},"supported_parameters":{"resolution":{"type":"enum","values":["1K","2K"]},"aspect_ratio":{"type":"enum","values":["1:1"]}}}]}"#.utf8)
        let model = try XCTUnwrap(MediaTransport.catalog(data, kind: .image).first)
        XCTAssertEqual(model.resolutions, ["1K", "2K"]); XCTAssertTrue(model.acceptsReferences)
        var value = job(); value.model = model; value.options.resolution = "4K"
        XCTAssertThrowsError(try MediaTransport.submission(value, key: "test-key"))
        value.options.resolution = "2K"
        let request = try MediaTransport.submission(value, key: "test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["resolution"] as? String, "2K"); XCTAssertNil(body["max_tokens"])
    }
    func testVideoJobIdentifierAndPollSurviveEncoding() throws {
        let value = job(kind: .video)
        let data = Data(#"{"id":"known-job","polling_url":"https://openrouter.ai/api/v1/videos/known-job","status":"pending"}"#.utf8)
        guard case let .pending(id, url) = try MediaTransport.decode(data, job: value) else { return XCTFail("Expected durable job") }
        var updated = value; updated.providerJobID = id; updated.pollingURL = url; updated.status = .awaiting
        let restored = try JSONDecoder().decode(MediaJob.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.providerJobID, "known-job"); XCTAssertEqual(restored.pollingURL, url)
        let complete = Data(#"{"id":"known-job","status":"completed","unsigned_urls":["https://openrouter.ai/api/v1/videos/known-job/content?index=0"],"usage":{"cost":0.25}}"#.utf8)
        guard case let .ready(_, _, cost) = try MediaTransport.decode(complete, job: restored) else { return XCTFail("Expected result") }
        XCTAssertEqual(cost, 0.25)
    }
    func testUnknownCostDoesNotBecomeZero() throws {
        let data = Data(#"{"data":[{"b64_json":"iVBORw0KGgo="}]}"#.utf8)
        guard case let .ready(_, bytes, cost) = try MediaTransport.decode(data, job: job()) else { return XCTFail() }
        XCTAssertNotNil(bytes); XCTAssertNil(cost)
    }
    func testBFLOnlyDocumentedImageEndpointsEnabled() throws {
        XCTAssertFalse(MediaModel.blackForestLabs.contains { $0.kind == .video || $0.id.contains("flux-3") })
        var value = job(route: .blackForestLabs); value.model = try XCTUnwrap(MediaModel.blackForestLabs.first)
        let request = try MediaTransport.submission(value, key: "test-key")
        XCTAssertEqual(request.url?.path, "/v1/flux-2-pro-preview"); XCTAssertEqual(request.value(forHTTPHeaderField: "x-key"), "test-key")
        value.model.bflEndpoint = "flux-3-video"
        XCTAssertThrowsError(try MediaTransport.submission(value, key: "test-key"))
    }
    func testTombstoneDominatesBothMergeOrdersAndAccountIsolation() throws {
        let id = UUID()
        let asset = MediaAsset(id: id, accountID: account, conversationID: nil, jobID: id, kind: .image, provider: .openRouter,
                               modelID: "test/model", title: "Test", mimeType: "image/png", byteCount: 8, sha256: String(repeating: "a", count: 64))
        var deleted = asset; deleted.deletedAt = .now
        var foreign = asset; foreign.accountID = UUID()
        for rows in [[asset, deleted, foreign], [deleted, asset, foreign]] {
            let merged = MediaAsset.merge(rows, accountID: account)
            XCTAssertEqual(merged.count, 1); XCTAssertNotNil(merged.first?.deletedAt)
        }
        let data = try JSONEncoder().encode(deleted)
        let decoded = try JSONDecoder().decode(MediaAsset.self, from: data)
        XCTAssertEqual(decoded.accountID, account); XCTAssertNotNil(decoded.deletedAt)
        XCTAssertTrue(asset.objectPath.hasPrefix(account.uuidString.lowercased() + "/"))
    }
    func testFormatDetectionRejectsHTMLAndWrongMediaKinds() throws {
        XCTAssertThrowsError(try MediaTransport.mimeType(Data("<html>error</html>".utf8), kind: .image))
        let png = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])
        XCTAssertEqual(try MediaTransport.mimeType(png, kind: .image), "image/png")
        XCTAssertThrowsError(try MediaTransport.mimeType(png, kind: .video))
    }
    func testImagePriceOnlyKnownWhenAllEndpointChargesAreUnambiguous() throws {
        let model = job().model
        let known = Data(#"{"endpoints":[{"pricing":[{"billable":"output_image","unit":"image","cost_usd":0.05}]}]}"#.utf8)
        XCTAssertEqual(try MediaTransport.imageDetails(known, model: model).priceUSD, 0.05)
        let unknown = Data(#"{"endpoints":[{"pricing":[{"billable":"output_image","unit":"image","cost_usd":0.05},{"billable":"input_image","unit":"image","cost_usd":0.01}]}]}"#.utf8)
        XCTAssertNil(try MediaTransport.imageDetails(unknown, model: model).priceUSD)
    }
    func testStrictMediaReservationRequiresCompleteFixedPrice() throws {
        var value = job()
        XCTAssertNil(MediaCostPolicy.upperBound(for: value))
        value.model.priceUSD = 0.05; value.model.priceUnit = "image"; value.model.fixedPrice = true
        XCTAssertEqual(MediaCostPolicy.upperBound(for: value), 0.05)
        value.model.priceUnit = "token"; XCTAssertNil(MediaCostPolicy.upperBound(for: value))
        value = job(kind: .video); value.model.priceUSD = 0.5; value.model.priceUnit = "second"
        value.options.durationSeconds = 8; value.model.durations = [8]
        XCTAssertNil(MediaCostPolicy.upperBound(for: value))
    }

}
