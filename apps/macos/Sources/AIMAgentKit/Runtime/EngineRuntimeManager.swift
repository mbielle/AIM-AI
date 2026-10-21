import AIMCore
import AIMApplication
import CryptoKit
import Foundation

public enum RuntimeArchiveFormat: String, Codable, Sendable {
    case zip
    case tarGzip
    case rawExecutable
}

public struct RuntimeManifest: Codable, Sendable {
    public var engine: AgentEngineID
    public var version: String
    public var archiveURL: URL
    public var sha256: String
    public var archiveFormat: RuntimeArchiveFormat
    public var executableRelativePath: String
    public var allowedHosts: Set<String>
    public var adapterProtocolVersion: Int?
    public var adapterIdentity: String?

    public init(
        engine: AgentEngineID,
        version: String,
        archiveURL: URL,
        sha256: String,
        archiveFormat: RuntimeArchiveFormat,
        executableRelativePath: String,
        allowedHosts: Set<String>,
        adapterProtocolVersion: Int? = nil, adapterIdentity: String? = nil
    ) {
        self.engine = engine
        self.version = version
        self.archiveURL = archiveURL
        self.sha256 = sha256.lowercased()
        self.archiveFormat = archiveFormat
        self.executableRelativePath = executableRelativePath
        self.allowedHosts = allowedHosts
        self.adapterProtocolVersion = adapterProtocolVersion; self.adapterIdentity = adapterIdentity
    }
}

public struct RuntimeInstallationRecord: Codable, Sendable {
    public var version: Int = 1
    public var manifest: RuntimeManifest
    public var executableSHA256: String
    public var installedAt: Date
}

public enum RuntimeInstallPhase: String, Codable, Sendable {
    case preparing
    case downloading
    case verifying
    case extracting
    case validating
    case activating
    case complete
}

public struct RuntimeInstallProgress: Sendable, Equatable {
    public var engine: AgentEngineID
    public var phase: RuntimeInstallPhase
    public var percent: Int
    public var message: String
    public init(engine: AgentEngineID, phase: RuntimeInstallPhase, percent: Int, message: String) {
        self.engine = engine; self.phase = phase; self.percent = percent; self.message = message
    }
}

public protocol RuntimeArchiveExtracting: Sendable {
    func extract(archive: URL, format: RuntimeArchiveFormat, destination: URL) async throws
}

public actor EngineRuntimeManager {
    private let root: URL
    private let extractor: any RuntimeArchiveExtracting
    private let fileManager: FileManager
    private var operations: Set<AgentEngineID> = []

    public init(root: URL, extractor: any RuntimeArchiveExtracting, fileManager: FileManager = .default) {
        self.root = root
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func install(_ manifest: RuntimeManifest) -> AsyncThrowingStream<RuntimeInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validate(manifest)
                    try RuntimePrivacyPolicy.requireEndpoint(manifest.archiveURL)
                    guard operations.insert(manifest.engine).inserted else { throw RuntimeError.operationInProgress }
                    defer { operations.remove(manifest.engine) }
                    continuation.yield(progress(manifest.engine, .preparing, 2, "Preparing installation…"))
                    let engineRoot = root.appending(path: manifest.engine.rawValue, directoryHint: .isDirectory)
                    try fileManager.createDirectory(at: engineRoot, withIntermediateDirectories: true)
                    let staging = engineRoot.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
                    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
                    defer { try? fileManager.removeItem(at: staging) }

                    continuation.yield(progress(manifest.engine, .downloading, 10, "Downloading runtime…"))
                    let (temporaryURL, response) = try await RuntimeManagedNetworkSession.shared.download(from: manifest.archiveURL)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let finalHost = response.url?.host, manifest.allowedHosts.contains(finalHost), response.url?.scheme == "https" else {
                        throw RuntimeError.downloadFailed
                    }
                    let archive = staging.appending(path: "runtime.download")
                    try fileManager.moveItem(at: temporaryURL, to: archive)

                    continuation.yield(progress(manifest.engine, .verifying, 45, "Verifying runtime…"))
                    let actualHash = try Self.sha256(of: archive)
                    guard actualHash == manifest.sha256 else {
                        throw RuntimeError.checksumMismatch(expected: manifest.sha256, actual: actualHash)
                    }

                    let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
                    try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: false)
                    continuation.yield(progress(manifest.engine, .extracting, 60, "Extracting runtime…"))
                    try await extractor.extract(archive: archive, format: manifest.archiveFormat, destination: unpacked)
                    try Task.checkCancellation()

                    continuation.yield(progress(manifest.engine, .validating, 88, "Validating installation…"))
                    let executable = unpacked.appending(path: manifest.executableRelativePath)
                    guard executable.resolvingSymlinksInPath().path.hasPrefix(unpacked.resolvingSymlinksInPath().path + "/"),
                          fileManager.isExecutableFile(atPath: executable.path) else {
                        throw RuntimeError.missingExecutable(manifest.executableRelativePath)
                    }

                    let record = RuntimeInstallationRecord(manifest: manifest, executableSHA256: try Self.sha256(of: executable), installedAt: .now)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                    let recordURL = unpacked.appendingPathComponent("installation-v1.json")
                    try encoder.encode(record).write(to: recordURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)

                    try Task.checkCancellation()
                    continuation.yield(progress(manifest.engine, .activating, 96, "Activating runtime…"))
                    let current = engineRoot.appending(path: "current", directoryHint: .isDirectory)
                    let rollback = engineRoot.appending(path: "rollback", directoryHint: .isDirectory)
                    if fileManager.fileExists(atPath: rollback.path) { try fileManager.removeItem(at: rollback) }
                    if fileManager.fileExists(atPath: current.path) { try fileManager.moveItem(at: current, to: rollback) }
                    do {
                        try fileManager.moveItem(at: unpacked, to: current)
                    } catch {
                        if fileManager.fileExists(atPath: rollback.path), !fileManager.fileExists(atPath: current.path) {
                            try? fileManager.moveItem(at: rollback, to: current)
                        }
                        throw error
                    }
                    continuation.yield(progress(manifest.engine, .complete, 100, "Runtime installed."))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func uninstall(_ engine: AgentEngineID) throws {
        guard !operations.contains(engine) else { throw RuntimeError.operationInProgress }
        let target = root.appending(path: engine.rawValue, directoryHint: .isDirectory)
        guard target.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw RuntimeError.invalidInstallRoot
        }
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }

    public func rollback(_ engine: AgentEngineID) throws {
        guard !operations.contains(engine) else { throw RuntimeError.operationInProgress }
        let engineRoot = root.appending(path: engine.rawValue, directoryHint: .isDirectory)
        let current = engineRoot.appending(path: "current", directoryHint: .isDirectory)
        let rollback = engineRoot.appending(path: "rollback", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: rollback.path) else { throw RuntimeError.rollbackUnavailable }
        let failed = engineRoot.appending(path: ".failed-\(UUID().uuidString)")
        if fileManager.fileExists(atPath: current.path) { try fileManager.moveItem(at: current, to: failed) }
        do {
            try fileManager.moveItem(at: rollback, to: current)
            try? fileManager.removeItem(at: failed)
        } catch {
            if fileManager.fileExists(atPath: failed.path) { try? fileManager.moveItem(at: failed, to: current) }
            throw error
        }
    }

    public func installation(_ engine: AgentEngineID) throws -> RuntimeInstallationRecord? {
        let file = root.appendingPathComponent(engine.rawValue).appendingPathComponent("current/installation-v1.json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(RuntimeInstallationRecord.self, from: Data(contentsOf: file))
        guard record.version == 1, record.manifest.engine == engine else { throw RuntimeError.invalidInstallRoot }
        return record
    }
    private func validate(_ manifest: RuntimeManifest) throws {
        if manifest.engine == .externalStdio {
            guard manifest.adapterProtocolVersion.map({ [1, 2].contains($0) }) == true, manifest.adapterIdentity?.isEmpty == false else { throw RuntimeError.incompatibleAdapter }
        }
        guard manifest.archiveURL.scheme == "https",
              let host = manifest.archiveURL.host,
              manifest.allowedHosts.contains(host)
        else { throw RuntimeError.untrustedDownloadOrigin }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeError.invalidChecksum
        }
        guard !manifest.executableRelativePath.hasPrefix("/"), !manifest.executableRelativePath.contains("..") else {
            throw RuntimeError.invalidExecutablePath
        }
    }

    private func progress(_ engine: AgentEngineID, _ phase: RuntimeInstallPhase, _ percent: Int, _ message: String) -> RuntimeInstallProgress {
        RuntimeInstallProgress(engine: engine, phase: phase, percent: percent, message: message)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum RuntimeError: LocalizedError, Sendable {
    case operationInProgress
    case incompatibleAdapter
    case downloadFailed
    case untrustedDownloadOrigin
    case invalidChecksum
    case checksumMismatch(expected: String, actual: String)
    case invalidExecutablePath
    case missingExecutable(String)
    case invalidInstallRoot
    case rollbackUnavailable

    public var errorDescription: String? {
        switch self {
        case .operationInProgress: "A runtime installation is already in progress for this engine."
        case .incompatibleAdapter: "The external adapter manifest must name its identity and AIM stdio protocol v1."
        case .downloadFailed: "The runtime download failed."
        case .untrustedDownloadOrigin: "The runtime download origin is not allowed."
        case .invalidChecksum: "The pinned runtime checksum is invalid."
        case let .checksumMismatch(expected, actual): "Runtime checksum mismatch (expected \(expected), got \(actual))."
        case .invalidExecutablePath: "The runtime executable path is unsafe."
        case let .missingExecutable(path): "The runtime is missing its executable at \(path)."
        case .invalidInstallRoot: "The runtime installation root is invalid."
        case .rollbackUnavailable: "No previous runtime is available."
        }
    }
}
