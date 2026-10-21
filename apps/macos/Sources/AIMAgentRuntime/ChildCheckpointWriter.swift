import AIMApplication
import Foundation

struct ChildCheckpointWriter: ExecutionCheckpointing {
    let context: RuntimeExecutionContext
    let childID: UUID
    func load() async throws -> ExecutionCheckpoint? { try await context.repository.childCheckpoint(childID) }
    func prepare(_ checkpoint: ExecutionCheckpoint) async throws {
        try await context.repository.saveChildCheckpoint(checkpoint, childID: childID, owner: context.owner)
    }
    func launched(_ callID: String) async throws {
        try await checkBoundary()
        try await context.repository.updateChildEffect(childID: childID, callID: callID, owner: context.owner)
    }
    func returned(_ output: ModelToolOutput) async throws {
        try await context.repository.updateChildEffect(childID: childID, callID: output.id, owner: context.owner, output: output)
    }
    func returned(_ output: ModelToolOutput, toolState: [String: Data]) async throws {
        try await context.repository.updateChildEffect(childID: childID, callID: output.id, owner: context.owner, output: output, toolState: toolState)
    }
    func checkBoundary() async throws {
        guard let parent = try await context.repository.execution(context.executionID),
              [.running, .waitingEvent, .waitingNetwork].contains(parent.state), parent.boundaryPauseReason == nil,
              try await context.repository.child(childID).state == .running else { throw ExecutionBoundaryPause() }
        var current = try await context.repository.child(childID)
        var visited: Set<UUID> = [childID]
        while let ancestorID = current.parentChildID {
            guard visited.insert(ancestorID).inserted else { throw ExecutionStoreError.incompatibleCheckpoint }
            current = try await context.repository.child(ancestorID)
            guard current.parentExecutionID == context.executionID,
                  [.running, .waitingEvent, .waitingNetwork].contains(current.state) else { throw ExecutionBoundaryPause() }
        }
    }
}
