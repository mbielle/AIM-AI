import Foundation

/// A signed qualification bundle owns a separate installation. Production
/// identifiers remain unchanged; malformed qualification metadata fails closed.
public enum AIMInstallationContext {
    private static let production = "com.aimai.macos"
    private static let namespace: String = {
        #if DEBUG
        // Test runners must never read/write the installed application's
        // preferences, privacy barrier or data directory. Release apps cannot
        // opt into this override, even if the environment is inherited.
        let executable = ProcessInfo.processInfo.arguments.first ?? ""
        if executable.contains(".xctest/") || Bundle.main.bundleURL.pathExtension == "xctest" {
            let value = ProcessInfo.processInfo.environment["AIM_TEST_INSTALLATION_ID"]
                ?? UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            guard value.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
                preconditionFailure("Invalid isolated test installation identifier")
            }
            return "com.aimai.macos.qualification." + value
        }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AIMQualificationNamespace") else {
            guard Bundle.main.bundleIdentifier?.hasPrefix(production + ".qualification.") != true else {
                preconditionFailure("Missing AIM qualification installation metadata")
            }
            return production
        }
        guard let value = value as? String,
              value.range(of: "^com\\.aimai\\.macos\\.qualification\\.[0-9a-f]{32}$", options: .regularExpression) != nil,
              Bundle.main.bundleIdentifier == value || Bundle.main.bundleIdentifier == value + ".agenthost" else {
            preconditionFailure("Invalid AIM qualification installation metadata")
        }
        return value
    }()
    public static var isQualification: Bool { namespace != production }
    public static var applicationSupportNamespace: String { namespace }
    public static var preferencesSuite: String { namespace }
    /// Foundation rejects the current bundle identifier as a suite name.
    /// The UI uses its standard domain; the helper opens that same domain.
    public static var sharedPreferences: UserDefaults {
        if Bundle.main.bundleIdentifier == namespace { return .standard }
        guard let defaults = UserDefaults(suiteName: namespace) else {
            preconditionFailure("AIM shared preferences domain is unavailable")
        }
        return defaults
    }
    public static var applicationIdentifier: String { namespace }
    public static var legacyDirectoryName: String { isQualification ? "AIM Qualification-" + namespace : "AIM AI" }
    public static var helperIdentifier: String { namespace + ".agenthost" }
    public static func keychainService(_ productionService: String) -> String {
        guard isQualification else { return productionService }
        guard productionService.hasPrefix(production + ".") else {
            preconditionFailure("Unexpected qualification Keychain service")
        }
        return namespace + String(productionService.dropFirst(production.count))
    }
}
