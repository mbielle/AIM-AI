import Foundation

/// Display-only account metadata. Never serializes server configuration or credentials.
public struct ConnectorDescriptor: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case saved, connected, disabled, unavailable }
    public var id: UUID
    public var name: String
    public var identity: String
    public var transport: String
    public var status: Status
    public var toolCount: Int?
    public init(id: UUID, name: String, identity: String, transport: String, status: Status, toolCount: Int? = nil) {
        self.id = id; self.name = name; self.identity = identity; self.transport = transport; self.status = status; self.toolCount = toolCount
    }
}

public struct RemoteConnectorDirectory: Codable, Equatable, Sendable {
    public var section: String = "connectors"
    public var version: Int = 1
    public var connectors: [ConnectorDescriptor]
    public init(connectors: [ConnectorDescriptor]) { self.connectors = connectors }
    public var json: RemoteJSONValue {
        get throws { try JSONDecoder().decode(RemoteJSONValue.self, from: JSONEncoder().encode(self)) }
    }
    public init(json: RemoteJSONValue) throws {
        let value = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(json))
        guard value.section == "connectors", value.version == 1 else { throw RemoteSecurityServiceError.invalidResponse }
        self = value
    }
}
