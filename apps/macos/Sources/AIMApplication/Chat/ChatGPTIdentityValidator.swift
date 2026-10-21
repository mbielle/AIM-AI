import Foundation
import Security

/// Narrow OIDC verifier backed by Apple's maintained Security implementation. Only the
/// algorithm advertised by OpenAI discovery is accepted; token-provided URLs are ignored.
public enum ChatGPTIdentityValidator {
    public static let issuer = "https://auth.openai.com"
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    public struct Identity: Equatable, Sendable {
        public let issuer: String
        public let subject: String
        public let email: String?
    }

    public static func validate(_ token: String, jwks: Data, clientID: String, nonce: String?,
                                expectedSubject: String? = nil, now: Date = .now) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 65536,
              let headerData = decode(String(parts[0])), let body = decode(String(parts[1])),
              let signature = decode(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]] else { throw ChatGPTPlanAuth.AuthError.invalidIdentity }
        let matches = keys.filter { $0["kid"] as? String == kid }
        guard matches.count == 1, let key = matches.first,
              key["kty"] as? String == "RSA", key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              let n = (key["n"] as? String).flatMap(decode), n.count >= 256,
              let e = (key["e"] as? String).flatMap(decode), !e.isEmpty else { throw ChatGPTPlanAuth.AuthError.invalidIdentity }
        let der = sequence(integer(n) + integer(e))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              claims["iss"] as? String == issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              expectedSubject == nil || subject == expectedSubject,
              let exp = number(claims["exp"]), let iat = number(claims["iat"]),
              exp > now.timeIntervalSince1970 - 5, iat <= now.timeIntervalSince1970 + 5,
              exp > iat else { throw ChatGPTPlanAuth.AuthError.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count == 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID else { throw ChatGPTPlanAuth.AuthError.invalidIdentity }
        if let nbf = claims["nbf"] { guard let value = number(nbf), value <= now.timeIntervalSince1970 + 5 else { throw ChatGPTPlanAuth.AuthError.invalidIdentity } }
        if let nonce { guard !nonce.isEmpty, claims["nonce"] as? String == nonce else { throw ChatGPTPlanAuth.AuthError.invalidIdentity } }
        return Identity(issuer: issuer, subject: subject, email: claims["email"] as? String)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
    private static func tlv(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count
        var encoded = Data()
        repeat { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let prefix = bytes.count < 128 ? Data([UInt8(bytes.count)]) : Data([0x80 | UInt8(encoded.count)]) + encoded
        return Data([tag]) + prefix + bytes
    }
    private static func integer(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop { $0 == 0 })
        if bytes.first.map({ $0 & 128 != 0 }) == true { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }
    private static func sequence(_ bytes: Data) -> Data { tlv(0x30, bytes) }
}
