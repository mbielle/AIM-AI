import AIMApplication
import XCTest

private final class CredentialCheckFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let provider = ChatProvider.allCases.first(where: { $0.host == url.host }) else {
            client?.urlProtocol(self, didFailWithError: ChatServiceError.invalidResponse)
            return
        }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(url.absoluteString.contains("fixture-key"))
        let expectedPath: String
        switch provider {
        case .openRouter: expectedPath = "/api/v1/key"
        case .openAI, .anthropic: expectedPath = "/v1/models"
        case .google: expectedPath = "/v1beta/models"
        case .deepSeek: expectedPath = "/models"
        case .xAI: expectedPath = "/v1/language-models"
        case .perplexity: expectedPath = "/router/v1/models"
        case .local, .chatgpt: expectedPath = "/v1/models"
        default: expectedPath = (URL(string: CompatibleProviders.spec(provider)?.baseURL ?? "")?.path ?? "") + "/models"
        }
        XCTAssertEqual(url.path, expectedPath)
        let header = provider == .google ? request.value(forHTTPHeaderField: "x-goog-api-key")
            : (provider == .anthropic ? request.value(forHTTPHeaderField: "x-api-key")
                : request.value(forHTTPHeaderField: "Authorization"))
        let key = header?.replacingOccurrences(of: "Bearer ", with: "")
        let status = key == "invalid" ? 401 : 200
        let body: String
        if key == "malformed" { body = "{}" }
        else if key == "invalid-json" { body = "not-json" }
        else if provider == .openRouter { body = #"{"data":{"label":"fixture"}}"# }
        else if provider == .google || provider == .xAI { body = #"{"models":[]}"# }
        else { body = #"{"data":[]}"# }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

final class ProviderCredentialCheckTests: XCTestCase {
    private func service() -> ProviderChatService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialCheckFixture.self]
        return ProviderChatService(session: URLSession(configuration: config))
    }

    func testProvidersUseReadOnlyAuthenticatedEndpoints() async throws {
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            let result = try await service().checkCredential(provider: provider, apiKey: "fixture-key")
            XCTAssertEqual(result, provider == .openRouter ? .keyAccepted : .catalogAccessible)
        }
    }

    func testRejectedKeyAndMalformedSuccessDoNotLookVerified() async throws {
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            do {
                _ = try await service().checkCredential(provider: provider, apiKey: "invalid")
                XCTFail("Rejected key must fail for \(provider.name)")
            } catch ChatServiceError.http(let code) { XCTAssertEqual(code, 401) }
            do {
                _ = try await service().checkCredential(provider: provider, apiKey: "malformed")
                XCTFail("Malformed 200 must fail for \(provider.name)")
            } catch ChatServiceError.invalidResponse { }
            do {
                _ = try await service().checkCredential(provider: provider, apiKey: "invalid-json")
                XCTFail("Invalid JSON must fail for \(provider.name)")
            } catch ChatServiceError.invalidResponse { }
        }
        for key in ["", "abc\nInjected: x", "white space"] {
            do { _ = try await service().checkCredential(provider: .openAI, apiKey: key); XCTFail("Unsafe key accepted") }
            catch ChatServiceError.missingKey { }
        }
    }
}
