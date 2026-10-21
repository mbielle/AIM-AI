@testable import AIMApplication
import Foundation
import Security
import XCTest

/// Ephemeral RSA keys stay in memory; no keychain access or network.
struct ChatGPTTestIssuer {
    let key: SecKey
    let jwks: Data
    let now = Date(timeIntervalSince1970: 1000)
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
        var claims: [String: Any] = ["iss": ChatGPTIdentityValidator.issuer, "sub": "subject-one", "aud": "issued", "iat": 995, "exp": 2000, "nonce": "attempt", "email": "synthetic@example.invalid"]
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

final class ChatGPTIdentityTests: XCTestCase {
    func testValidSignatureIdentityNonceAndStoredGrant() throws {
        let issuer = try ChatGPTTestIssuer(); let session = try issuer.session()
        XCTAssertEqual(session.subject, "subject-one"); XCTAssertEqual(session.email, "synthetic@example.invalid")
        XCTAssertTrue(session.canUsePlan); XCTAssertEqual(try JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: JSONEncoder().encode(session)), session)
    }
    func testRejectsSignatureTamperingAndUntrustedKeys() throws {
        let issuer = try ChatGPTTestIssuer(); let other = try ChatGPTTestIssuer(); let token = try issuer.token()
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(token, jwks: other.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
        var parts = token.components(separatedBy: "."); parts[1] = ChatGPTTestIssuer.b64(Data(#"{"sub":"attacker"}"#.utf8))
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(parts.joined(separator: "."), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
    }
    func testRejectsIssuerAudienceExpiryNonceSubjectAndFutureClaims() throws {
        let issuer = try ChatGPTTestIssuer()
        for claims in [["iss": "https://evil.invalid"], ["aud": "wrong"], ["exp": 900], ["nonce": "wrong"], ["sub": ""], ["iat": 1010], ["nbf": 1010], ["exp": true], ["iat": NSNull()]] as [[String: Any]] {
            XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(issuer.token(claims), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
        }
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(issuer.token(), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", expectedSubject: "other", now: issuer.now))
    }
    func testRejectsAlgorithmConfusionUnknownKidCriticalAndAmbiguousAudiences() throws {
        let issuer = try ChatGPTTestIssuer()
        for header in [["alg": "none"], ["alg": "HS256"], ["kid": "missing"], ["crit": ["unknown"]]] as [[String: Any]] {
            XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(issuer.token(header: header), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
        }
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(issuer.token(["aud": ["issued", "other"]]), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
        XCTAssertNoThrow(try ChatGPTIdentityValidator.validate(issuer.token(["aud": ["issued", "other"], "azp": "issued"]), jwks: issuer.jwks, clientID: "issued", nonce: "attempt", now: issuer.now))
    }
    func testMissingIdentityOrScopeCannotCreatePlanSession() throws {
        let issuer = try ChatGPTTestIssuer()
        for change in [["id_token": NSNull()], ["scope": NSNull()], ["token_type": "Other"], ["expires_in": 0], ["expires_in": true]] as [[String: Any]] { XCTAssertThrowsError(try issuer.session(change)) }
        let identityOnly = try issuer.session(["scope": "openid email"])
        XCTAssertTrue(identityOnly.hasValidatedIdentity); XCTAssertFalse(identityOnly.canUsePlan)
    }
    func testIssuedClientIsRequiredAndReturningClientCannotChange() throws {
        XCTAssertThrowsError(try ChatGPTPlanAuth.issuedClientID(callback: nil, selected: nil))
        XCTAssertThrowsError(try ChatGPTPlanAuth.issuedClientID(callback: "dynamic_agent_client", selected: nil))
        XCTAssertThrowsError(try ChatGPTPlanAuth.issuedClientID(callback: "other", selected: "issued"))
        XCTAssertEqual(try ChatGPTPlanAuth.issuedClientID(callback: nil, selected: "issued"), "issued")
        XCTAssertEqual(try ChatGPTPlanAuth.issuedClientID(callback: "issued", selected: nil), "issued")
    }
    func testRefreshRetainsVerifiedIdentityScopesAndRotatesTogether() throws {
        let issuer = try ChatGPTTestIssuer(); let original = try issuer.session()
        let response = Data(#"{"access_token":"new","refresh_token":"rotated","token_type":"Bearer","expires_in":3600}"#.utf8)
        let renewed = try ChatGPTPlanAuth.session(from: response, clientID: "issued", hostID: "host", previous: original, now: issuer.now)
        XCTAssertEqual(renewed.subject, original.subject); XCTAssertEqual(renewed.scopes, original.scopes)
        XCTAssertEqual(renewed.accessToken, "new"); XCTAssertEqual(renewed.refreshToken, "rotated"); XCTAssertTrue(renewed.canUsePlan)
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: response, clientID: "other", hostID: "host", previous: original))
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: response, clientID: "issued", hostID: "different", previous: original))
        let wrongID = try issuer.response(["id_token": issuer.token(["sub": "different"])])
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: wrongID, clientID: "issued", hostID: "host", previous: original, jwks: issuer.jwks, now: issuer.now))
        let reduced = try ChatGPTPlanAuth.session(from: issuer.response(["scope": "openid"]), clientID: "issued", hostID: "host", previous: original, jwks: issuer.jwks, now: issuer.now)
        XCTAssertFalse(reduced.canUsePlan)
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: issuer.response(["scope": NSNull()]), clientID: "issued", hostID: "host", previous: original, jwks: issuer.jwks, now: issuer.now))
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: Data(#"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#.utf8), clientID: "issued", hostID: "host", previous: original, now: issuer.now))
    }
    func testLegacySessionsDecodeButNeverSupplyPlanOrRefresh() throws {
        let legacy = ChatGPTPlanAuth.Session(clientID: "issued", hostID: "host", accessToken: "old", refreshToken: "old", expiresAt: .distantFuture, email: "old@example.invalid")
        let decoded = try JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: JSONEncoder().encode(legacy))
        XCTAssertFalse(decoded.hasValidatedIdentity); XCTAssertFalse(decoded.canUsePlan); XCTAssertNil(ChatGPTPlanAuth.refreshRequest(decoded))
        XCTAssertThrowsError(try ChatGPTPlanAuth.session(from: Data(#"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#.utf8), clientID: "issued", hostID: "host", previous: decoded))
    }
    func testReturningAuthorizationHintsRemainBoundToSelectedRegistration() throws {
        let issuer = try ChatGPTTestIssuer(); let saved = try issuer.session()
        let url = ChatGPTPlanAuth.authorizationURL(clientID: saved.clientID, hostID: saved.hostID, redirectURI: "http://127.0.0.1:54321/callback", state: "fresh-state", nonce: "fresh-nonce", codeChallenge: "challenge", previous: saved)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "id_token_hint" }?.value, saved.idToken)
        XCTAssertNil(items.first { $0.name == "agent_name_hint" }); XCTAssertEqual(items.first { $0.name == "nonce" }?.value, "fresh-nonce")
    }
}
