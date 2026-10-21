import AIMCore
import Foundation

/// Helper resources stay in the containing AIM bundle, while TCC identity stays the helper's.
public enum HostBundleResources {
    public static var applicationBundle: Bundle {
        guard Bundle.main.bundleIdentifier == AIMInstallationContext.helperIdentifier else { return .main }
        let outer = (0..<4).reduce(Bundle.main.bundleURL) { url, _ in url.deletingLastPathComponent() }
        guard let bundle = Bundle(url: outer), bundle.bundleIdentifier == AIMInstallationContext.applicationIdentifier else { return .main }
        return bundle
    }
    public static var resourceURL: URL? { applicationBundle.resourceURL }
    /// A qualification host must remain distinguishable from the user's Mac
    /// and the simulated Remote fixture without changing its pairing identity.
    public static var remoteMachineName: String {
        AIMInstallationContext.isQualification ? "AIM Continuité — TEST NATIF" : (Host.current().localizedName ?? "Mac")
    }
}
