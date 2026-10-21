import Foundation
public struct ScheduledRuntimeAdmission: Sendable {
    public let commandID: UUID
    public let taskID: UUID
    public let conversationID: UUID
    public let claimID: Int64
    public let payload: Data
}
public struct ScheduledRuntimeEvent: Sendable {
    public let id: UUID
    public let taskID: UUID
    public let reason: String
    public let payload: String?
}
