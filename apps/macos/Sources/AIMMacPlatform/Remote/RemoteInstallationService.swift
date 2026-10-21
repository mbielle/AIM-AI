import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation
import CryptoKit
import Darwin

/// Explicit paired-device downloads. Selection alone never installs or starts an engine.
public actor RemoteInstallationService {
    public static let shared = RemoteInstallationService()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var jobs: [String: Job] = [:]
    private var admissions = Set<String>()
    private struct Job: Codable { var state: String; var progress: Double; var message: String }
    private var installer: UpstreamAgentInstaller?
    private let injectedReceipt: URL?
    private let installedAgent: (@Sendable (AgentEngineID) async throws -> String?)?
    private let installAgent: (@Sendable (AgentEngineID) async -> AsyncThrowingStream<RuntimeInstallProgress, Error>)?
    private let networkAdmission: @Sendable () throws -> Void
    private var receipt: URL? {
        injectedReceipt ?? (try? ApplicationPaths().applicationSupport)?.appending(path: "remote-downloads-v1.json")
    }
    public init(receiptURL: URL? = nil,
                installedAgent: (@Sendable (AgentEngineID) async throws -> String?)? = nil,
                installAgent: (@Sendable (AgentEngineID) async -> AsyncThrowingStream<RuntimeInstallProgress, Error>)? = nil,
                networkAdmission: @escaping @Sendable () throws -> Void = { try RuntimePrivacyPolicy.requireNetwork() }) {
        injectedReceipt = receiptURL; self.installedAgent = installedAgent; self.installAgent = installAgent; self.networkAdmission = networkAdmission
    }
    private func version(_ id: AgentEngineID) async throws -> String? {
        if let installedAgent { return try await installedAgent(id) }
        return try await agentInstaller().installation(id)?.version
    }
    private func install(_ id: AgentEngineID) async throws -> AsyncThrowingStream<RuntimeInstallProgress, Error> {
        if let installAgent { return await installAgent(id) }
        return try await agentInstaller().install(id)
    }
    private func agentInstaller() throws -> UpstreamAgentInstaller {
        if let installer { return installer }
        let root = try ApplicationPaths().applicationSupport.appending(path: "Agents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let value = UpstreamAgentInstaller(root: root); installer = value; return value
    }
    private func load() {
        guard let receipt, let data = try? Data(contentsOf: receipt), let saved = try? JSONDecoder().decode([String: Job].self, from: data) else { return }
        jobs = saved.mapValues { $0 }
        for (key, job) in jobs where job.state == "running" && tasks[key] == nil {
            // A different host process can still own this download.
            if let lease = try? DownloadLease(receipt: receipt, key: key) {
                jobs[key] = Job(state: "interrupted", progress: job.progress, message: "Download interrupted. Review before retrying.")
                withExtendedLifetime(lease) {}
            }
        }
    }
    /// Merge one item while holding a receipt lock, so the UI and helper cannot
    /// overwrite one another's jobs or race Foundation's atomic replacement.
    private func persist(_ key: String, job: Job) throws {
        guard let receipt else { throw DownloadError.storageUnavailable }
        let lock = try DownloadLease(receipt: receipt, key: "__receipt__", wait: true)
        defer { withExtendedLifetime(lock) {} }
        var saved = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode([String: Job].self, from: $0) } ?? [:]
        saved[key] = job
        try JSONEncoder().encode(saved).write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        jobs.merge(saved) { _, new in new }
    }
    private func update(_ key: String, _ state: String, _ progress: Double, _ message: String) {
        let job = Job(state: state, progress: min(1, max(0, progress)), message: String(message.prefix(500)))
        jobs[key] = job
        try? persist(key, job: job)
    }
    /// A receipt must be durable before a background operation can begin.
    private func begin(_ key: String, message: String) throws -> DownloadLease {
        guard let receipt else { throw DownloadError.storageUnavailable }
        let lease = try DownloadLease(receipt: receipt, key: key)
        try persist(key, job: .init(state: "running", progress: 0, message: message))
        return lease
    }

    /// The lease is held by the task, across actors and the UI/helper processes.
    private final class DownloadLease: @unchecked Sendable {
        let descriptor: Int32
        init(receipt: URL, key: String, wait: Bool = false) throws {
            let directory = receipt.deletingLastPathComponent().appendingPathComponent("RemoteDownloadLeases", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = SHA256.hash(data: Data((receipt.standardizedFileURL.path + "\0" + key).utf8)).map { String(format: "%02x", $0) }.joined()
            descriptor = Darwin.open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw DownloadError.storageUnavailable }
            guard flock(descriptor, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw DownloadError.alreadyDownloading }
        }
        deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    }

    private func report(_ key: String, fraction: Double, file: String) {
        guard tasks[key] != nil, jobs[key]?.state == "running" else { return }
        update(key, "running", fraction, file)
    }
    public func engines() async -> [RemoteEngineAnnouncement] {
        load()
        var values: [RemoteEngineAnnouncement] = [.init(id: "aim", state: "ready", features: ["plan": true, "goal": true, "attachments": true, "imageAttachments": true])]
        for id in UpstreamAgentInstaller.downloadable {
            let installed = try? await version(id)
            values.append(.init(id: id.rawValue, state: tasks["agent:" + id.rawValue] != nil ? "starting" : installed != nil ? "stopped" : "not_installed", version: installed, providers: [ChatProvider.openRouter.rawValue], features: ["plan": true, "goal": false, "attachments": true, "imageAttachments": true]))
        }
        return values
    }
    private func status() -> RemoteJSONValue {
        .object(["jobs": .object(jobs.mapValues { .object(["state": .string($0.state), "progress": .number($0.progress), "message": .string($0.message)]) })])
    }
    public func execute(type: String, payload: RemoteJSONValue) async throws -> RemoteJSONValue {
        load()
        guard let object = payload.objectValue, object["section"]?.stringValue == "downloads", object["version"] == .number(1),
              let operation = object["operation"]?.stringValue else { throw DownloadError.invalidRequest }
        if type == "get_mac_settings" {
            if operation == "status" { return status() }
            try networkAdmission()
            guard let format = HuggingFaceModelHub.Format(rawValue: object["format"]?.stringValue ?? "gguf") else { throw DownloadError.invalidRequest }
            if operation == "search" {
                let results = try await HuggingFaceModelHub.search(String((object["query"]?.stringValue ?? "").prefix(150)), format: format)
                return .object(["models": .array(results.map { .object(["id": .string($0.id)]) })])
            }
            if operation == "detail", let repo = object["repo"]?.stringValue {
                let detail = try await HuggingFaceModelHub.detail(repo)
                let choices = format == .gguf ? HuggingFaceModelHub.ggufQuantizations(detail).map { ($0.name, $0.bytes) }
                    : [("MLX", HuggingFaceModelHub.files(for: detail, format: format).reduce(Int64(0)) { $0 + $1.size })]
                return .object(["repo": .string(repo), "revision": .string(detail.sha), "gated": .bool(detail.gated),
                    "variants": .array(choices.map { name, bytes in .object(["name": .string(name), "bytes": .number(Double(bytes)), "fit": .string(HuggingFaceModelHub.fit(weightsBytes: bytes).rawValue)]) })])
            }
            throw DownloadError.invalidRequest
        }
        guard type == "set_mac_settings" else { throw DownloadError.invalidRequest }
        if operation == "cancel", let key = object["key"]?.stringValue {
            tasks[key]?.cancel(); return status()
        }
        try networkAdmission()
        if operation == "agent", let raw = object["agent"]?.stringValue, let id = AgentEngineID(rawValue: raw), UpstreamAgentInstaller.downloadable.contains(id) {
            let key = "agent:" + raw
            guard tasks[key] == nil, !admissions.contains(key) else { return status() }
            admissions.insert(key); defer { admissions.remove(key) }
            if try await version(id) != nil { update(key, "complete", 1, "Installed"); return status() }
            let lease = try begin(key, message: "Preparing installation")
            tasks[key] = Task {
                defer { withExtendedLifetime(lease) {} }
                do {
                    for try await progress in try await self.install(id) {
                        try Task.checkCancellation()
                        self.update(key, "running", Double(progress.percent) / 100, progress.message)
                    }
                    try Task.checkCancellation()
                    self.update(key, "complete", 1, "Installed. Select this agent to use it.")
                } catch { self.update(key, Task.isCancelled ? "cancelled" : "failed", 0, error.localizedDescription) }
                self.tasks[key] = nil
            }
            return status()
        }
        if operation == "model", let repo = object["repo"]?.stringValue,
           let format = HuggingFaceModelHub.Format(rawValue: object["format"]?.stringValue ?? ""),
           let revision = object["revision"]?.stringValue, let variant = object["variant"]?.stringValue,
           let approvedBytes = object["bytes"]?.numberValue, approvedBytes > 0 {
            let key = "model:" + repo + ":" + format.rawValue + ":" + variant
            guard tasks[key] == nil, !admissions.contains(key) else { return status() }
            admissions.insert(key); defer { admissions.remove(key) }
            let detail = try await HuggingFaceModelHub.detail(repo)
            let files = HuggingFaceModelHub.files(for: detail, format: format, ggufFile: format == .gguf ? variant : nil)
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            guard detail.sha == revision, !detail.gated, !files.isEmpty, files.allSatisfy({ $0.size > 0 }), Double(bytes) == approvedBytes else { throw DownloadError.changedSelection }
            let free = (try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard bytes < free - 1_000_000_000 else { throw DownloadError.diskFull }
            let lease = try begin(key, message: "Downloading selected revision")
            tasks[key] = Task {
                defer { withExtendedLifetime(lease) {} }
                do {
                    _ = try await HuggingFaceModelHub.download(detail, files: files, format: format) { progress in
                        Task { await self.report(key, fraction: Double(progress.completedBytes) / Double(max(1, progress.totalBytes)), file: progress.file) }
                    }
                    try Task.checkCancellation()
                    self.update(key, "complete", 1, "Downloaded on this Mac. Activate it in the local runtime when ready.")
                } catch { self.update(key, Task.isCancelled ? "cancelled" : "failed", 0, error.localizedDescription) }
                self.tasks[key] = nil
            }
            return status()
        }
        throw DownloadError.invalidRequest
    }
    public enum DownloadError: String, LocalizedError {
        case invalidRequest, changedSelection, diskFull, storageUnavailable, alreadyDownloading
        public var errorDescription: String? {
            switch self {
            case .invalidRequest: "Invalid remote download request."
            case .changedSelection: "The selected revision or size changed, or the repository needs authorization. Review it again."
            case .diskFull: "Insufficient free space on this Mac."
            case .storageUnavailable: "The download receipt could not be saved on this Mac. No download was started."
            case .alreadyDownloading: "This item is already downloading on this Mac. Wait for that operation before retrying."
            }
        }
    }
}
