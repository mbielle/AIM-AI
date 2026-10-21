import Foundation

public enum ConfigurationError: Error, Equatable, Sendable {
    case missingProjectURL
    case invalidProjectURL
    case missingPublicAPIKey
    case privilegedKeyForbidden
    case invalidPublicAPIKey
}

public struct AppConfiguration: Equatable, Sendable {
    public let projectURL: URL
    public let publicAPIKey: String

    public init(projectURLString: String, publicAPIKey: String) throws {
        let trimmedURL = projectURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = publicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            throw ConfigurationError.missingProjectURL
        }
        guard
            let components = URLComponents(string: trimmedURL),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            components.port.map({ (1...65_535).contains($0) }) ?? true,
            let projectURL = components.url
        else {
            throw ConfigurationError.invalidProjectURL
        }
        guard !trimmedKey.isEmpty else {
            throw ConfigurationError.missingPublicAPIKey
        }
        try Self.validatePublicKey(trimmedKey)

        self.projectURL = projectURL
        self.publicAPIKey = trimmedKey
    }

    private static func validatePublicKey(_ key: String) throws {
        if key.hasPrefix("sbp_") || key.hasPrefix("sb_secret_") {
            throw ConfigurationError.privilegedKeyForbidden
        }

        if key.hasPrefix("sb_publishable_") {
            return
        }

        guard let role = legacyJWTRole(in: key) else {
            throw ConfigurationError.invalidPublicAPIKey
        }
        guard role != "service_role" else {
            throw ConfigurationError.privilegedKeyForbidden
        }
        guard role == "anon" else {
            throw ConfigurationError.invalidPublicAPIKey
        }
    }

    private static func legacyJWTRole(in key: String) -> String? {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))

        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["role"] as? String
    }
}
