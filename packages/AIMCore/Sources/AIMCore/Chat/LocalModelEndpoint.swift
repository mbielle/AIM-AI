import Foundation

/// Where AIM reaches the local model server (OpenAI-compatible `/v1`).
/// Defaults to oMLX's port; LM Studio (1234) and Ollama (11434) are detected too.
public enum LocalModelEndpoint {
    static let key = "AIMLocalModelBaseURL"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8000/v1")!

    public static var baseURL: URL {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), let url = URL(string: raw), isAllowed(url) else {
                return defaultBaseURL
            }
            return url
        }
        set { UserDefaults.standard.set(isAllowed(newValue) ? newValue.absoluteString : nil, forKey: key) }
    }

    /// Local means this Mac (or an explicit HTTPS server the person configured).
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), url.user == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    public static func url(_ path: String, base: URL = baseURL) -> URL {
        base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
