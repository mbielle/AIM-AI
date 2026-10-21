import Foundation
import AIMAgentKit

package struct RuntimeVirtualMachineControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case preview, apply, status, start, stop, privacyQuiesce }
    package var action: Action
    package var configuration: Data?
    package init(action: Action, configuration: Data? = nil) { self.action = action; self.configuration = configuration }
}
extension RuntimeVirtualMachineController {
    package func handleControl(_ data: Data) async throws -> Data {
        guard data.count <= 100_000 else { throw AgentHostTransportError.invalidMessage }
        let request = try JSONDecoder().decode(RuntimeVirtualMachineControl.self, from: data)
        let encoder = JSONEncoder()
        switch request.action {
        case .preview:
            guard let configuration = request.configuration else { throw AgentHostTransportError.invalidMessage }
            return try await encoder.encode(previewConfiguration(configuration))
        case .apply:
            guard let configuration = request.configuration else { throw AgentHostTransportError.invalidMessage }
            return try await encoder.encode(importConfiguration(configuration))
        case .status: return try await encoder.encode(status())
        case .start: return try await encoder.encode(start())
        case .privacyQuiesce:
            await AgentPluginRegistry.shared.stop()
            return try await encoder.encode(privacyQuiesce())
        case .stop: return try await encoder.encode(stop())
        }
    }
}
