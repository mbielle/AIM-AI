import AIMCore
import AIMApplication
import AIMProcessSupport
import Darwin
import Foundation

/// AIM's own local model engine: the bundled llama.cpp server, started only when a local
/// model is chosen, bound to 127.0.0.1 on a free port, one model in memory at a time,
/// unloaded after a quiet period and when AIM quits. No other app is needed.
public actor BuiltInLocalEngine {
    public static let shared = BuiltInLocalEngine()

    public enum State: Equatable, Sendable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
    }

    public enum EngineError: LocalizedError, Equatable {
        case notBundled, modelMissing, didNotStart(String)
        public var errorDescription: String? {
            switch self {
            case .notBundled: "This copy of AIM does not include its local model engine."
            case .modelMissing: "The model file is missing. Download it again."
            case .didNotStart(let log): "The local model could not be loaded (not enough memory or an unsupported file). Details: \(log)"
            }
        }
    }

    public private(set) var state: State = .idle
    private var process: Process?
    private var loadedFile: URL?
    /// The context and cache setting the loaded model was started with.
    private var loadedConfiguration: Configuration?
    private var baseURL: URL?
    private var privacyEndpointID: UUID?
    private final class ProcessLiveness: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
    private var lastUse = Date.now
    private var idleTask: Task<Void, Never>?
    private let idleLimit: TimeInterval
    private let executable: URL?
    private let mlxExecutable: URL?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(executable: URL? = BuiltInLocalEngine.bundledServer, mlxExecutable: URL? = BuiltInLocalEngine.bundledMLXEngine,
                idleLimit: TimeInterval = 600) {
        self.executable = executable
        self.mlxExecutable = mlxExecutable
        self.idleLimit = idleLimit
    }

    /// AIM's MLX engine (Contents/Resources/MLXEngine), for MLX model folders.
    public static var bundledMLXEngine: URL? {
        guard let url = HostBundleResources.resourceURL?.appendingPathComponent("MLXEngine/aim-mlx-engine"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    public static var isMLXAvailable: Bool { bundledMLXEngine != nil }

    /// An MLX model is a folder (config.json + safetensors); GGUF is a single file.
    public static func isMLXFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// The bundled `llama-server` (Contents/Resources/LlamaCpp), when this build includes it.
    public static var bundledServer: URL? {
        guard let url = HostBundleResources.resourceURL?.appendingPathComponent("LlamaCpp/llama-server"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    public static var isAvailable: Bool { bundledServer != nil }

    public func updates() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ value: State) {
        state = value
        for continuation in observers.values { continuation.yield(value) }
    }

    public struct Configuration: Equatable, Sendable {
        public var contextTokens: Int
        public var kvCacheQuantized: Bool
        public init(contextTokens: Int, kvCacheQuantized: Bool) {
            self.contextTokens = contextTokens; self.kvCacheQuantized = kvCacheQuantized
        }
    }

    /// The engine arguments for a model file or folder.
    static func arguments(file: URL, mlx: Bool, port: Int, name: String, contextTokens: Int, kvCacheQuantized: Bool) -> [String] {
        if mlx {
            var arguments = ["--model", file.path, "--port", String(port), "--alias", name]
            if contextTokens > 0 { arguments += ["--context", String(contextTokens)] }
            if kvCacheQuantized { arguments += ["--kv-bits", "8"] }
            return arguments
        }
        var arguments = ["-m", file.path, "--host", "127.0.0.1", "--port", String(port), "--jinja",
                         "-ngl", "99", "-c", String(contextTokens), "--alias", name, "--no-webui"]
        // An 8-bit KV cache needs flash attention in llama.cpp.
        if kvCacheQuantized { arguments += ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"] }
        return arguments
    }

    /// Loads `file` (unloading any other model) and returns the OpenAI-compatible base URL.
    /// The same model with another context or cache setting is restarted.
    public func load(_ file: URL, name: String, contextTokens: Int, kvCacheQuantized: Bool = false) async throws -> URL {
        let configuration = Configuration(contextTokens: contextTokens, kvCacheQuantized: kvCacheQuantized)
        if loadedFile == file, loadedConfiguration == configuration, let baseURL, process?.isRunning == true {
            try RuntimePrivacyPolicy.requireEndpoint(baseURL)
            touch()
            return baseURL
        }
        let mlx = Self.isMLXFolder(file)
        guard let executable = mlx ? mlxExecutable : executable else { throw EngineError.notBundled }
        let isBundled = executable.standardizedFileURL == (mlx ? Self.bundledMLXEngine : Self.bundledServer)?.standardizedFileURL
        if RuntimePrivacyPolicy.isEnabled {
            guard isBundled else {
                throw RuntimePrivacyError.externalAccessDisabled
            }
        }
        guard FileManager.default.fileExists(atPath: file.path) else { throw EngineError.modelMissing }
        await stop()
        set(.loading(name))
        let port = Self.freePort()
        let privacyLease = isBundled ? nil : try AIMNetworkPrivacyPolicy.beginOpaqueOperation("custom local model executable")
        let process = Process()
        if let privacyLease { process.terminationHandler = { [privacyLease] _ in privacyLease.finish() } }
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        // GGUF → llama.cpp; MLX folder → AIM's MLX engine (same OpenAI-style interface).
        process.arguments = Self.arguments(file: file, mlx: mlx, port: port, name: name,
                                           contextTokens: contextTokens, kvCacheQuantized: kvCacheQuantized)
        let log = Self.logFile()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            set(.failed(error.localizedDescription))
            throw EngineError.didNotStart(log.path)
        }
        LocalModelRuntime.track(process, isAttestedLocal: isBundled)
        self.process = process
        let url = URL(string: "http://127.0.0.1:\(port)/v1")!
        let liveness = ProcessLiveness(process)
        if isBundled {
            privacyEndpointID = try RuntimePrivacyPolicy.registerManagedLocalEndpoint(url, ownerIsRunning: {
                liveness.process.isRunning && aim_process_owns_loopback_listener(liveness.process.processIdentifier, UInt16(port)) == 1
            })
        }
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date.now.addingTimeInterval(240)
        while Date.now < deadline {
            if !process.isRunning { break }
            if await Self.isHealthy(health) {
                loadedFile = file
                loadedConfiguration = configuration
                baseURL = url
                set(.ready(name))
                touch()
                return url
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        await stop()
        let failure = EngineError.didNotStart(log.path)
        set(.failed(failure.localizedDescription))
        throw failure
    }

    /// Marks the model as in use; it is unloaded after `idleLimit` without use.
    public func touch() {
        lastUse = .now
        idleTask?.cancel()
        let limit = idleLimit
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard Date.now.timeIntervalSince(lastUse) >= idleLimit else { return }
        await stop()
    }

    /// Ends the server and waits for it to exit (forced after 3 s), freeing its memory.
    public func stop() async {
        if let privacyEndpointID { RuntimePrivacyPolicy.unregisterManagedLocalEndpoint(privacyEndpointID) }
        privacyEndpointID = nil
        idleTask?.cancel()
        idleTask = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date.now.addingTimeInterval(3)
            while process.isRunning, Date.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        loadedFile = nil
        loadedConfiguration = nil
        baseURL = nil
        if state != .idle { set(.idle) }
    }

    public var loadedModelFile: URL? { loadedFile }
    public var loadedModelConfiguration: Configuration? { loadedConfiguration }

    // MARK: Helpers

    static func isHealthy(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await RuntimeManagedNetworkSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// A free TCP port on the loopback interface.
    static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 8_765
    }

    static func logFile() -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/" + AIMInstallationContext.legacyDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("local-engine.log")
    }

    /// A context window that fits next to the weights in unified memory (shape-aware when known).
    public static func contextTokens(weightsBytes: Int64, architecture: LocalModelMemory.Architecture? = nil,
                                     budget: Int64 = LocalModelMemory.budget()) -> Int {
        LocalModelMemory.recommendedContext(weightsBytes: weightsBytes, architecture: architecture, budget: budget)
    }
}
