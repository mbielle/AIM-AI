import AIMCore
import AIMApplication
import Foundation

/// The local inference servers AIM can use, all OpenAI-compatible on loopback:
/// oMLX (MLX, port 8000, can be started by AIM over the Hugging Face cache),
/// LM Studio (port 1234, `lms server start`) and Ollama (port 11434).
public enum LocalModelRuntime {
    public enum Kind: String, Sendable, CaseIterable {
        case omlx, lmStudio = "lm_studio", ollama

        public var name: String {
            switch self { case .omlx: "oMLX"; case .lmStudio: "LM Studio"; case .ollama: "Ollama" }
        }
        public var baseURL: URL {
            switch self {
            case .omlx: URL(string: "http://127.0.0.1:8000/v1")!
            case .lmStudio: URL(string: "http://127.0.0.1:1234/v1")!
            case .ollama: URL(string: "http://127.0.0.1:11434/v1")!
            }
        }
    }

    public struct Status: Sendable, Equatable, Identifiable {
        public var id: String { kind.rawValue }
        public let kind: Kind
        public let installed: Bool
        public let running: Bool
        public let models: [String]
    }

    /// The executable that starts a runtime, if installed.
    public static func executable(_ kind: Kind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [String]
        switch kind {
        case .omlx: candidates = [home.appendingPathComponent(".local/bin/omlx").path, "/opt/homebrew/bin/omlx", "/usr/local/bin/omlx",
                                  "/Applications/oMLX.app/Contents/MacOS/omlx"]
        case .lmStudio: candidates = [home.appendingPathComponent(".lmstudio/bin/lms").path, "/opt/homebrew/bin/lms", "/usr/local/bin/lms"]
        case .ollama: candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        }
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func models(at base: URL, session: URLSession = RuntimeManagedNetworkSession.shared) async -> [String]? {
        var request = URLRequest(url: LocalModelEndpoint.url("models", base: base), timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        return rows.compactMap { $0["id"] as? String }
    }

    public static func detect() async -> [Status] {
        await withTaskGroup(of: Status.self) { group in
            for kind in Kind.allCases {
                group.addTask {
                    let models = await models(at: kind.baseURL)
                    return Status(kind: kind, installed: executable(kind) != nil || models != nil,
                                  running: models != nil, models: models ?? [])
                }
            }
            var all: [Status] = []
            for await status in group { all.append(status) }
            return all.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    /// Starts a runtime's server in the background and waits until it answers.
    /// oMLX serves the Hugging Face cache, so models AIM downloads appear at once.
    @discardableResult
    public static func start(_ kind: Kind, timeout: TimeInterval = 60) async throws -> [String] {
        try RuntimePrivacyPolicy.requireNetwork()
        if let models = await models(at: kind.baseURL) { return models }
        guard let executable = executable(kind) else { throw RuntimeError.notInstalled(kind.name) }
        let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("external local model server " + kind.name)
        let process = Process()
        process.executableURL = executable
        switch kind {
        case .omlx: process.arguments = ["serve", "--hf-cache", "--host", "127.0.0.1", "--port", "8000"]
        case .lmStudio: process.arguments = ["server", "start"]
        case .ollama: process.arguments = ["serve"]
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/" + AIMInstallationContext.legacyDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(kind.rawValue).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [privacyLease] _ in privacyLease.finish() }
        try process.run()
        if kind != .lmStudio { StartedServers.shared.add(process) } // `lms server start` hands off to LM Studio itself.
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let models = await models(at: kind.baseURL) { return models }
            if !process.isRunning, kind == .omlx || kind == .ollama { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RuntimeError.didNotStart(kind.name, log.path)
    }

    /// Servers AIM itself started end with AIM, so a model does not keep gigabytes of memory afterwards.
    public static func stopStartedServers() { StartedServers.shared.terminateAll() }

    /// Registers a server process AIM started so it ends with AIM.
    public static func track(_ process: Process, isAttestedLocal: Bool = false) { StartedServers.shared.add(process, isAttestedLocal: isAttestedLocal) }
    public static func stopOpaqueServers() { StartedServers.shared.terminateAll(onlyOpaque: true) }

    public enum RuntimeError: LocalizedError, Equatable {
        case notInstalled(String), didNotStart(String, String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled(let name): "\(name) is not installed on this Mac."
            case .didNotStart(let name, let log): "\(name) did not start; see \(log)."
            }
        }
    }
}

private final class StartedServers: @unchecked Sendable {
    static let shared = StartedServers()
    private let lock = NSLock()
    private var processes: [(process: Process, attested: Bool)] = []
    func add(_ process: Process, isAttestedLocal: Bool = false) {
        lock.withLock { processes.append((process, isAttestedLocal)) }
    }
    func terminateAll(onlyOpaque: Bool = false) {
        let all = lock.withLock {
            let selected = processes.filter { !onlyOpaque || !$0.attested }.map(\.process)
            processes.removeAll { !onlyOpaque || !$0.attested }
            return selected
        }
        for process in all where process.isRunning { process.terminate() }
    }
}
