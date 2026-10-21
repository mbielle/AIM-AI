import AIMCore
import AIMApplication
import CryptoKit
import Darwin
import Foundation
import Security

/// Identifies what a CUA qualification applies to on this Mac. The adapter
/// contract version changes whenever AIM's interpretation of driver results
/// or its argument forms change, invalidating earlier qualifications.
public enum CuaRuntimeIdentity {
    public static let adapterContract = "aim-cua-adapter-2026-10-02"
    public static var currentAdapterContract: String {
        if Bundle.main.bundleIdentifier == AIMInstallationContext.helperIdentifier {
            return adapterContract + ":host=" + AIMInstallationContext.helperIdentifier
        }
        return AIMInstallationContext.isQualification ? adapterContract + ":app=" + AIMInstallationContext.applicationIdentifier : adapterContract
    }
    static let contractTools = ["get_window_state", "list_windows", "click", "type_text", "set_value",
                                "scroll", "press_key"]

    private static let cache = DriverHashCache()

    public static var bundledDriver: URL? {
        guard let url = HostBundleResources.resourceURL?.appendingPathComponent("CuaDriver/cua-driver"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The helper's code identity is computed once per process, off the main thread,
    /// and only for a validly signed binary.
    public static func currentKey() async -> CuaQualificationKey? {
        guard let driver = bundledDriver, let build = osBuild() else { return nil }
        guard let hash = await cache.hash(of: driver) else { return nil }
        return CuaQualificationKey(driverVersion: EmbeddedCuaDriverHost.qualifiedVersion,
            driverSHA256: hash, osBuild: build, adapterContract: currentAdapterContract)
    }

    /// Adopts the signed bundle's release manifest for this Mac and this process (app, Test bundle
    /// or permanent host). Returns the number of capabilities adopted.
    public static func adoptReleaseManifest(into repository: SQLiteCuaQualificationRepository) async -> Int {
        let url = Bundle.main.url(forResource: "CuaQualificationManifest", withExtension: "json")
            ?? HostBundleResources.resourceURL?.appendingPathComponent("CuaQualificationManifest.json")
        guard let url, let data = try? Data(contentsOf: url),
              let manifest = try? CuaReleaseManifest.decode(data),
              let key = await currentKey() else { return 0 }
        return (try? await repository.adopt(manifest.adoptionRecords(for: key))) ?? 0
    }

    static func schemaDigest(_ client: PlaywrightMCPClient) -> String? {
        var data = Data()
        for name in contractTools {
            guard let schema = client.inputSchema(for: name) else { return nil }
            data.append(contentsOf: name.utf8)
            data.append(0)
            data.append(schema)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The signed helper's cdhash: it covers every code page, the identifier,
/// team, flags and entitlements, but not the signing time, so it is stable
/// across rebuilds of the same pinned binary and changes with any of those.
private actor DriverHashCache {
    private var hashes: [String: String] = [:]

    func hash(of url: URL) async -> String? {
        if let cached = hashes[url.path] { return cached }
        let computed = await Task.detached(priority: .utility) { () -> String? in
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
            else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
            return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
        }.value
        if let computed { hashes[url.path] = computed }
        return computed
    }
}
