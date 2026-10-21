import AIMApplication
import AIMCore
import Foundation

/// One tool as advertised by a configured MCP server. Descriptive only: a
/// remote listing never authorizes an action.
public struct MCPToolInfo: Sendable, Equatable {
    public let server: String
    public let name: String
    public let description: String
    public let inputSchema: Data
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
}

/// Transport-independent MCP session.
protocol MCPConnection: Sendable {
    func toolDefinitions() async throws -> [[String: Any]]
    /// Arguments and result are JSON objects, exchanged as data across isolation.
    func call(_ name: String, argumentsJSON: Data) async throws -> Data
    func close() async
}

extension PlaywrightMCPClient: MCPConnection {
    func toolDefinitions() async throws -> [[String: Any]] {
        let names = try await listTools()
        return names.sorted().compactMap { name in
            toolDefinition(for: name).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func call(_ name: String, argumentsJSON: Data) async throws -> Data {
        guard let arguments = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw PlaywrightError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: try await callRawTool(name, arguments: arguments))
    }

    func close() async { stop() }
}

/// Keychain storage for MCP secrets: `<server id>/<NAME>` in a dedicated service.
public enum MCPSecretStore {
    static let service = AIMInstallationContext.keychainService("com.aimai.macos.mcp")

    public static func save(_ value: String, name: String, serverID: UUID) throws {
        try KeychainSecureStore(service: service).store(Data(value.utf8), forKey: "\(serverID.uuidString)/\(name)")
    }

    public static func remove(name: String, serverID: UUID) throws {
        try KeychainSecureStore(service: service).removeData(forKey: "\(serverID.uuidString)/\(name)")
    }

    static func values(for server: MCPServerConfiguration) -> [String: String] {
        var values: [String: String] = [:]
        for name in server.secretNames {
            if let data = try? KeychainSecureStore(service: service).readData(forKey: "\(server.id.uuidString)/\(name)"),
               let value = String(data: data, encoding: .utf8) {
                values[name] = value
            }
        }
        return values
    }
}

/// App-wide owner of MCP server sessions: connects on first use, caches tool
/// listings, stops a server after repeated failures for a cool-down period
/// and closes idle sessions. "Connected" means a completed handshake and listing.
public actor MCPServerManager {
    public static let shared = MCPServerManager()

    public enum Status: Equatable, Sendable {
        case idle
        case connected(toolCount: Int)
        case coolingDown(until: Date, reason: String)
        case failed(String)
    }

    static let failureThreshold = 3
    static let coolDown: TimeInterval = 300
    static let idleTimeout: TimeInterval = 600

    private struct Entry {
        var configuration: MCPServerConfiguration
        var connection: (any MCPConnection)?
        var tools: [MCPToolInfo] = []
        var failures = 0
        var coolingUntil: Date?
        var lastError: String?
        var lastUsed = Date.now
    }

    private var entries: [UUID: Entry] = [:]
    private let connector: @Sendable (MCPServerConfiguration) async throws -> any MCPConnection
    private let clock: @Sendable () -> Date

    init(connector: @escaping @Sendable (MCPServerConfiguration) async throws -> any MCPConnection = MCPServerManager.connect,
         clock: @escaping @Sendable () -> Date = { .now }) {
        self.connector = connector
        self.clock = clock
    }

    public init() {
        self.init(connector: MCPServerManager.connect)
    }

    public func status(of server: MCPServerConfiguration) -> Status {
        guard let entry = entries[server.id] else { return .idle }
        if let until = entry.coolingUntil, until > clock() {
            return .coolingDown(until: until, reason: entry.lastError ?? "repeated failures")
        }
        if entry.connection != nil { return .connected(toolCount: entry.tools.count) }
        if let error = entry.lastError { return .failed(error) }
        return .idle
    }

    /// Tools allowed by the server's filters, connecting if needed.
    public func tools(of server: MCPServerConfiguration) async throws -> [MCPToolInfo] {
        try await session(for: server).tools
    }

    public func call(server: MCPServerConfiguration, tool: String, argumentsJSON: Data) async throws -> Data {
        let entry = try await session(for: server)
        guard entry.tools.contains(where: { $0.name == tool }), let connection = entry.connection else {
            throw MCPManagerError.unknownTool(tool)
        }
        do {
            let result = try await connection.call(tool, argumentsJSON: argumentsJSON)
            entries[server.id]?.lastUsed = clock()
            entries[server.id]?.failures = 0
            return result
        } catch {
            // The connection may be broken; never replay the call automatically.
            await disconnect(server.id, error: error.localizedDescription)
            throw error
        }
    }

    public func disconnect(_ id: UUID, error: String? = nil) async {
        let connection = entries[id]?.connection
        entries[id]?.connection = nil
        entries[id]?.tools = []
        if let error { entries[id]?.lastError = error }
        await connection?.close()
    }

    public func closeIdle() async {
        let now = clock()
        for (id, entry) in entries where entry.connection != nil && now.timeIntervalSince(entry.lastUsed) > Self.idleTimeout {
            await disconnect(id)
        }
    }

    public func closeAll() async {
        for id in entries.keys { await disconnect(id) }
    }

    private func session(for server: MCPServerConfiguration) async throws -> Entry {
        try RuntimePrivacyPolicy.requireNetwork()
        guard server.enabled, server.isValid else { throw MCPManagerError.disabled(server.name) }
        if var existing = entries[server.id], !Self.sameSession(existing.configuration, server) {
            await disconnect(server.id)
            existing.configuration = server
            entries[server.id] = existing
        }
        var entry = entries[server.id] ?? Entry(configuration: server)
        if let until = entry.coolingUntil, until > clock() {
            throw MCPManagerError.coolingDown(server.name, until)
        }
        if entry.connection != nil {
            entry.lastUsed = clock()
            entries[server.id] = entry
            return entry
        }
        do {
            let connection = try await connector(server)
            let definitions: [[String: Any]]
            do { definitions = try await connection.toolDefinitions() } catch {
                await connection.close()
                throw error
            }
            entry.connection = connection
            entry.tools = definitions.compactMap { Self.info($0, server: server.name) }.filter { server.allows(tool: $0.name) }
            entry.failures = 0
            entry.coolingUntil = nil
            entry.lastError = nil
            entry.lastUsed = clock()
            entries[server.id] = entry
            return entry
        } catch {
            entry.failures += 1
            entry.lastError = String(error.localizedDescription.prefix(300))
            if entry.failures >= Self.failureThreshold {
                entry.coolingUntil = clock().addingTimeInterval(Self.coolDown)
                entry.failures = 0
            }
            entries[server.id] = entry
            throw MCPManagerError.connectionFailed(server.name, entry.lastError ?? "")
        }
    }

    /// Fields that require a new session when edited; timestamps and trust do not.
    static func sameSession(_ lhs: MCPServerConfiguration, _ rhs: MCPServerConfiguration) -> Bool {
        lhs.name == rhs.name && lhs.transport == rhs.transport && lhs.command == rhs.command &&
            lhs.arguments == rhs.arguments && lhs.url == rhs.url && lhs.secretNames == rhs.secretNames &&
            lhs.includeTools == rhs.includeTools && lhs.excludeTools == rhs.excludeTools
    }

    static func info(_ definition: [String: Any], server: String) -> MCPToolInfo? {
        guard let name = definition["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
              let schema = definition["inputSchema"] as? [String: Any],
              let schemaData = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else { return nil }
        let annotations = definition["annotations"] as? [String: Any] ?? [:]
        return MCPToolInfo(server: server, name: name,
            description: String((definition["description"] as? String ?? "").prefix(2_000)),
            inputSchema: schemaData,
            readOnlyHint: annotations["readOnlyHint"] as? Bool ?? false,
            destructiveHint: annotations["destructiveHint"] as? Bool ?? true)
    }

    @Sendable static func connect(_ server: MCPServerConfiguration) async throws -> any MCPConnection {
        try RuntimePrivacyPolicy.requireNetwork()
        let secrets = MCPSecretStore.values(for: server)
        switch server.transport {
        case .stdio:
            guard let command = server.command else { throw MCPManagerError.disabled(server.name) }
            let client = try PlaywrightMCPClient(server: URL(fileURLWithPath: command), arguments: server.arguments,
                secrets: secrets, workingDirectory: workingDirectory(for: server))
            do {
                try await client.initialize()
            } catch {
                client.stop()
                throw error
            }
            return client
        case .http:
            guard let raw = server.url, let url = URL(string: raw) else { throw MCPManagerError.disabled(server.name) }
            let client = try MCPStreamableHTTPClient(url: url, authorization: secrets["AUTHORIZATION"],
                                                 oauthServerID: server.id, serverName: server.name)
            try await client.initialize()
            return client
        case .sse:
            guard let raw = server.url, let url = URL(string: raw) else { throw MCPManagerError.disabled(server.name) }
            let client = MCPLegacySSEClient(url: url, authorization: secrets["AUTHORIZATION"],
                                            oauthServerID: server.id, serverName: server.name)
            do {
                try await client.initialize()
            } catch {
                await client.close()
                throw error
            }
            return client
        }
    }
}

/// A private directory per server, so relative writes never land in the
/// user's home folder or a project.
private func workingDirectory(for server: MCPServerConfiguration) -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    let directory = support.appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/MCP/\(server.id.uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return directory
}

public enum MCPManagerError: LocalizedError, Equatable {
    case disabled(String), coolingDown(String, Date), connectionFailed(String, String), unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .disabled(let name): "The MCP server \(name) is disabled or misconfigured."
        case .coolingDown(let name, let until): "The MCP server \(name) failed repeatedly and is paused until \(until.formatted(date: .omitted, time: .shortened))."
        case .connectionFailed(let name, let detail): "The MCP server \(name) could not be reached: \(detail)"
        case .unknownTool(let tool): "The MCP tool \(tool) is not offered by this server or is filtered out."
        }
    }
}

/// MCP Streamable HTTP client: JSON or single-response SSE replies, session header.
final class MCPStreamableHTTPClient: MCPConnection, @unchecked Sendable {
    private let client: MCPWebClient
    private let serverName: String
    init(url: URL, authorization: String?, oauthServerID: UUID? = nil, serverName: String = "server",
         session: URLSession = NativeChatTransport.secretSession()) throws {
        // The manager validates MCPServerConfiguration before constructing this adapter.
        self.serverName = serverName
        client = try MCPWebClient(url: url, allowLocalhost: true, session: session, authorization: { refresh in
            if let authorization { return authorization }
            guard let oauthServerID else { return nil }
            return try await MCPOAuth.accessToken(serverID: oauthServerID, forceRefresh: refresh)
        })
    }
    func initialize() async throws {
        do { try await client.initialize() }
        catch MCPWebError.http(401) { throw MCPOAuth.OAuthError.needsSignIn(serverName) }
    }
    func toolDefinitions() async throws -> [[String: Any]] {
        try await client.definitions().map { tool in
            ["name": tool.name, "description": tool.description,
             "inputSchema": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.schema)),
             "annotations": ["readOnlyHint": tool.readOnly]] as [String: Any]
        }
    }
    func call(_ name: String, argumentsJSON: Data) async throws -> Data {
        let arguments = try JSONDecoder().decode(RemoteJSONValue.self, from: argumentsJSON)
        // AgentMCPToolService has already completed the Mac's existing approval path.
        let result = try await client.call(name, arguments: arguments, authorized: true)
        return try JSONEncoder().encode(result)
    }
    func close() async { await client.close() }
}

enum MCPHTTPStatus: Error { case unauthorized(String?) }

enum MCPJSONRPC {
    /// JSON-RPC ids may come back as numbers or numeric strings.
    static func id(of object: [String: Any]) -> Int? {
        if let number = object["id"] as? NSNumber { return number.intValue }
        if let text = object["id"] as? String { return Int(text) }
        return nil
    }
}

/// The 2024-11-05 HTTP+SSE transport still used by many hosted MCP servers: a
/// long-lived GET event stream announces a POST endpoint (`event: endpoint`);
/// replies arrive on the stream as `message` events.
final class MCPLegacySSEClient: MCPConnection, @unchecked Sendable {
    private let url: URL
    private let authorization: String?
    private let oauthServerID: UUID?
    private let serverName: String
    private let session: URLSession
    private let lock = NSLock()
    private var endpoint: URL?
    private var endpointWaiters: [CheckedContinuation<URL, Error>] = []
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var nextID = 1
    private var failure: Error?

    init(url: URL, authorization: String?, oauthServerID: UUID? = nil, serverName: String = "server",
         session: URLSession = RuntimeManagedNetworkSession.make(configuration: .ephemeral)) {
        self.url = url
        self.authorization = authorization
        self.oauthServerID = oauthServerID
        self.serverName = serverName
        self.session = session
    }

    private func bearer() async throws -> String? {
        if let authorization { return authorization.hasPrefix("Bearer ") ? authorization : "Bearer \(authorization)" }
        guard let oauthServerID else { return nil }
        return try await MCPOAuth.accessToken(serverID: oauthServerID).map { "Bearer \($0)" }
    }

    func initialize() async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60 * 60 * 24)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let bearer = try await bearer() { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaywrightError.invalidResponse }
        if http.statusCode == 401 {
            throw authorization == nil ? MCPOAuth.OAuthError.needsSignIn(serverName) : PlaywrightError.toolFailed("HTTP 401")
        }
        guard (200..<300).contains(http.statusCode) else { throw PlaywrightError.toolFailed("HTTP \(http.statusCode)") }
        reader = Task { [weak self] in
            var eventName = "message"
            var data = ""
            do {
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") {
                        // A new event starts: drop any unparseable remainder of the previous one.
                        eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        data = ""
                    } else if line.hasPrefix("data:") {
                        data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        // `lines` drops the blank separator line: dispatch as soon as the data is complete.
                        if self?.dispatch(event: eventName, data: data) == true { eventName = "message"; data = "" }
                    }
                    if data.utf8.count > 16_000_000 { data = "" }
                }
                self?.fail(PlaywrightError.toolFailed("The MCP event stream closed."))
            } catch {
                self?.fail(error)
            }
        }
        let endpoint = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            lock.withLock {
                if let endpoint = self.endpoint { continuation.resume(returning: endpoint) }
                else if let failure { continuation.resume(throwing: failure) }
                else { endpointWaiters.append(continuation) }
            }
        }
        _ = endpoint
        _ = try await rpc("initialize", params: [
            "protocolVersion": "2024-11-05", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "AIM AI", "version": "0.1.0"]])
        try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// Returns true when the event was complete and handled.
    private func dispatch(event: String, data: String) -> Bool {
        if event == "endpoint" {
            guard let resolved = URL(string: data, relativeTo: url)?.absoluteURL,
                  resolved.host == url.host, resolved.scheme == url.scheme else { return true }
            let waiters = lock.withLock { () -> [CheckedContinuation<URL, Error>] in
                endpoint = resolved
                defer { endpointWaiters.removeAll() }
                return endpointWaiters
            }
            waiters.forEach { $0.resume(returning: resolved) }
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return false }
        if let id = MCPJSONRPC.id(of: object), let continuation = lock.withLock({ pending.removeValue(forKey: id) }) {
            continuation.resume(returning: Data(data.utf8))
        }
        return true
    }

    private func fail(_ error: Error) {
        let (waiters, calls) = lock.withLock { () -> ([CheckedContinuation<URL, Error>], [CheckedContinuation<Data, Error>]) in
            failure = error
            defer { endpointWaiters.removeAll(); pending.removeAll() }
            return (endpointWaiters, Array(pending.values))
        }
        waiters.forEach { $0.resume(throwing: error) }
        calls.forEach { $0.resume(throwing: error) }
    }

    private func resolve(_ id: Int, with result: Result<Data, Error>) {
        lock.withLock { pending.removeValue(forKey: id) }?.resume(with: result)
    }

    private func post(_ message: [String: Any]) async throws {
        try await post(body: try JSONSerialization.data(withJSONObject: message))
    }

    private func post(body: Data) async throws {
        guard let endpoint = lock.withLock({ self.endpoint }) else { throw PlaywrightError.invalidResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = try await bearer() { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PlaywrightError.toolFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id: Int = lock.withLock { defer { nextID += 1 }; return nextID }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: message)
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(120))
            self?.resolve(id, with: .failure(PlaywrightError.toolFailed("The MCP server did not answer \(method) in time.")))
        }
        defer { timeout.cancel() }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let failure = lock.withLock { () -> Error? in
                if let failure { return failure }
                pending[id] = continuation
                return nil
            }
            if let failure { continuation.resume(throwing: failure); return }
            Task { [weak self] in
                do { try await self?.post(body: body) } catch { self?.resolve(id, with: .failure(error)) }
            }
        }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlaywrightError.invalidResponse }
        if let error = response["error"] as? [String: Any] {
            throw PlaywrightError.toolFailed(String(describing: error["message"] ?? "MCP error"))
        }
        guard let result = response["result"] as? [String: Any] else { throw PlaywrightError.invalidResponse }
        return result
    }

    func toolDefinitions() async throws -> [[String: Any]] {
        var tools: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<20 {
            let result = try await rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            tools += result["tools"] as? [[String: Any]] ?? []
            guard tools.count <= 500 else { throw PlaywrightError.invalidResponse }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, next != cursor else { return tools }
            cursor = next
        }
        throw PlaywrightError.invalidResponse
    }

    func call(_ name: String, argumentsJSON: Data) async throws -> Data {
        guard let arguments = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw PlaywrightError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: try await rpc("tools/call", params: ["name": name, "arguments": arguments]))
    }

    func close() async {
        reader?.cancel()
        fail(CancellationError())
    }
}
