import AIMAgentKit
import Foundation

package struct RuntimePluginChannelGrant: Codable, Sendable, Equatable {
    package var version: Int
    package var apiVersion: Int
    package var pluginID: String
    package var pluginVersion: String
    package var configuration: Data
}
package struct RuntimePluginIngress: Codable, Sendable {
    package var version = 1
    package var grant: RuntimeChannelGrant
    /// SDK encoding retains Date precision; never rebuild the event from text.
    package var encodedEvent: Data
    package var hostReceiptID: String
    package var digest: String
    package var disposition: String?
    package var acknowledged = false
    package func event() throws -> AgentChannelEvent { try JSONDecoder().decode(AgentChannelEvent.self, from: encodedEvent) }
    package func receipt() throws -> AgentChannelIngressReceipt {
        guard let disposition else { throw RuntimeChannelError.invalidEvent }
        return AgentChannelIngressReceipt(event: try event(), hostReceiptID: hostReceiptID, digest: digest,
            disposition: disposition == "accepted" ? .accepted : .rejected)
    }
}
