import AIMApplication
import Foundation

package struct RunCheckpointWriter: ExecutionCheckpointing {
    let repository: SQLiteAgentExecutionRepository
    let executionID: UUID
    let owner: UUID

    package func load() async throws -> ExecutionCheckpoint? { try await repository.checkpoint(executionID) }
    package func pendingUserInputs() async throws -> [ExecutionUserInput] { try await repository.pendingUserInputs(executionID: executionID, owner: owner) }
    package func prepare(_ checkpoint: ExecutionCheckpoint) async throws {
        guard let record = try await repository.execution(executionID) else { throw ExecutionStoreError.notFound }
        _ = try await repository.saveCheckpoint(checkpoint, executionID: executionID, owner: owner, expectedRevision: record.revision)
    }
    package func launched(_ callID: String) async throws {
        try await checkBoundary()
        try await repository.updateEffect(executionID: executionID, callID: callID, owner: owner)
    }
    package func returned(_ output: ModelToolOutput) async throws {
        try await repository.updateEffect(executionID: executionID, callID: output.id, owner: owner, output: output)
    }
    package func returned(_ output: ModelToolOutput, toolState: [String: Data]) async throws {
        try await repository.updateEffect(executionID: executionID, callID: output.id, owner: owner, output: output, toolState: toolState)
    }
    package func checkBoundary() async throws {
        guard let record = try await repository.execution(executionID), record.state == .running else {
            throw ExecutionBoundaryPause()
        }
        if record.boundaryPauseReason != nil { throw ExecutionBoundaryPause() }
    }
}
