import Foundation

public struct AuthRedirectPolicy: Equatable, Sendable {
    public let canonicalScheme: String
    public let acceptedSchemes: Set<String>
    public let callbackHost: String

    public init(
        canonicalScheme: String = "aim",
        acceptedSchemes: Set<String> = ["aim", "aimai"],
        callbackHost: String = "auth-callback"
    ) {
        self.canonicalScheme = canonicalScheme
        self.acceptedSchemes = acceptedSchemes
        self.callbackHost = callbackHost
    }

    public var canonicalURL: URL? {
        var components = URLComponents()
        components.scheme = canonicalScheme
        components.host = callbackHost
        return components.url
    }

    public func accepts(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return acceptedSchemes.contains(scheme)
            && url.host?.lowercased() == callbackHost
    }
}
