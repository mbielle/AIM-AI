import Foundation
import XCTest
@testable import AIMCore

private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let mutex = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var foreignIssuer = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.mutex.withLock { Self.requests.append(request) }
        let root: [String: Any]
        switch request.url!.path {
        case "/.well-known/oauth-protected-resource/mcp":
            root = ["resource": "https://connector.example/mcp", "authorization_servers": ["https://auth.example"]]
        case "/.well-known/oauth-authorization-server":
            root = ["issuer": Self.mutex.withLock { Self.foreignIssuer ? "https://foreign.example" : "https://auth.example" },
                "authorization_endpoint": "https://auth.example/authorize", "token_endpoint": "https://auth.example/token",
                "registration_endpoint": "https://auth.example/register", "code_challenge_methods_supported": ["S256"]]
        case "/register": root = ["client_id": "public-fixture"]
        case "/token": root = ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600, "token_type": "Bearer"]
        default: root = [:]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: root))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class MCPAuthorizationTests: XCTestCase {
    private let resource = URL(string: "https://connector.example/mcp")!, callback = URL(string: "https://aim-ai.tech/auth/mcp/ios")!
    private func session(foreignIssuer: Bool = false) -> URLSession {
        OAuthFixtureProtocol.mutex.withLock { OAuthFixtureProtocol.requests = []; OAuthFixtureProtocol.foreignIssuer = foreignIssuer }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OAuthFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    func testDiscoveryPKCEAudienceExchangeAndRefreshStayOnVerifiedEndpoints() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let flow = try await MCPAuthorizationFlow.prepare(resource: resource, callback: callback, session: session)
        let items = URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "resource" }?.value, resource.absoluteString)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        let state = try XCTUnwrap(items.first { $0.name == "state" }?.value)
        let returned = URL(string: callback.absoluteString + "?code=fixture-code&state=" + state)!
        let request = try flow.exchangeRequest(callback: returned)
        XCTAssertEqual(request.url?.host, "auth.example"); XCTAssertNil(request.url?.query)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("resource=https%3A%2F%2Fconnector.example%2Fmcp")); XCTAssertTrue(body.contains("code_verifier="))
        let tokens = try await flow.exchange(callback: returned, session: session)
        let refreshed = try await tokens.refreshed(session: session, force: true)
        XCTAssertEqual(refreshed.resource, resource); XCTAssertEqual(refreshed.accessToken, "fixture-access")
        let requests = OAuthFixtureProtocol.mutex.withLock { OAuthFixtureProtocol.requests }
        XCTAssertFalse(requests.contains { $0.url!.absoluteString.contains("fixture-access") || $0.url!.absoluteString.contains("fixture-refresh") })
        XCTAssertEqual(requests.filter { $0.url?.path == "/token" }.count, 2)
    }
    func testForeignIssuerCannotReceiveRegistrationOrVerifier() async {
        let session = session(foreignIssuer: true); defer { session.invalidateAndCancel() }
        do { _ = try await MCPAuthorizationFlow.prepare(resource: resource, callback: callback, session: session); XCTFail("Foreign issuer must fail discovery") }
        catch { }
        let requests = OAuthFixtureProtocol.mutex.withLock { OAuthFixtureProtocol.requests }
        XCTAssertFalse(requests.contains { $0.url?.path == "/register" || $0.url?.path == "/token" })
    }
    func testCallbackRejectsMissingForeignDuplicatedStateAndExpiration() throws {
        let start = Date(timeIntervalSince1970: 100)
        let flow = try MCPAuthorizationFlow(authorizationEndpoint: URL(string: "https://auth.example/authorize")!, tokenEndpoint: URL(string: "https://auth.example/token")!, resource: resource, callbackURL: callback, clientID: "public", now: start)
        let state = URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        for raw in [callback.absoluteString + "?code=x", callback.absoluteString + "?code=x&state=wrong", callback.absoluteString + "?code=x&state=" + state + "&state=" + state,
                    "https://foreign.example/auth/mcp/ios?code=x&state=" + state] {
            XCTAssertThrowsError(try flow.exchangeRequest(callback: URL(string: raw)!, now: start))
        }
        XCTAssertThrowsError(try flow.exchangeRequest(callback: URL(string: callback.absoluteString + "?code=x&state=" + state)!, now: start.addingTimeInterval(301)))
    }
}
