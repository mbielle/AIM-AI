import CryptoKit
import Foundation

public struct CuaDriverDiagnosticReport: Sendable {
    public let version: String
    public let hostIdentityVerified: Bool
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    public let toolNames: [String]
    public let coreSchemaSHA256: String
    /// Permissions and the read-only window contract are prerequisites only.
    /// No background gesture is exposed until it passes signed-bundle tests.
    public var backgroundPrerequisitesAvailable: Bool {
        hostIdentityVerified && accessibilityGranted && screenRecordingGranted &&
            toolNames.contains("get_window_state")
    }
}

public enum CuaDriverDiagnosticError: LocalizedError, Sendable {
    case invalidHostIdentity, invalidPermissions, missingTools, incompatibleSchema

    public var errorDescription: String? {
        switch self {
        case .invalidHostIdentity: "The CUA Driver did not prove that AIM owns its macOS responsibility chain. Its tools remain disabled."
        case .invalidPermissions: "The CUA Driver returned an invalid or non-host permission report. Its tools remain disabled."
        case .missingTools: "The CUA Driver does not expose the expected diagnostic and window tools. Its tools remain disabled."
        case .incompatibleSchema: "The CUA Driver tool schemas differ from the qualified 0.28.2 contract. Its tools remain disabled."
        }
    }
}

/// Read-only qualification of the exact bundled helper. A successful probe
/// records capabilities, never grants a model access or asks macOS for access.
public actor CuaDriverDiagnostics {
    private static let qualifiedCoreSchemaSHA256 = "1845fc23a1a0fff983abe03c274c14fd738996a82ea366e38845b7b220af2496"
    public nonisolated static var isBundled: Bool {
        guard let resourceURL = HostBundleResources.resourceURL else { return false }
        return FileManager.default.isExecutableFile(atPath:
            resourceURL.appendingPathComponent("CuaDriver/cua-driver").path)
    }
    private let host: EmbeddedCuaDriverHost
    private let executable: URL
    private let bundleID: String
    private var activeClient: PlaywrightMCPClient?

    public init(executable: URL? = nil, bundleID: String? = nil,
                supervisor: ProcessSupervisor = .shared) {
        let executable = executable ?? HostBundleResources.resourceURL!
            .appendingPathComponent("CuaDriver/cua-driver")
        let bundleID = bundleID ?? Bundle.main.bundleIdentifier ?? ""
        self.executable = executable
        self.bundleID = bundleID
        self.host = EmbeddedCuaDriverHost(executable: executable, hostBundleID: bundleID,
            supervisor: supervisor)
    }

    public func probe() async throws -> CuaDriverDiagnosticReport {
        let connection = try await host.start()
        let client: PlaywrightMCPClient
        do {
            client = try PlaywrightMCPClient(cuaDriver: executable,
                socketPath: connection.socketPath, hostBundleID: bundleID)
            activeClient = client
        } catch {
            await host.stop()
            throw error
        }
        do {
            try await client.initialize()
            let tools = try await client.listTools()
            let coreTools = ["check_permissions", "get_window_state", "health_report"]
            guard tools.isSuperset(of: coreTools) else {
                throw CuaDriverDiagnosticError.missingTools
            }
            var schemaData = Data()
            for name in coreTools {
                guard let schema = client.inputSchema(for: name) else {
                    throw CuaDriverDiagnosticError.missingTools
                }
                schemaData.append(contentsOf: name.utf8)
                schemaData.append(0)
                schemaData.append(schema)
                schemaData.append(0)
            }
            let schemaHash = SHA256.hash(data: schemaData)
                .map { String(format: "%02x", $0) }.joined()
            guard schemaHash == Self.qualifiedCoreSchemaSHA256 else {
                throw CuaDriverDiagnosticError.incompatibleSchema
            }
            let health = try await client.callRawTool("health_report", arguments: [
                "include": ["bundle_identity"]])
            guard let checks = (health["structuredContent"] as? [String: Any])?["checks"] as? [[String: Any]],
                  let identity = checks.first(where: { $0["name"] as? String == "bundle_identity" }),
                  identity["status"] as? String == "pass",
                  let identityData = identity["data"] as? [String: Any],
                  identityData["bundle_identifier"] as? String == bundleID,
                  identityData["identity_source"] as? String == "parent_application",
                  identityData["parent_process_id"] as? Int == Int(getpid()) else {
                throw CuaDriverDiagnosticError.invalidHostIdentity
            }
            let permissions = try await client.callRawTool("check_permissions", arguments: [:])
            guard let structured = permissions["structuredContent"] as? [String: Any],
                  let source = structured["source"] as? [String: Any],
                  source["attribution"] as? String == "host",
                  source["host_bundle_id"] as? String == bundleID,
                  let accessibility = structured["accessibility"] as? Bool,
                  let recording = structured["screen_recording"] as? Bool else {
                throw CuaDriverDiagnosticError.invalidPermissions
            }
            let report = CuaDriverDiagnosticReport(version: connection.version,
                hostIdentityVerified: true, accessibilityGranted: accessibility,
                screenRecordingGranted: recording, toolNames: tools.sorted(),
                coreSchemaSHA256: schemaHash)
            await stop()
            return report
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        activeClient?.stop()
        activeClient = nil
        await host.stop()
    }
}
