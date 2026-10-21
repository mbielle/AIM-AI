import Foundation
import CryptoKit

public struct OpenRouterPKCE: Sendable {
    private let createdAt: Date
    public let verifier: String
    public let callbackURL: URL
    public init(callbackURL: URL, now: Date = .now) throws {
        guard callbackURL.scheme == "https", callbackURL.host != nil, callbackURL.user == nil,
              callbackURL.password == nil, callbackURL.query == nil, callbackURL.fragment == nil else { throw ChatServiceError.invalidResponse }
        createdAt = now
        self.callbackURL = callbackURL
        verifier = try SecureNonceGenerator().generate(length: 64)
    }
    public var authorizationURL: URL {
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        url.queryItems = [.init(name: "callback_url", value: callbackURL.absoluteString), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        return url.url!
    }
    public func exchangeRequest(callback: URL, now: Date = .now) throws -> URLRequest {
        guard now >= createdAt, now.timeIntervalSince(createdAt) <= 300 else { throw ChatServiceError.invalidResponse }
        guard callback.scheme == callbackURL.scheme, callback.host == callbackURL.host, callback.port == callbackURL.port,
              callback.path == callbackURL.path, callback.user == nil, callback.password == nil, callback.fragment == nil,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "code" }).count == 1, let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096, !query.contains(where: { $0.name == "error" }) else { throw ChatServiceError.invalidResponse }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        return request
    }
}
