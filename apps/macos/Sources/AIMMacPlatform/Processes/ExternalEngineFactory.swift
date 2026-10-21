import AIMAgentKit
import AIMCore
import CryptoKit
import Foundation

public enum ExternalEngineFactory {
    /// Configuration alone registers a stopped engine. Launch is a later,
    /// explicit choice in the existing engine selector.
    public static func configured(directory: URL, secureStore: any SecureStoring,
        approvals: ToolApprovalBroker, financeResolver: ExternalFinanceResolver? = nil) throws -> StdioAgentEngine? {
        let v2 = directory.appendingPathComponent("adapter-v2.json")
        let file = FileManager.default.fileExists(atPath: v2.path) ? v2 : directory.appendingPathComponent("adapter-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let properties = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard properties.isSymbolicLink != true, properties.isRegularFile == true,
              (properties.fileSize ?? Int.max) <= 65_536 else {
            throw EngineError.invalidRuntime("The external adapter configuration file is unsafe.")
        }
        let configuration = try JSONDecoder().decode(ExternalEngineConfiguration.self, from: Data(contentsOf: file))
        guard configuration.version == (file.lastPathComponent == "adapter-v2.json" ? 2 : 1) else { throw EngineError.invalidRuntime("The external adapter configuration version is unsupported.") }
        guard configuration.enabled else { return nil }
        return StdioAgentEngine(configuration: configuration, secureStore: secureStore, approvals: approvals, financeResolver: financeResolver)
    }
}

public extension ExternalEngineFactory {
    /// Call only from the durable driver. UI proxies submit to its coordinator;
    /// they never register or launch this subprocess as a second execution.
    static func upstream(engineID: AgentEngineID, version: String, executable: URL,
        upstreamDirectory: URL, bridgeDirectory: URL, privateHome: URL,
        secureStore: any SecureStoring, approvals: ToolApprovalBroker,
        financeResolver: @escaping ExternalFinanceResolver,
        providerHandler: @escaping ExternalProviderHandler, toolHandler: ExternalToolHandler? = nil, toolSchemas: Data? = nil,
        activityHandler: ExternalActivityHandler? = nil) throws -> StdioAgentEngine {
        guard [.hermes, .openClaw].contains(engineID) else { throw EngineError.invalidRuntime("Unsupported upstream bridge identity.") }
        let script = bridgeDirectory.appendingPathComponent(engineID == .hermes ? "aim_hermes_bridge.py" : "aim_openclaw_bridge.mjs")
        let values = try script.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw EngineError.invalidRuntime("The installed runtime or AIM bridge is missing.") }
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        let names = engineID == .hermes ? ["aim_hermes_bridge.py"] : ["aim_openclaw_bridge.mjs", "aim_openclaw_preload.mjs", "aim_openclaw_plugin.mjs"]
        var bridgeDigest = SHA256()
        for name in names {
            let file = bridgeDirectory.appendingPathComponent(name)
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  (properties.fileSize ?? Int.max) <= 1_048_576 else { throw EngineError.invalidRuntime("The AIM bridge is unsafe or incomplete.") }
            bridgeDigest.update(data: Data(name.utf8)); bridgeDigest.update(data: try Data(contentsOf: file))
        }
        let bridgeRevision = bridgeDigest.finalize().map { String(format: "%02x", $0) }.joined()
        let configuration = ExternalEngineConfiguration(identity: "aim." + engineID.rawValue + ".bridge.v1",
            engineVersion: version + "+bridge-v1." + bridgeRevision, executable: executable, executableSHA256: digest,
            arguments: [script.path, "--upstream", upstreamDirectory.path, "--state", privateHome.path],
            environment: ["PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"],
            enabled: true, allowModelCalls: true, allowExternalEffects: false,
            isolationReceipt: "native-seatbelt-required", version: 2, financeProtocolVersion: 1)
        var reads = [executable.deletingLastPathComponent().deletingLastPathComponent(), executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent(), upstreamDirectory, bridgeDirectory, privateHome.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools")]
        if engineID == .openClaw { reads.append(upstreamDirectory.deletingLastPathComponent()) }
        let confinement = ExternalEngineConfinement(readRoots: reads,
            writeRoots: [privateHome], privateHome: privateHome)
        return StdioAgentEngine(configuration: configuration, secureStore: secureStore, approvals: approvals,
            financeResolver: financeResolver, providerHandler: providerHandler, confinement: confinement, toolHandler: toolHandler, toolSchemas: toolSchemas,
            activityHandler: activityHandler, engineID: engineID)
    }
}
