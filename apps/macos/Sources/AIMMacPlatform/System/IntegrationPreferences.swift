import Foundation

/// Settings read by the Agent's tools (computer use, browser, Git, worktrees), kept in
/// UserDefaults so the platform layer reads them without the app model.
public enum IntegrationPreferences {
    static let computerUseKey = "aim.computerUse.enabled"
    static let browserKey = "aim.browser.enabled"
    static let blockedSitesKey = "aim.browser.blockedSites"
    static let branchPrefixKey = "aim.git.branchPrefix"
    static let commitTemplateKey = "aim.git.commitTemplate"
    static let worktreeRootKey = "aim.worktrees.root"

    /// Whether the Agent may control apps (clicks, typing, focus). Reading windows stays available.
    public static var computerUseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: computerUseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: computerUseKey) }
    }

    /// Whether the Agent gets its browser tools.
    public static var browserEnabled: Bool {
        get { UserDefaults.standard.object(forKey: browserKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: browserKey) }
    }

    /// Sites the Agent never opens (a domain also blocks its subdomains).
    public static var blockedSites: [String] {
        get { UserDefaults.standard.stringArray(forKey: blockedSitesKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue.compactMap(normalizedSite))).sorted(), forKey: blockedSitesKey) }
    }

    /// "https://www.Example.com/path" or "example.com" → "example.com"; nil if not a host.
    public static func normalizedSite(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URLComponents(string: value)?.host, value.contains("://") { value = host }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        guard !value.isEmpty, value.contains("."), value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return value
    }

    public static func isBlocked(host: String, blocked: [String] = blockedSites) -> Bool {
        let host = host.lowercased()
        return blocked.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Prefix of the branches AIM creates (sub-agent worktrees and new worktrees).
    public static var branchPrefix: String {
        get {
            let value = UserDefaults.standard.string(forKey: branchPrefixKey) ?? "aim/"
            return validBranchPrefix(value) ? value : "aim/"
        }
        set { UserDefaults.standard.set(newValue, forKey: branchPrefixKey) }
    }

    public static func validBranchPrefix(_ value: String) -> Bool {
        value.count <= 40 && !value.hasPrefix("-") && !value.hasPrefix("/") && !value.contains("..")
            && value.allSatisfy { $0.isLetter || $0.isNumber || "/-_.".contains($0) }
    }

    /// Text placed in the commit message field when committing from AIM.
    public static var commitTemplate: String {
        get { UserDefaults.standard.string(forKey: commitTemplateKey) ?? "" }
        set { UserDefaults.standard.set(String(newValue.prefix(2_000)), forKey: commitTemplateKey) }
    }

    /// Folder for sub-agent worktrees (nil: AIM's own folder in Application Support).
    public static var worktreeRoot: String? {
        get { UserDefaults.standard.string(forKey: worktreeRootKey) }
        set { UserDefaults.standard.set(newValue, forKey: worktreeRootKey) }
    }
}
