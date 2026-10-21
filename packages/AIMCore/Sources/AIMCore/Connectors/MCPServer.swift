import Foundation

/// A user-configured MCP server. Secrets are never stored here: only their
/// names, resolved from the Keychain when the server starts.
public struct MCPServerConfiguration: Codable, Equatable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable {
        case stdio, http
        /// Legacy HTTP+SSE (2024-11-05): GET event stream plus a POST endpoint.
        case sse
    }

    public var id: UUID
    /// Stable short name used in tool routing, e.g. `github`.
    public var name: String
    public var transport: Transport
    /// stdio: absolute executable and its arguments.
    public var command: String?
    public var arguments: [String]
    /// http: Streamable HTTP endpoint.
    public var url: String?
    /// Environment variable names (stdio) or `AUTHORIZATION` (http bearer) whose values live in the Keychain.
    public var secretNames: [String]
    /// Legacy display preference only. Server annotations never prove that an action is safe.
    public var trusted: Bool
    public var enabled: Bool
    /// Device-local account label, distinct from the stable routing name.
    public var accountLabel: String?
    public var connectorID: String?
    /// Exceptions can tighten the reviewed default; they cannot authorize unknown writes.
    public var actionPermissions: [String: ConnectorPermissionPolicy.Decision]?
    /// Tool name filters (`*` wildcards). Exclusions win.
    public var includeTools: [String]
    public var excludeTools: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, transport: Transport, command: String? = nil,
                arguments: [String] = [], url: String? = nil, secretNames: [String] = [],
                trusted: Bool = false, enabled: Bool = true, includeTools: [String] = [],
                excludeTools: [String] = [], accountLabel: String? = nil, connectorID: String? = nil,
                actionPermissions: [String: ConnectorPermissionPolicy.Decision]? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.transport = transport; self.command = command
        self.arguments = arguments; self.url = url; self.secretNames = secretNames; self.trusted = trusted
        self.enabled = enabled; self.includeTools = includeTools; self.excludeTools = excludeTools
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.accountLabel = accountLabel; self.connectorID = connectorID; self.actionPermissions = actionPermissions
    }

    public var displayName: String { accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name }

    public static func isValidName(_ name: String) -> Bool {
        (1...40).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public var isValid: Bool {
        guard Self.isValidName(name), (accountLabel?.count ?? 0) <= 120, (connectorID?.count ?? 0) <= 80,
              (actionPermissions?.count ?? 0) <= 500,
              actionPermissions?.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) != false, arguments.count <= 64,
              arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
              secretNames.count <= 16,
              secretNames.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }),
              (includeTools + excludeTools).count <= 100,
              (includeTools + excludeTools).allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else { return false }
        switch transport {
        case .stdio:
            guard let command, command.hasPrefix("/"), command.utf8.count <= 1_024, !command.contains("\0") else { return false }
            return url == nil
        case .http, .sse:
            guard let url, let components = URLComponents(string: url),
                  components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(components.host ?? "")),
                  components.user == nil, components.password == nil else { return false }
            return command == nil
        }
    }

    /// Applies include/exclude filters to a server tool name.
    public func allows(tool: String) -> Bool {
        func matches(_ pattern: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
            return tool.range(of: "^\(escaped)$", options: .regularExpression) != nil
        }
        if excludeTools.contains(where: matches) { return false }
        return includeTools.isEmpty || includeTools.contains(where: matches)
    }
}

public protocol MCPServerRepository: Sendable {
    func list() async throws -> [MCPServerConfiguration]
    func save(_ server: MCPServerConfiguration) async throws
    func delete(id: UUID) async throws
}

/// Parses the common `{"mcpServers": {name: {command, args, env | url, headers}}}`
/// format. Environment values are returned separately for the Keychain.
public enum MCPServerImport {
    public struct Entry: Sendable {
        public let configuration: MCPServerConfiguration
        public let secrets: [String: String]
    }

    public static func parse(_ data: Data, resolveCommand: (String) -> String? = { $0.hasPrefix("/") ? $0 : nil }) throws -> [Entry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = (root["mcpServers"] ?? root["servers"]) as? [String: Any] else {
            throw MCPImportError.unsupportedFormat
        }
        var entries: [Entry] = []
        for (rawName, value) in servers.sorted(by: { $0.key < $1.key }) {
            guard let object = value as? [String: Any] else { throw MCPImportError.invalidServer(rawName) }
            let name = String(rawName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(40))
            var secrets: [String: String] = [:]
            let configuration: MCPServerConfiguration
            if let url = object["url"] as? String {
                if let headers = object["headers"] as? [String: String], let auth = headers["Authorization"] {
                    secrets["AUTHORIZATION"] = auth
                }
                let legacy = (object["type"] as? String ?? object["transport"] as? String)?.lowercased() == "sse"
                    || URL(string: url)?.lastPathComponent == "sse"
                configuration = MCPServerConfiguration(name: name, transport: legacy ? .sse : .http, url: url,
                    secretNames: secrets.keys.sorted())
            } else if let command = object["command"] as? String, let resolved = resolveCommand(command) {
                let environment = object["env"] as? [String: String] ?? [:]
                secrets = environment
                configuration = MCPServerConfiguration(name: name, transport: .stdio, command: resolved,
                    arguments: object["args"] as? [String] ?? [], secretNames: environment.keys.sorted())
            } else {
                throw MCPImportError.invalidServer(rawName)
            }
            guard configuration.isValid else { throw MCPImportError.invalidServer(rawName) }
            entries.append(Entry(configuration: configuration, secrets: secrets))
        }
        return entries
    }
}

public enum MCPImportError: LocalizedError, Equatable {
    case unsupportedFormat, invalidServer(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Expected a JSON object with an \"mcpServers\" map."
        case .invalidServer(let name): "The server \"\(name)\" has an unsupported or unsafe definition (absolute command or HTTPS URL required)."
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
