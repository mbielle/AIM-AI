import Foundation

public enum MCPWebError: LocalizedError { case invalidResponse, unsupportedTransport, approvalRequired, http(Int)
    public var errorDescription: String? { switch self { case .invalidResponse: "The connector returned an invalid response."; case .unsupportedTransport: "This connector requires the Mac or another supported transport."; case .approvalRequired: "Confirm this connector action before running it."; case .http(let code): "The connector refused the request (HTTP \(code))." } }
}
public struct MCPWebTool: Codable, Identifiable, Sendable {
    public let name: String
    public let description: String
    public let schema: RemoteJSONValue
    public let readOnly: Bool
    public var id: String { name }
}

/// Portable Streamable HTTP transport. Authorization belongs to this device;
/// the server's tool annotations never authorize an action by themselves.
public actor MCPWebClient {
    private let url: URL
    private let session: URLSession
    private let ownsSession: Bool
    private var closed = false
    private var operations: [UUID: Task<RemoteJSONValue?, Error>] = [:]
    private let authorization: @Sendable (Bool) async throws -> String?
    private var sessionID: String?
    private var version = "2025-06-18"
    public init(url: URL, allowLocalhost: Bool = false, session: URLSession? = nil,
                authorization: @escaping @Sendable (Bool) async throws -> String? = { _ in nil }) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.fragment == nil,
              c.scheme == "https" || (allowLocalhost && c.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(c.host ?? "")) else { throw MCPWebError.unsupportedTransport }
        self.url = url; self.authorization = authorization; ownsSession = session == nil
        self.session = session ?? NativeChatTransport.secretSession()
    }
    public func initialize() async throws {
        let result = try await rpc("initialize", params: .object(["protocolVersion": .string(version), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("AIM"), "version": .string("1.0")])]))
        guard let negotiated = result.objectValue?["protocolVersion"]?.stringValue,
              ["2025-06-18", "2025-03-26", "2024-11-05"].contains(negotiated) else { throw MCPWebError.invalidResponse }
        version = negotiated
        _ = try await perform(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), id: nil)
    }
    public func definitions() async throws -> [MCPWebTool] {
        var tools: [MCPWebTool] = [], cursor: String?, seen = Set<String>()
        for _ in 0..<20 {
            let result = try await rpc("tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
            guard let object = result.objectValue, let rows = object["tools"]?.arrayValue else { throw MCPWebError.invalidResponse }
            for row in rows {
                guard let fields = row.objectValue, let name = fields["name"]?.stringValue, !name.isEmpty,
                      name.utf8.count <= 256, let schema = fields["inputSchema"], schema.objectValue != nil else { throw MCPWebError.invalidResponse }
                tools.append(.init(name: name, description: fields["description"]?.stringValue ?? "", schema: schema, readOnly: fields["annotations"]?.objectValue?["readOnlyHint"]?.boolValue == true))
            }
            guard tools.count <= 500 else { throw MCPWebError.invalidResponse }
            guard let next = object["nextCursor"]?.stringValue, !next.isEmpty else { return tools }
            guard seen.insert(next).inserted else { throw MCPWebError.invalidResponse }; cursor = next
        }
        throw MCPWebError.invalidResponse
    }
    public func call(_ name: String, arguments: RemoteJSONValue, authorized: Bool) async throws -> RemoteJSONValue {
        guard authorized else { throw MCPWebError.approvalRequired }
        guard arguments.objectValue != nil, !name.isEmpty, name.utf8.count <= 256 else { throw MCPWebError.invalidResponse }
        return try await rpc("tools/call", params: .object(["name": .string(name), "arguments": arguments]))
    }
    public func close() async {
        closed = true
        let pending = Array(operations.values)
        for task in pending { task.cancel() }
        if ownsSession { session.invalidateAndCancel() }
        for task in pending { _ = try? await task.value }
        guard let sessionID else { return }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let auth = try? await authorization(false) { request.setValue(auth.hasPrefix("Bearer ") ? auth : "Bearer " + auth, forHTTPHeaderField: "Authorization") }
        if !AIMNetworkPrivacyPolicy.isEnabled {
            let cleanup = NativeChatTransport.secretSession()
            _ = try? await cleanup.data(for: request); cleanup.invalidateAndCancel()
        }
        self.sessionID = nil
    }
    private func rpc(_ method: String, params: RemoteJSONValue) async throws -> RemoteJSONValue {
        let id = UUID().uuidString
        let body: RemoteJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])
        let response = try await perform(body, id: id)
        guard let object = response?.objectValue, object["error"] == nil, let result = object["result"] else { throw MCPWebError.invalidResponse }
        return result
    }
    private func perform(_ body: RemoteJSONValue, id: String?) async throws -> RemoteJSONValue? {
        guard !closed else { throw CancellationError() }
        let operationID = UUID()
        let task = Task {
            do { return try await self.send(body, id: id, refresh: false) }
            catch MCPWebError.http(401) { return try await self.send(body, id: id, refresh: true) }
        }
        operations[operationID] = task
        defer { operations[operationID] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func send(_ body: RemoteJSONValue, id: String?, refresh: Bool) async throws -> RemoteJSONValue? {
        try AIMNetworkPrivacyPolicy.requireNetwork(); try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let bearer = try await authorization(refresh) {
            guard !bearer.contains("\n"), !bearer.contains("\r"), !bearer.contains("\0") else { throw MCPWebError.invalidResponse }
            request.setValue(bearer.hasPrefix("Bearer ") ? bearer : "Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPWebError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MCPWebError.http(http.statusCode) }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id"), assigned.utf8.count <= 1024 { sessionID = assigned }
        guard let id else { return nil }
        let isSSE = http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
        var buffer = Data(), line = Data(), event: [String] = []
        func decode(_ data: Data) throws -> RemoteJSONValue? {
            let response = try JSONDecoder().decode(RemoteJSONValue.self, from: data)
            guard response.objectValue?["jsonrpc"] == .string("2.0") else { throw MCPWebError.invalidResponse }
            return response.objectValue?["id"] == .string(id) ? response : nil
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte); guard buffer.count <= 4_194_304 else { throw MCPWebError.invalidResponse }
            if isSSE {
                if byte == 10 {
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines); line.removeAll(keepingCapacity: true)
                    if text.isEmpty, !event.isEmpty {
                        if let response = try decode(Data(event.joined(separator: "\n").utf8)) { return response }
                        event.removeAll(keepingCapacity: true)
                    } else if text.hasPrefix("data:") { var text = String(text.dropFirst(5)); if text.hasPrefix(" ") { text.removeFirst() }; event.append(text) }
                } else { line.append(byte) }
            }
        }
        if isSSE {
            if !event.isEmpty, let response = try decode(Data(event.joined(separator: "\n").utf8)) { return response }
            throw MCPWebError.invalidResponse
        }
        guard let response = try decode(buffer) else { throw MCPWebError.invalidResponse }; return response
    }
}
