import AIMAgentKit
import AIMApplication
import AIMCore
import CryptoKit
import Foundation

public struct UpstreamAgentInstallation: Sendable {
    public let engine: AgentEngineID
    public let version: String
    public let directory: URL
    public let executable: URL
    public let upstreamDirectory: URL
    public let bridgeDirectory: URL
    public var privateHome: URL { directory.appending(path: "home") }
    /// A newer vetted version ships with this app; the installed one keeps working until then.
    public var updateAvailable: Bool { UpstreamAgentCatalog.release(engine).map { $0.version != version } ?? false }
}

/// Only an explicit UI download prepares upstream dependencies. No shell installer,
/// user Python/Node, inherited credentials, or package lifecycle scripts are used.
public actor UpstreamAgentInstaller {
    public static let downloadable: [AgentEngineID] = [.openClaw, .hermes]
    private let root: URL
    private var operations: Set<AgentEngineID> = []
    private let runner = MacProcessRunner()
    public init(root: URL) { self.root = root }

    private struct Record: Codable {
        var schema = 1
        var engine: AgentEngineID
        var version: String
        var directoryName: String
        var executable: String
        var upstream: String
        var bridges: [String: String]
        var runtimeSHA256: String
        var archiveDigest: String
        var dependencyLockSHA256: String
        var installedAt: Date
    }

    public func installation(_ engine: AgentEngineID) throws -> UpstreamAgentInstallation? {
        guard Self.downloadable.contains(engine) else { return nil }
        let engineRoot = root.appending(path: engine.rawValue)
        let receipt = engineRoot.appending(path: "installed-v1.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
        try safeDirectory(root); try safeDirectory(engineRoot); try safeFile(receipt, maximumBytes: 65_536)
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: receipt))
        guard record.schema == 1, record.engine == engine,
              record.directoryName.hasPrefix("versions/"),
              UUID(uuidString: String(record.directoryName.dropFirst("versions/".count))) != nil,
              !record.version.isEmpty, !record.archiveDigest.isEmpty,
              record.upstream == (engine == .hermes ? "upstream" : "upstream/node_modules/openclaw") else {
            throw InstallerError.invalidReceipt
        }
        let directory = engineRoot.appending(path: record.directoryName)
        try safeDirectory(engineRoot.appending(path: "versions")); try safeDirectory(directory)
        try safeDirectory(directory.appending(path: "home")); try safeDirectory(directory.appending(path: "state"))
        let executable = try bounded(record.executable, inside: directory)
        let upstream = try bounded(record.upstream, inside: directory)
        let bridges = directory.appending(path: "bridge")
        try safeDirectory(upstream); try safeDirectory(bridges)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              try digest(executable) == record.runtimeSHA256,
              record.bridges.keys.sorted() == Self.bridgeNames(engine).sorted() else { throw InstallerError.invalidReceipt }
        for (name, hash) in record.bridges {
            let file = try bounded(name, inside: bridges)
            try safeFile(file, maximumBytes: 1_048_576)
            guard try digest(file) == hash else { throw InstallerError.invalidReceipt }
        }
        let lock = directory.appending(path: engine == .hermes ? "upstream/uv.lock" : "upstream/package-lock.json")
        try safeFile(lock, maximumBytes: 20_000_000)
        guard try digest(lock) == record.dependencyLockSHA256 else { throw InstallerError.invalidReceipt }
        // The upstream version/receipt stays immutable. AIM-owned shims follow
        // the running app bundle so a signed app update fixes existing installs
        // without downloading a runtime or rewriting its receipt.
        let activeBridges = try Self.activeBridgeDirectory(engine: engine, installed: bridges,
            resources: HostBundleResources.resourceURL)
        return UpstreamAgentInstallation(engine: engine, version: record.version, directory: directory,
            executable: executable, upstreamDirectory: upstream, bridgeDirectory: activeBridges)
    }

    static func activeBridgeDirectory(engine: AgentEngineID, installed: URL, resources: URL?) throws -> URL {
        guard let resources,
              FileManager.default.fileExists(atPath: resources.appending(path: "AgentBridges").path) else { return installed }
        let directory = resources.appending(path: "AgentBridges/" + engine.rawValue)
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw InstallerError.missingBridge }
        for name in bridgeNames(engine) {
            let file = directory.appending(path: name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_048_576 else { throw InstallerError.missingBridge }
        }
        return directory
    }

    public func install(_ engine: AgentEngineID) -> AsyncThrowingStream<RuntimeInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard Self.downloadable.contains(engine) else { throw InstallerError.unsupported }
                    guard operations.insert(engine).inserted else { throw RuntimeError.operationInProgress }
                    defer { operations.remove(engine) }
                    try RuntimePrivacyPolicy.requireNetwork()
                    continuation.yield(progress(engine, .preparing, 2, "Préparation isolée…"))
                    // Immutable final directory: moving a prepared venv would break
                    // its absolute interpreter/shebang paths. Switch only the receipt.
                    try createPrivateDirectory(root)
                    let engineRoot = root.appending(path: engine.rawValue)
                    try createPrivateDirectory(engineRoot)
                    let versions = engineRoot.appending(path: "versions")
                    try createPrivateDirectory(versions)
                    let name = "versions/" + UUID().uuidString
                    let directory = engineRoot.appending(path: name)
                    try createPrivateDirectory(directory)
                    for path in ["home", "home/tmp", "cache", "tools", "upstream", "bridge", "state"] {
                        try createPrivateDirectory(directory.appending(path: path))
                    }
                    // A cancelled/failed version never replaces the previous receipt.
                    guard let release = UpstreamAgentCatalog.release(engine) else { throw InstallerError.unsupported }
                    let source = Self.source(release)
                    let previous = (try? installation(engine)) ?? nil
                    continuation.yield(progress(engine, .downloading, 8, "Téléchargement de la version vérifiée…"))
                    let archive = try await download(source, directory: directory, name: engine == .hermes ? "upstream.zip" : "upstream.tgz")
                    continuation.yield(progress(engine, .verifying, 30, "Empreinte de l’archive vérifiée."))
                    let tools = directory.appending(path: "tools")
                    var executable: URL
                    var upstream = directory.appending(path: "upstream")
                    continuation.yield(progress(engine, .extracting, 35, "Préparation du moteur et de son runtime…"))
                    if engine == .hermes {
                        try await execute("/usr/bin/ditto", ["-x", "-k", archive.path, upstream.path], directory: directory)
                        let imported = upstream.appending(path: release.archiveFolder ?? "")
                        try safeDirectory(imported)
                        // Flatten before creating the venv, not afterwards.
                        let temporary = directory.appending(path: "source")
                        try FileManager.default.moveItem(at: imported, to: temporary)
                        try FileManager.default.removeItem(at: upstream)
                        try FileManager.default.moveItem(at: temporary, to: upstream)
                        let uvArchive = try await download(Self.uv(), directory: directory, name: "uv.tar.gz")
                        try await execute("/usr/bin/tar", ["-xzf", uvArchive.path, "-C", tools.path], directory: directory)
                        let uv = tools.appending(path: "uv-" + Self.architecture + "-apple-darwin/uv")
                        let pythonRoot = tools.appending(path: "python")
                        try createPrivateDirectory(pythonRoot)
                        let environment = ["UV_PYTHON_INSTALL_DIR": pythonRoot.path,
                            "UV_PROJECT_ENVIRONMENT": directory.appending(path: ".venv").path,
                            "UV_CACHE_DIR": directory.appending(path: "cache/uv").path,
                            "UV_NO_PROGRESS": "1", "PYTHONDONTWRITEBYTECODE": "1"]
                        continuation.yield(progress(engine, .validating, 55, "Installation des dépendances Python verrouillées…"))
                        try await execute(uv.path, ["sync", "--frozen", "--no-dev", "--python", release.python ?? "3.13", "--python-preference", "only-managed"],
                            directory: directory, workingDirectory: upstream, environment: environment, network: .installationAllowed)
                        executable = directory.appending(path: ".venv/bin/python")
                    } else {
                        let nodeArchive = try await download(Self.node(), directory: directory, name: "node.tar.gz")
                        try await execute("/usr/bin/tar", ["-xzf", nodeArchive.path, "-C", tools.path], directory: directory)
                        let nodeRoot = tools.appending(path: "node-v26.10.0-darwin-" + (Self.architecture == "aarch64" ? "arm64" : "x64"))
                        executable = nodeRoot.appending(path: "bin/node")
                        let npm = nodeRoot.appending(path: "lib/node_modules/npm/bin/npm-cli.js")
                        continuation.yield(progress(engine, .validating, 55, "Installation des dépendances Node sans scripts automatiques…"))
                        let npmEnvironment = ["PATH": nodeRoot.appending(path: "bin").path + ":/usr/bin:/bin", "npm_config_cache": directory.appending(path: "cache/npm").path]
                        // The vetted lockfile pins every transitive package by sha512; `npm ci` refuses
                        // anything else. Without one (a version not yet vetted), npm resolves them.
                        if let lock = HostBundleResources.resourceURL?.appending(path: "AgentBridges/openclaw/locks/\(release.version).package-lock.json"),
                           FileManager.default.fileExists(atPath: lock.path) {
                            try safeFile(lock, maximumBytes: 20_000_000)
                            try Data(#"{"dependencies":{"openclaw":"file:../upstream.tgz"}}"#.utf8).write(to: upstream.appending(path: "package.json"))
                            try FileManager.default.copyItem(at: lock, to: upstream.appending(path: "package-lock.json"))
                            try await execute(executable.path, [npm.path, "ci", "--prefix", upstream.path, "--ignore-scripts", "--no-audit", "--no-fund"],
                                directory: directory, workingDirectory: upstream, environment: npmEnvironment, network: .installationAllowed)
                            guard try digest(upstream.appending(path: "package-lock.json")) == digest(lock) else { throw InstallerError.invalidReceipt }
                        } else {
                            try await execute(executable.path, [npm.path, "install", "--prefix", upstream.path, "--ignore-scripts", "--no-audit", "--no-fund", archive.path],
                                directory: directory, workingDirectory: upstream, environment: npmEnvironment, network: .installationAllowed)
                        }
                    }
                    try Task.checkCancellation()
                    guard let resources = HostBundleResources.resourceURL else { throw InstallerError.missingBridge }
                    let sourceBridge = resources.appending(path: "AgentBridges/" + engine.rawValue)
                    var hashes: [String: String] = [:]
                    for name in Self.bridgeNames(engine) {
                        let original = sourceBridge.appending(path: name)
                        try safeFile(original, maximumBytes: 1_048_576)
                        let target = directory.appending(path: "bridge/" + name)
                        try FileManager.default.copyItem(at: original, to: target)
                        hashes[name] = try digest(target)
                    }
                    // Installation verification calls only the runtime version, no
                    // agent/model and no account credentials.
                    try await execute(executable.path, ["--version"], directory: directory)
                    if engine == .openClaw {
                        try await execute(executable.path, [upstream.appending(path: "node_modules/openclaw/openclaw.mjs").path, "--version"], directory: directory,
                            environment: ["OPENCLAW_STATE_DIR": directory.appending(path: "state").path, "OPENCLAW_NO_RESPAWN": "1"])
                        // A partly extracted dependency only fails when a run imports it: load the
                        // modules a run needs now (the 2026-10-05 install lacked SDK files).
                        let entry = upstream.appending(path: "node_modules/openclaw/openclaw.mjs").path
                        try await execute(executable.path, ["--input-type=module", "-e",
                            "import {createRequire} from 'node:module'; const r = createRequire(process.argv[1]); for (const m of ['@openclaw/ai', '@anthropic-ai/sdk', 'openai']) { try { await import(r.resolve(m)) } catch (e) { if (e.code !== 'MODULE_NOT_FOUND' || !String(e.message).includes(\"'\" + m + \"'\")) throw e } }",
                            entry], directory: directory, environment: ["OPENCLAW_NO_RESPAWN": "1"])
                    } else {
                        // Check installed imports without constructing AIAgent,
                        // reading a user profile, or contacting a model provider.
                        try await execute(executable.path, ["-c", "import sys; sys.path.insert(0, sys.argv[1]); from run_agent import AIAgent; assert callable(AIAgent)", upstream.path],
                            directory: directory, environment: ["PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"])
                    }
                    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw InstallerError.invalidReceipt }
                    let relative = String(executable.path.dropFirst(directory.path.count + 1))
                    let lock = directory.appending(path: engine == .hermes ? "upstream/uv.lock" : "upstream/package-lock.json")
                    let record = Record(engine: engine, version: release.version, directoryName: name,
                        executable: relative, upstream: engine == .hermes ? "upstream" : "upstream/node_modules/openclaw", bridges: hashes, runtimeSHA256: try digest(executable),
                        archiveDigest: source.digest, dependencyLockSHA256: try digest(lock), installedAt: .now)
                    continuation.yield(progress(engine, .activating, 95, "Enregistrement de l’installation…"))
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    let receipt = engineRoot.appending(path: "installed-v1.json")
                    try encoder.encode(record).write(to: receipt, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
                    _ = try installation(engine)
                    // Keep the new version and the one it replaces (a turn may still use it); older ones go.
                    pruneVersions(engine, keeping: [name, previous.map { "versions/" + $0.directory.lastPathComponent }].compactMap { $0 })
                    continuation.yield(progress(engine, .complete, 100, "Installé · version \(release.version)."))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Old version folders (up to 1.4 GB each) are removed once a newer one is active.
    private func pruneVersions(_ engine: AgentEngineID, keeping: [String]) {
        let versions = root.appending(path: engine.rawValue + "/versions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else { return }
        for entry in entries where !keeping.contains("versions/" + entry) && UUID(uuidString: entry) != nil {
            try? FileManager.default.removeItem(at: versions.appending(path: entry))
        }
    }

    /// At launch: version folders that are not the active one and were not touched for a day
    /// (failed or replaced installs) are removed.
    public func cleanUp(_ engine: AgentEngineID) {
        guard !operations.contains(engine), let active = (try? installation(engine)) ?? nil else { return }
        let versions = root.appending(path: engine.rawValue + "/versions")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else { return }
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for entry in entries where entry != active.directory.lastPathComponent && UUID(uuidString: entry) != nil {
            let folder = versions.appending(path: entry)
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < dayAgo { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// Removes an agent entirely (its versions, private home and receipt).
    public func uninstall(_ engine: AgentEngineID) throws {
        guard Self.downloadable.contains(engine), !operations.contains(engine) else { throw RuntimeError.operationInProgress }
        let engineRoot = root.appending(path: engine.rawValue)
        guard FileManager.default.fileExists(atPath: engineRoot.path) else { return }
        try safeDirectory(engineRoot)
        try FileManager.default.removeItem(at: engineRoot.appending(path: "installed-v1.json"))
        try FileManager.default.removeItem(at: engineRoot)
    }

    private func execute(_ executable: String, _ arguments: [String], directory: URL, workingDirectory: URL? = nil,
        environment: [String: String] = [:], network: OSProcessNetworkPolicy = .deny) async throws {
        try Task.checkCancellation()
        let command = ProcessCommand(executable: URL(fileURLWithPath: executable), arguments: arguments,
            workingDirectory: workingDirectory ?? directory, environment: environment, timeout: .seconds(900), inheritsEnvironment: false)
        let confined = try OSProcessConfinement.prepare(command, readRoots: [directory], writeRoots: [directory],
            privateHome: directory.appending(path: "home"), network: network)
        let output = try await runner.runConfined(confined)
        guard output.exitCode == 0 else { throw InstallerError.preparationFailed(output.exitCode, String(output.stderr.suffix(1500))) }
    }

    private struct Download: Sendable { var url: String; var digest: String; var sha512 = false; var maximumBytes: Int64 = 250_000_000 }
    private func download(_ source: Download, directory: URL, name: String) async throws -> URL {
        let url = URL(string: source.url)!
        try RuntimePrivacyPolicy.requireEndpoint(url)
        let (temporary, response) = try await RuntimeManagedNetworkSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let allowed = Set(["codeload.github.com", "github.com", "release-assets.githubusercontent.com", "nodejs.org", "registry.npmjs.org"])
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https",
              allowed.contains(response.url?.host ?? ""), response.expectedContentLength <= source.maximumBytes else { throw RuntimeError.downloadFailed }
        try safeFile(temporary, maximumBytes: source.maximumBytes)
        let actual = try digest(temporary, sha512: source.sha512)
        guard actual == source.digest else { throw RuntimeError.checksumMismatch(expected: source.digest, actual: actual) }
        try Task.checkCancellation()
        let destination = directory.appending(path: name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    private func digest(_ file: URL, sha512: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var small = SHA256(), large = SHA512()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            if sha512 { large.update(data: bytes) } else { small.update(data: bytes) }
        }
        return sha512 ? Data(large.finalize()).base64EncodedString() : small.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func bounded(_ path: String, inside directory: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw InstallerError.invalidReceipt }
        let value = directory.appending(path: path)
        guard value.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw InstallerError.invalidReceipt }
        return value
    }
    private func safeDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw InstallerError.invalidReceipt }
    }
    private func createPrivateDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try safeDirectory(directory); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    private func safeFile(_ file: URL, maximumBytes: Int64) throws {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, Int64(values.fileSize ?? Int.max) <= maximumBytes else { throw InstallerError.invalidReceipt }
    }
    private func progress(_ engine: AgentEngineID, _ phase: RuntimeInstallPhase, _ percent: Int, _ message: String) -> RuntimeInstallProgress {
        RuntimeInstallProgress(engine: engine, phase: phase, percent: percent, message: message)
    }
    public static func version(_ engine: AgentEngineID) -> String { UpstreamAgentCatalog.release(engine)?.version ?? "" }
    private static func bridgeNames(_ engine: AgentEngineID) -> [String] {
        engine == .hermes ? ["aim_hermes_bridge.py"] : ["aim_openclaw_bridge.mjs", "aim_openclaw_preload.mjs", "aim_openclaw_plugin.mjs"]
    }
    #if arch(arm64)
    private static let architecture = "aarch64"
    #else
    private static let architecture = "x86_64"
    #endif
    private static func source(_ release: UpstreamAgentRelease) -> Download {
        Download(url: release.url, digest: release.digest, sha512: release.sha512)
    }
    private static func uv() -> Download {
        Download(url: "https://github.com/astral-sh/uv/releases/download/0.12.23/uv-" + architecture + "-apple-darwin.tar.gz",
            digest: architecture == "aarch64" ? "50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544" : "960da44cb4b73685206ddd250b19e0a117fa41095710c1038f081f5cb613efb4")
    }
    private static func node() -> Download {
        Download(url: "https://nodejs.org/dist/v26.10.0/node-v26.10.0-darwin-" + (architecture == "aarch64" ? "arm64" : "x64") + ".tar.gz",
            digest: architecture == "aarch64" ? "751fdf7439f115d87ee2a8f3f18c065b6151852068e3e666ac60ac2996f75ac9" : "ebbe9ab9b58ad6bb54390d6e2c862c1afa7d4475fb7e8ae8146acde211bf70df")
    }
}

private enum InstallerError: LocalizedError {
    case unsupported, invalidReceipt, missingBridge, preparationFailed(Int32, String)
    var errorDescription: String? {
        switch self {
        case .unsupported: "Cet agent ne possède pas de téléchargement AIM."
        case .invalidReceipt: "L’installation de cet agent est absente, modifiée ou incompatible. Réinstaller pour continuer."
        case .missingBridge: "Le bridge AIM de cet agent manque dans l’application."
        case let .preparationFailed(code, detail): "La préparation isolée de l’agent a échoué (\(code)). \(detail)"
        }
    }
}
