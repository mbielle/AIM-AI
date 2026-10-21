import Foundation

public struct DurableProcess: Codable, Sendable {
    public var id: UUID
    public var executionID: UUID
    public var admissionCallID: String
    public var workspacePath: String
    public var state: String
    public var version: Int
    public var payload: Data
    public init(id: UUID, executionID: UUID, admissionCallID: String, workspacePath: String, state: String, version: Int, payload: Data) {
        self.id = id; self.executionID = executionID; self.admissionCallID = admissionCallID
        self.workspacePath = workspacePath; self.state = state; self.version = version; self.payload = payload
    }
}
