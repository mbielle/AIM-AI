#if DEBUG
import CryptoKit
import Foundation

/// Explicit debug qualification only. Merely inheriting an environment variable
/// cannot activate this path in an official app or an existing test installation.
public struct AIMQAContext: Sendable {
    public let runID: String
    public let directory: URL
    public let invitation: String?
    public let expectedCatalog: String?
    public let injectCatalogMismatch: Bool
    public var marker: String { "AIM-QA-" + runID }

    public static let current: Self? = {
        let env = ProcessInfo.processInfo.environment
        guard let run = env["AIM_QA_RUN_ID"] else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let allowed = bundle.hasPrefix("com.aimai.ios.qa.") ||
            bundle == "com.aimai.macos.qualification." + run
        guard allowed, run.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            preconditionFailure("QA requires a fresh isolated debug qualification bundle")
        }
        let directory: URL
        #if os(macOS)
        guard let path = env["AIM_QA_DIRECTORY"], path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else {
            preconditionFailure("QA output directory must already exist")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        #else
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIM-QA", isDirectory: true).appendingPathComponent(run, isDirectory: true)
        #endif
        return .init(runID: run, directory: directory, invitation: env["AIM_QA_INVITE"],
            expectedCatalog: env["AIM_QA_EXPECTED_CATALOG"], injectCatalogMismatch: env["AIM_QA_FAULT"] == "catalog-mismatch")
    }()

    public func store(_ role: String) throws -> AIMQAFileStore {
        try AIMQAFileStore(directory: directory.appendingPathComponent(role + "-secrets", isDirectory: true))
    }

    public static func catalogDigest(_ models: [RemoteModelAnnouncement]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sorted = models.sorted { ($0.provider + ":" + $0.id) < ($1.provider + ":" + $1.id) }
        return SHA256.hash(data: try encoder.encode(sorted)).map { String(format: "%02x", $0) }.joined()
    }

    public func receipt(_ values: [String: String], name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var values = values
        values["run_id"] = runID
        values["physical_devices_qualified"] = "false"
        values["real_inference_qualified"] = "false"
        let path = directory.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
#endif
