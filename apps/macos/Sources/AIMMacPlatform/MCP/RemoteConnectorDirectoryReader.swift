import AIMCore
import Foundation

/// Called only after the Remote host has authenticated and admitted the settings read.
/// Listing observes saved configurations and existing sessions; it never connects or runs tools.
public enum RemoteConnectorDirectoryReader {
    public static func result(repository: any MCPServerRepository, manager: MCPServerManager = .shared) async throws -> RemoteJSONValue {
        let servers = try await repository.list()
        var descriptors: [ConnectorDescriptor] = []
        for server in servers {
            let current = await manager.status(of: server)
            let status: ConnectorDescriptor.Status
            var count: Int?
            if !server.enabled { status = .disabled }
            else {
                switch current {
                case .idle: status = .saved
                case .connected(let tools): status = .connected; count = tools
                case .coolingDown, .failed: status = .unavailable
                }
            }
            descriptors.append(.init(id: server.id, name: server.displayName,
                identity: server.connectorID ?? server.name, transport: server.transport.rawValue, status: status, toolCount: count))
        }
        return try RemoteConnectorDirectory(connectors: descriptors).json
    }
}
