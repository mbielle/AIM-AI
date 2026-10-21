import AIMCore
import Foundation

public extension PendingToolApproval {
    /// A bounded, redacted description shared by native and durable Remote hosts.
    var remoteSummary: String {
        let description: String
        if toolName == "open_app" {
            let target = arguments["app"] ?? arguments["bundle_id"] ?? arguments["name"] ?? "Target not provided"
            let placement = arguments["activate"] == "true" ? "in front" : "in the background"
            description = "Open app · \(target) · \(placement)"
        } else {
            let detail = arguments["path"] ?? arguments["command"] ?? arguments["url"] ?? review?.path ?? ""
            description = toolName + (detail.isEmpty ? "" : " · " + detail)
        }
        return String(ConversationAction.redact(description).prefix(300))
    }
}
