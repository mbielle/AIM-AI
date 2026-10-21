import AIMCore
import Foundation

/// How AIM's Playwright bridge reaches a browser.
public enum AgentBrowserMode: String, Codable, CaseIterable, Sendable {
    /// The person's Chrome through the official Playwright extension (logged-in tabs they share).
    case extensionConnected = "extension"
    /// A visible Chrome with an in-memory profile, launched for this run only.
    case isolated
}

public struct AgentBrowserConfiguration: Sendable, Equatable {
    public var mode: AgentBrowserMode
    public var extensionToken: String?
    /// Private directory for session records (isolated mode), kept for review.
    public var outputDirectory: URL?
    /// The selected workspace, which bounds Playwright's own file access.
    public var workspace: URL?
    /// Isolated only: no visible window (used by unattended qualification).
    public var headless: Bool

    public init(mode: AgentBrowserMode = .extensionConnected, extensionToken: String? = nil,
                outputDirectory: URL? = nil, workspace: URL? = nil, headless: Bool = false) {
        self.mode = mode
        self.extensionToken = extensionToken
        self.outputDirectory = outputDirectory
        self.workspace = workspace
        self.headless = headless
    }

    /// Page-registered WebMCP tools are never collected: a web page must not
    /// be able to add tools to an agent run.
    var serverArguments: [String] {
        switch mode {
        case .extensionConnected:
            return ["--extension", "--no-webmcp"]
        case .isolated:
            var arguments = ["--browser", "chrome", "--isolated", "--no-webmcp", "--console-level", "info"]
            if headless { arguments.append("--headless") }
            if let outputDirectory { arguments += ["--output-dir", outputDirectory.path, "--save-session"] }
            return arguments
        }
    }
}

/// Persisted browser choice and the extension token (Keychain only).
public enum AgentBrowserPreferences {
    static let modeKey = "aim.browser.mode"
    static let tokenService = AIMInstallationContext.keychainService("com.aimai.macos.browser")
    static let tokenAccount = "playwright-extension-token"

    public static var mode: AgentBrowserMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(AgentBrowserMode.init(rawValue:)) ?? .extensionConnected }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    public static var hasExtensionToken: Bool { (try? readToken()) != nil }

    public static func saveExtensionToken(_ token: String) throws {
        guard let trimmed = normalizedToken(token), trimmed.utf8.count <= 4_096, !trimmed.contains("\0") else { throw AgentBrowserPreferenceError.invalidToken }
        try KeychainSecureStore(service: tokenService).store(Data(trimmed.utf8), forKey: tokenAccount)
    }

    public static func removeExtensionToken() throws {
        try KeychainSecureStore(service: tokenService).removeData(forKey: tokenAccount)
    }

    static func readToken() throws -> String? {
        guard let data = try KeychainSecureStore(service: tokenService).readData(forKey: tokenAccount),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return normalizedToken(raw)
    }

    /// Accepts what people paste from the extension page: the bare token, or the
    /// whole `PLAYWRIGHT_MCP_EXTENSION_TOKEN=…` line (optionally with export/quotes).
    static func normalizedToken(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("export ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if let range = value.range(of: "PLAYWRIGHT_MCP_EXTENSION_TOKEN") {
            value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("=") || value.hasPrefix(":") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        while let first = value.first, "\"'`".contains(first) { value.removeFirst() }
        while let last = value.last, "\"'`,;".contains(last) { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains(where: \.isWhitespace) ? nil : value
    }

    /// Token shape for diagnostics: never the value itself.
    public static func tokenShape() -> [String: Any] {
        guard let data = try? KeychainSecureStore(service: tokenService).readData(forKey: tokenAccount),
              let raw = String(data: data, encoding: .utf8) else { return ["stored": false] }
        let normalized = normalizedToken(raw)
        return ["stored": true, "raw_length": raw.count, "normalized_length": normalized?.count ?? 0,
                "had_variable_name": raw.contains("PLAYWRIGHT_MCP_EXTENSION_TOKEN"),
                "had_quotes_or_spaces": raw.contains("\"") || raw.contains("'") || raw.contains(" ") || raw.contains("\n")]
    }

    /// Configuration for one run. An isolated session's private record
    /// directory is created only when the browser is actually started.
    public static func configuration(workspace: String?) -> AgentBrowserConfiguration {
        let mode = self.mode
        var configuration = AgentBrowserConfiguration(mode: mode,
            workspace: workspace.map { URL(fileURLWithPath: $0, isDirectory: true) })
        if mode == .extensionConnected { configuration.extensionToken = try? readToken() }
        return configuration
    }

    /// Private session record directory; only the ten most recent are kept.
    static func sessionDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let root = support.appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/BrowserSessions", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let existing = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for old in existing.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) {
                try? FileManager.default.removeItem(at: old)
            }
            return directory
        } catch {
            return nil
        }
    }
}

public enum AgentBrowserPreferenceError: LocalizedError {
    case invalidToken
    public var errorDescription: String? { "The extension token is empty or invalid." }
}
