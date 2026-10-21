import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation

/// Minimal, bounded JSON-RPC stdio transport. Host tool services own their
/// allowlists; a remote tools/list response never authorizes an action.
final class PlaywrightMCPClient: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var privacyLease: AIMNetworkPrivacyLease?
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var pending: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    private var nextID = 1
    private var stopped = false
    private var bytesWritten = 0
    private var bytesRead = 0
    private var stderrBytes = 0
    private var readerEnded = false
    private var toolSchemas: [String: Data] = [:]
    /// Complete tools/list entries (description, annotations, output schema) as
    /// sorted JSON. Descriptive only: a remote listing never authorizes an action.
    private var toolDefinitions: [String: Data] = [:]
    private var handshake: Data?
    private let protocolVersion: String
    /// Versions a generic server may answer with; pinned helpers accept only theirs.
    private var acceptedProtocolVersions: Set<String> = []
    private let requiresToolsCapability: Bool

    static func chromeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "\(home)/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func chromeLauncher() -> String? {
        guard chromeExecutable() != nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Playwright", isDirectory: true)
        let launcher = folder.appendingPathComponent("open-in-chrome.sh")
        let script = """
        #!/bin/sh
        # Written by AIM. Opens the Playwright extension's connect page (the last
        # argument) in the person's own Chrome through LaunchServices.
        for last; do :; done
        exec /usr/bin/open -a "Google Chrome" "$last"

        """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? String(contentsOf: launcher, encoding: .utf8)) != script {
                try script.write(to: launcher, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            return launcher.path
        } catch {
            return nil
        }
    }

    convenience init(node: URL, cli: URL, configuration: AgentBrowserConfiguration = .init()) throws {
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: cli.path) else { throw PlaywrightError.runtimeMissing }
        var environment = Self.cleanEnvironment()
        // The token only bypasses the extension's connection prompt; it never
        // reaches logs, reports or the model.
        if configuration.mode == .extensionConnected, let token = configuration.extensionToken, !token.isEmpty {
            environment["PLAYWRIGHT_MCP_EXTENSION_TOKEN"] = token
        }
        // macOS denies other apps read access to Chrome's profile folder, so the
        // helper's scan for the installed extension fails, and a Chrome started as
        // AIM's child process would have its own profile reads attributed to AIM and
        // blocked ("Data Access Blocked"). A tiny launcher hands the connect page to
        // the person's Chrome through LaunchServices instead.
        if configuration.mode == .extensionConnected, let launcher = Self.chromeLauncher() {
            environment["PLAYWRIGHT_MCP_EXECUTABLE_PATH"] = launcher
        }
        try self.init(executable: node, arguments: [cli.path] + configuration.serverArguments,
            environment: environment, protocolVersion: "2025-11-25",
            requiresToolsCapability: true, workingDirectory: configuration.workspace)
    }

    convenience init(cuaDriver: URL, socketPath: String, hostBundleID: String) throws {
        guard FileManager.default.isExecutableFile(atPath: cuaDriver.path) else { throw PlaywrightError.runtimeMissing }
        try self.init(executable: cuaDriver,
            arguments: ["mcp", "--embedded", "--host-bundle-id", hostBundleID, "--socket", socketPath],
            environment: CuaDriverEnvironment.make(hostBundleID: hostBundleID), protocolVersion: "2025-06-18",
            requiresToolsCapability: false)
    }

    /// A user-configured stdio MCP server. It receives only neutral variables
    /// plus the secrets configured for it, and starts in the given directory.
    convenience init(server executable: URL, arguments: [String], secrets: [String: String],
                     workingDirectory: URL?) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PlaywrightError.runtimeMissing }
        var environment = Self.cleanEnvironment().merging(secrets) { _, secret in secret }
        // GUI apps get a minimal PATH; scripts such as `npx` need their own
        // directory and the usual package-manager locations to find `node`.
        let searchPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                          environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = searchPath.joined(separator: ":")
        try self.init(executable: executable, arguments: arguments,
            environment: environment,
            protocolVersion: "2025-06-18", requiresToolsCapability: true, workingDirectory: workingDirectory)
        acceptedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    }

    private init(executable: URL, arguments: [String], environment: [String: String],
                 protocolVersion: String, requiresToolsCapability: Bool, workingDirectory: URL? = nil) throws {
        try RuntimePrivacyPolicy.requireNetwork()
        privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("browser, CUA or MCP stdio helper")
        self.protocolVersion = protocolVersion
        self.requiresToolsCapability = requiresToolsCapability
        process.executableURL = executable
        process.arguments = arguments
        // Playwright confines file access to its working directory when no MCP roots are declared.
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = environment
        process.terminationHandler = { [weak self, privacyLease] _ in
            privacyLease?.finish()
            self?.lock.withLock { self?.privacyLease = nil }
        }
        try process.run()
        // FileHandle.read is blocking. Keep it off Swift's cooperative executor.
        DispatchQueue.global(qos: .utility).async { [self] in readResponses() }
        DispatchQueue.global(qos: .utility).async { [self] in drainErrors() }
    }

    func initialize() async throws {
        let response = try await call("initialize", params: [
            "protocolVersion": protocolVersion,
            "capabilities": [:] as [String: String],
            "clientInfo": ["name": "AIM AI", "version": "0.1.0"]
        ])
        let negotiated = response["protocolVersion"] as? String
        guard negotiated == protocolVersion || negotiated.map(acceptedProtocolVersions.contains) == true else {
            throw PlaywrightError.invalidHandshake("protocol version \(response["protocolVersion"] as? String ?? "missing"); expected \(protocolVersion)")
        }
        if requiresToolsCapability && (response["capabilities"] as? [String: Any])?["tools"] == nil {
            throw PlaywrightError.invalidHandshake("tool capability missing")
        }
        let summary = response.filter { ["protocolVersion", "serverInfo", "capabilities"].contains($0.key) }
        let encoded = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        lock.withLock { handshake = encoded }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func listTools() async throws -> Set<String> {
        lock.withLock { toolSchemas = [:]; toolDefinitions = [:] }
        var schemas: [String: Data] = [:]
        var definitions: [String: Data] = [:]
        var cursor: String?
        var seenCursors: Set<String> = []
        // MCP servers may split a large registry into pages. Bound the
        // discovery itself, and never publish a partial registry as complete.
        for _ in 0..<20 {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let result = try await call("tools/list", params: params)
            guard let tools = result["tools"] as? [[String: Any]],
                  schemas.count + tools.count <= 500 else {
                throw PlaywrightError.invalidResponse
            }
            for tool in tools {
                guard let name = tool["name"] as? String, !name.isEmpty, schemas[name] == nil,
                      let schema = tool["inputSchema"] as? [String: Any],
                      schema["type"] as? String == "object" || (schema["type"] == nil && schema["properties"] != nil) else {
                    throw PlaywrightError.invalidResponse
                }
                schemas[name] = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
                definitions[name] = try JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys])
            }
            guard let next = result["nextCursor"] else {
                lock.withLock { toolSchemas = schemas; toolDefinitions = definitions }
                return Set(schemas.keys)
            }
            guard let next = next as? String, !next.isEmpty,
                  seenCursors.insert(next).inserted else {
                throw PlaywrightError.invalidResponse
            }
            cursor = next
        }
        throw PlaywrightError.invalidResponse
    }

    func inputSchema(for name: String) -> Data? { lock.withLock { toolSchemas[name] } }
    func toolDefinition(for name: String) -> Data? { lock.withLock { toolDefinitions[name] } }
    /// The negotiated server summary (protocol, serverInfo, capabilities), if initialized.
    func handshakeSummary() -> Data? { lock.withLock { handshake } }

    func callTool(_ name: String, arguments: [String: Any], requestID: String) async throws -> ToolResult {
        guard inputSchema(for: name) != nil else { throw PlaywrightError.invalidResponse }
        let result = try await call("tools/call", params: ["name": name, "arguments": arguments])
        return try Self.decodeToolResult(result, requestID: requestID)
    }

    func callRawTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard inputSchema(for: name) != nil else { throw PlaywrightError.invalidResponse }
        return try await call("tools/call", params: ["name": name, "arguments": arguments])
    }

    /// Preserve error results as tool data, including their pixels and structured content.
    /// Large text is archived by AIM's dispatcher, never silently cut here.
    static func decodeToolResult(_ result: [String: Any], requestID: String) throws -> ToolResult {
        guard let blocks = result["content"] as? [[String: Any]] else { throw PlaywrightError.invalidResponse }
        var text: [String] = []
        var image: Data?
        var warnings: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let value = block["text"] as? String else { throw PlaywrightError.invalidResponse }
                text.append(value)
            case "image":
                guard let encoded = block["data"] as? String, let mime = block["mimeType"] as? String else {
                    throw PlaywrightError.invalidResponse
                }
                if image == nil, mime == "image/png", let data = Data(base64Encoded: encoded),
                   data.count <= 6_000_000, data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) {
                    image = data
                } else { warnings.append("Additional, oversized or unsupported image omitted; do not act from missing pixels.") }
            default:
                // Embedded resources and links stay structured JSON, never instructions.
                let data = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
                text.append(String(decoding: data, as: UTF8.self))
            }
        }
        if let structured = result["structuredContent"] {
            let data = try JSONSerialization.data(withJSONObject: structured, options: [.fragmentsAllowed, .sortedKeys])
            text.append("[Structured tool data]\n" + String(decoding: data, as: UTF8.self))
        }
        if !warnings.isEmpty { text.append(warnings.joined(separator: "\n")) }
        return ToolResult(requestID: requestID, content: text.joined(separator: "\n"),
            isError: result["isError"] as? Bool ?? false,
            metadata: warnings.isEmpty ? [:] : ["content_omitted": "true"], imagePNG: image)
    }

    func stop() {
        let continuations: [CheckedContinuation<MCPResponse, Error>] = lock.withLock {
            if stopped { return [] }
            stopped = true
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for continuation in continuations { continuation.resume(throwing: PlaywrightError.stopped) }
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        // The read ends are closed by their reader loops after end of file: closing
        // them here, while availableData is blocked on another thread, raises an
        // Objective-C exception that aborts the whole app.
    }

    private func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id: Int = try lock.withLock {
            guard !stopped else { throw PlaywrightError.stopped }
            let id = nextID; nextID += 1
            return id
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPResponse, Error>) in
                let registered = lock.withLock {
                    guard !stopped else { return false }
                    pending[id] = continuation
                    return true
                }
                guard registered else { continuation.resume(throwing: PlaywrightError.stopped); return }
                if Task.isCancelled {
                    _ = fail(id, error: CancellationError())
                    stop()
                    return
                }
                do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
                catch { fail(id, error: error); return }
                Task.detached { [self] in
                    try? await Task.sleep(for: .seconds(method == "tools/call" ? 45 : 15))
                    if fail(id, error: PlaywrightError.timedOut(debugState())) {
                        // The action may already have taken effect. Retire this connection;
                        // never retry the mutation on a fresh client automatically.
                        stop()
                    }
                }
            }
        } onCancel: { [self] in
            if fail(id, error: CancellationError()) { stop() }
        }
        return response.value
    }

    private func send(_ object: [String: Any]) throws {
        try RuntimePrivacyPolicy.requireNetwork()
        let bytes = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try lock.withLock {
            guard !stopped else { throw PlaywrightError.stopped }
            try input.fileHandleForWriting.write(contentsOf: bytes)
            bytesWritten += bytes.count
        }
    }

    private func readResponses() {
        var buffer = Data()
        while true {
            let bytes = output.fileHandleForReading.availableData
            guard !bytes.isEmpty else { break }
            lock.withLock { bytesRead += bytes.count }
            buffer.append(bytes)
            guard buffer.count <= 24_000_000 else { break }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = json["id"] as? Int else { continue }
                let continuation = lock.withLock { pending.removeValue(forKey: id) }
                if let error = json["error"] as? [String: Any] {
                    continuation?.resume(throwing: PlaywrightError.toolFailed(String(describing: error["message"] ?? "MCP error")))
                } else if let result = json["result"] as? [String: Any] {
                    continuation?.resume(returning: MCPResponse(value: result))
                } else {
                    continuation?.resume(throwing: PlaywrightError.invalidResponse)
                }
            }
        }
        lock.withLock { readerEnded = true }
        stop()
        try? output.fileHandleForReading.close()
    }

    private func drainErrors() {
        while true {
            let bytes = errors.fileHandleForReading.availableData
            guard !bytes.isEmpty else { break }
            lock.withLock { stderrBytes += bytes.count }
            // Never log extension token, page content or browser diagnostics.
        }
        try? errors.fileHandleForReading.close()
    }

    @discardableResult
    private func fail(_ id: Int, error: Error) -> Bool {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
        return continuation != nil
    }

    private func debugState() -> String {
        let counts = lock.withLock { (bytesWritten, bytesRead, stderrBytes, readerEnded, stopped) }
        return "written=\(counts.0), read=\(counts.1), stderr=\(counts.2), readerEnded=\(counts.3), stopped=\(counts.4), processRunning=\(process.isRunning)"
    }

    private static func cleanEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"].contains(key)
        }
    }
}

private struct MCPResponse: @unchecked Sendable {
    let value: [String: Any]
}

enum PlaywrightError: LocalizedError {
    case runtimeMissing, invalidResponse, invalidHandshake(String), stopped, timedOut(String), toolFailed(String)
    var errorDescription: String? {
        switch self {
        case .runtimeMissing: "The bundled Playwright runtime is unavailable. Rebuild AIM with the Node runtime and Playwright MCP dependency."
        case .invalidResponse: "Playwright returned an invalid protocol response."
        case let .invalidHandshake(detail): "MCP initialization failed: \(detail)."
        case .stopped: "The Playwright browser connection stopped."
        case let .timedOut(state): "Playwright did not respond in time (\(state)). The action may have executed; inspect the page before retrying. The connection was retired."
        case let .toolFailed(message): "Playwright action failed: \(message)"
        }
    }
}
