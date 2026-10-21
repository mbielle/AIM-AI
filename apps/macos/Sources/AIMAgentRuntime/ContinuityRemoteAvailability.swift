import AIMCore
import Foundation

/// An operator records qualification only after the native Mac/iPhone acceptance
/// scenario. Experimental availability is a separate opt-in and is never proof.
package struct ContinuityRemoteAvailability: Codable, Sendable {
    package struct Qualification: Codable, Sendable {
        package let contractVersion: Int
        package let applicationVersion: String
        package let applicationBuild: String
        package let runtimeIdentity: String
        package let evidence: String
        package let qualifiedAt: Date
    }
    package let version: Int
    package let experimentalOptIn: Bool
    package let qualification: Qualification?
    package static let defaultsKey = "AIMRemoteContinuityAvailabilityV1"
    package static func current() -> Self {
        AIMInstallationContext.sharedPreferences.synchronize()
        guard let data = AIMInstallationContext.sharedPreferences.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else {
            return Self(version: 1, experimentalOptIn: false, qualification: nil)
        }
        return value
    }
    package static func setExperimentalOptIn(_ enabled: Bool) throws {
        let old = current()
        let value = Self(version: 1, experimentalOptIn: enabled, qualification: old.qualification)
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.set(try JSONEncoder().encode(value), forKey: defaultsKey); defaults.synchronize()
    }
    package var isQualified: Bool {
        guard version == 1, let proof = qualification, proof.contractVersion == 1,
              proof.runtimeIdentity == Bundle.main.bundleIdentifier,
              proof.applicationVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              proof.applicationBuild == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !proof.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proof.qualifiedAt <= Date() else { return false }
        return true
    }
    package var features: [String: Bool] {
        [RemoteCapabilities.Feature.continuity: isQualified,
         RemoteCapabilities.Feature.continuityAvailable: true,
         RemoteCapabilities.Feature.experimentalContinuity: version == 1 && experimentalOptIn && !isQualified]
    }
}
