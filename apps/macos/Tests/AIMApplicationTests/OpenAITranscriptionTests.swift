import AIMApplication
import XCTest

private final class TranscriptionFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        if let body = request.httpBody, let contents = String(data: body, encoding: .utf8) {
            XCTAssertTrue(contents.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
            XCTAssertTrue(contents.contains("filename=\"speech.m4a\""))
            XCTAssertTrue(contents.contains("fixture-audio"))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"Bonjour AIM"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TranscriptionHTTPErrorFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer rejected-key" ? 401 : 429
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"provider detail must not reach the user"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenAITranscriptionTests: XCTestCase {
    func testAuthenticatedTranscriptionInsertsNoAIMQuota() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionFixture.self]
        let service = OpenAITranscriptionService(session: URLSession(configuration: config))
        let text = try await service.transcribe(m4a: Data("fixture-audio".utf8), apiKey: "fixture-key")
        XCTAssertEqual(text, "Bonjour AIM")
    }

    func testInvalidInputsNeverReachNetwork() async throws {
        let service = OpenAITranscriptionService()
        do {
            _ = try await service.transcribe(m4a: Data("audio".utf8), apiKey: "bad\nkey")
            XCTFail("Unsafe key accepted")
        } catch OpenAITranscriptionError.missingKey {}
        do {
            _ = try await service.transcribe(m4a: Data(), apiKey: "fixture-key")
            XCTFail("Empty audio accepted")
        } catch OpenAITranscriptionError.emptyRecording {}
        do {
            _ = try await service.transcribe(m4a: Data(count: 25_000_001), apiKey: "fixture-key")
            XCTFail("Oversize audio accepted")
        } catch OpenAITranscriptionError.recordingTooLarge {}
    }

    func testProviderAuthAndRateErrorsAreDistinctWithoutExposingResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionHTTPErrorFixture.self]
        let service = OpenAITranscriptionService(session: URLSession(configuration: config))
        do {
            _ = try await service.transcribe(m4a: Data("audio".utf8), apiKey: "rejected-key")
            XCTFail("Rejected key accepted")
        } catch OpenAITranscriptionError.credentialsRejected {}
        do {
            _ = try await service.transcribe(m4a: Data("audio".utf8), apiKey: "throttled-key")
            XCTFail("Provider rate limit accepted")
        } catch OpenAITranscriptionError.providerRateLimited {}
        XCTAssertFalse(OpenAITranscriptionError.providerRateLimited.localizedDescription.contains("provider detail"))
    }
}
