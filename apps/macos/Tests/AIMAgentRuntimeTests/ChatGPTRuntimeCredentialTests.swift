@testable import AIMApplication
@testable import AIMAgentRuntime
import AIMCore
import Foundation
import Security
import XCTest

/// Ephemeral RSA keys stay in memory; no keychain access or network.
struct ChatGPTRuntimeTestIssuer {
    let key: SecKey
    let jwks: Data
    let now = Date()
    init() throws {
        key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var position = 0
        func length() -> Int {
            var count = Int(der[position]); position += 1
            if count & 128 != 0 { let bytes = count & 127; count = 0; for _ in 0..<bytes { count = count * 256 + Int(der[position]); position += 1 } }
            return count
        }
        position += 1; _ = length()
        func integer() -> Data { position += 1; let count = length(); let result = Data(der[position..<position+count]); position += count; return Data(result.drop { $0 == 0 }) }
        let n = integer(); let e = integer()
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test-key", "alg": "RS256", "use": "sig", "n": Self.b64(n), "e": Self.b64(e)]]])
    }
    static func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func token(_ changes: [String: Any] = [:], header changesHeader: [String: Any] = [:]) throws -> String {
        var claims: [String: Any] = ["iss": ChatGPTIdentityValidator.issuer, "sub": "subject-one", "aud": "issued", "iat": now.timeIntervalSince1970 - 5, "exp": now.timeIntervalSince1970 + 3600, "nonce": "attempt", "email": "synthetic@example.invalid"]
        claims.merge(changes) { _, new in new }
        var header: [String: Any] = ["alg": "RS256", "kid": "test-key"]
        header.merge(changesHeader) { _, new in new }
        let signing = Self.b64(try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) + "." + Self.b64(try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signing.utf8) as CFData, nil)) as Data
        return signing + "." + Self.b64(signature)
    }
    func response(_ changes: [String: Any] = [:]) throws -> Data {
        var response: [String: Any] = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTPlanAuth.scope, "id_token": try token()]
        response.merge(changes) { _, new in new }; return try JSONSerialization.data(withJSONObject: response)
    }
    func session(_ changes: [String: Any] = [:]) throws -> ChatGPTPlanAuth.Session {
        try ChatGPTPlanAuth.session(from: response(changes), clientID: "issued", hostID: "host", nonce: "attempt", jwks: jwks, now: now)
    }
}

private final class OAuthFixtureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private final class OAuthFixtureResponses: @unchecked Sendable {
    let lock = NSLock()
    var token = Data(), jwks = Data(), status = 200, requests = 0
    func setup(token: Data, jwks: Data, status: Int = 200) { lock.withLock { self.token = token; self.jwks = jwks; self.status = status; requests = 0 } }
    func response(_ url: URL) -> (Data, Int) { lock.withLock { requests += 1; return url == ChatGPTIdentityValidator.jwksURL ? (jwks, 200) : (token, status) } }
    var count: Int { lock.withLock { requests } }
}
private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = OAuthFixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!; let (body, status) = Self.responses.response(url)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class ChatGPTRuntimeCredentialTests: XCTestCase {
    private func fixture(_ value: ChatGPTPlanAuth.Session?) throws -> (OAuthFixtureStore, RuntimeProviderCredentials, URLSession) {
        let store = OAuthFixtureStore()
        try store.store(Data("raw-legacy".utf8), forKey: ChatProvider.chatgpt.rawValue)
        if let value { try store.store(JSONEncoder().encode(value), forKey: ChatGPTPlanAuth.sessionKey) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OAuthFixtureProtocol.self]
        let http = URLSession(configuration: configuration)
        return (store, RuntimeProviderCredentials(provider: .chatgpt, store: store, session: http), http)
    }
    private func denied(_ reader: RuntimeProviderCredentials) async { do { _ = try await reader.value(); XCTFail("Unverified credentials must be refused") } catch {} }
    func testRawCredentialAloneNeverAuthorizesRuntimeOrMakesRequest() async throws {
        OAuthFixtureProtocol.responses.setup(token: Data(), jwks: Data())
        let (store, reader, http) = try fixture(nil); defer { http.invalidateAndCancel() }
        XCTAssertFalse(try RuntimeProviderCredentials.hasCredential(provider: .chatgpt, store: store))
        await denied(reader); XCTAssertEqual(OAuthFixtureProtocol.responses.count, 0)
        XCTAssertEqual(try store.readData(forKey: "chatgpt"), Data("raw-legacy".utf8))
    }
    func testLegacyFreshSessionIsPreservedAndRefusedWithoutNetwork() async throws {
        OAuthFixtureProtocol.responses.setup(token: Data(), jwks: Data())
        let legacy = ChatGPTPlanAuth.Session(clientID: "issued", hostID: "host", accessToken: "legacy", refreshToken: "old", expiresAt: .distantFuture, email: nil)
        let (store, reader, http) = try fixture(legacy); defer { http.invalidateAndCancel() }
        let before = try store.readData(forKey: ChatGPTPlanAuth.sessionKey)
        XCTAssertFalse(try RuntimeProviderCredentials.hasCredential(provider: .chatgpt, store: store))
        await denied(reader); XCTAssertEqual(OAuthFixtureProtocol.responses.count, 0)
        XCTAssertEqual(try store.readData(forKey: ChatGPTPlanAuth.sessionKey), before)
    }
    func testIdentityOnlyCannotFallBackToRawTokenOrRefresh() async throws {
        OAuthFixtureProtocol.responses.setup(token: Data(), jwks: Data())
        let issuer = try ChatGPTRuntimeTestIssuer(); let identityOnly = try issuer.session(["scope": "openid email"])
        let (store, reader, http) = try fixture(identityOnly); defer { http.invalidateAndCancel() }
        XCTAssertFalse(try RuntimeProviderCredentials.hasCredential(provider: .chatgpt, store: store))
        await denied(reader); XCTAssertEqual(OAuthFixtureProtocol.responses.count, 0)
    }
    func testValidFreshGrantSuppliesOnlyVerifiedSessionToken() async throws {
        OAuthFixtureProtocol.responses.setup(token: Data(), jwks: Data())
        let issuer = try ChatGPTRuntimeTestIssuer(); let current = try issuer.session()
        let (store, reader, http) = try fixture(current); defer { http.invalidateAndCancel() }
        XCTAssertTrue(try RuntimeProviderCredentials.hasCredential(provider: .chatgpt, store: store))
        let value = try await reader.value(); XCTAssertEqual(value, current.accessToken); XCTAssertEqual(OAuthFixtureProtocol.responses.count, 0)
    }
    func testRefreshValidatesNewIdentityAndRotatesCompleteStoredSession() async throws {
        let issuer = try ChatGPTRuntimeTestIssuer(); var current = try issuer.session(); current.expiresAt = .distantPast
        OAuthFixtureProtocol.responses.setup(token: try issuer.response(["access_token": "renewed", "refresh_token": "rotated"]), jwks: issuer.jwks)
        let (store, reader, http) = try fixture(current); defer { http.invalidateAndCancel() }
        let value = try await reader.value(); XCTAssertEqual(value, "renewed"); XCTAssertEqual(OAuthFixtureProtocol.responses.count, 2)
        let saved = try JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: XCTUnwrap(store.readData(forKey: ChatGPTPlanAuth.sessionKey)))
        XCTAssertEqual(saved.subject, current.subject); XCTAssertEqual(saved.refreshToken, "rotated"); XCTAssertTrue(saved.canUsePlan)
        XCTAssertEqual(try store.readData(forKey: "chatgpt"), Data("renewed".utf8))
    }
    func testBadRefreshIdentityPreservesExistingSecrets() async throws {
        let issuer = try ChatGPTRuntimeTestIssuer(); var current = try issuer.session(); current.expiresAt = .distantPast
        OAuthFixtureProtocol.responses.setup(token: try issuer.response(["id_token": issuer.token(["sub": "other"])]), jwks: issuer.jwks)
        let (store, reader, http) = try fixture(current); defer { http.invalidateAndCancel() }
        let before = try store.readData(forKey: ChatGPTPlanAuth.sessionKey)
        await denied(reader); XCTAssertEqual(try store.readData(forKey: ChatGPTPlanAuth.sessionKey), before)
        XCTAssertEqual(try store.readData(forKey: "chatgpt"), Data("raw-legacy".utf8))
    }
    func testLostScopeAfterRefreshCannotSupplyInferenceToken() async throws {
        let issuer = try ChatGPTRuntimeTestIssuer(); var current = try issuer.session(); current.expiresAt = .distantPast
        OAuthFixtureProtocol.responses.setup(token: try issuer.response(["scope": "openid email"]), jwks: issuer.jwks)
        let (store, reader, http) = try fixture(current); defer { http.invalidateAndCancel() }
        await denied(reader)
        XCTAssertFalse(try RuntimeProviderCredentials.hasCredential(provider: .chatgpt, store: store))
        let count = OAuthFixtureProtocol.responses.count; await denied(reader); XCTAssertEqual(OAuthFixtureProtocol.responses.count, count)
    }
    func testTransientRefreshFailureDoesNotEraseCredentials() async throws {
        let issuer = try ChatGPTRuntimeTestIssuer(); var current = try issuer.session(); current.expiresAt = .distantPast
        OAuthFixtureProtocol.responses.setup(token: Data(), jwks: issuer.jwks, status: 503)
        let (store, reader, http) = try fixture(current); defer { http.invalidateAndCancel() }
        let before = try store.readData(forKey: ChatGPTPlanAuth.sessionKey)
        await denied(reader); XCTAssertEqual(try store.readData(forKey: ChatGPTPlanAuth.sessionKey), before)
    }
}
