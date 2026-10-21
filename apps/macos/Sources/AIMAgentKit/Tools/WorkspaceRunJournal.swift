import AIMApplication
import Foundation

/// Saves audit records before tool dispatch and before returning results to the model.
/// Raw provider payloads, keys and private reasoning are never stored here.
public struct WorkspaceRunJournal: Sendable {
    private let repository: any WorkspaceRunRepository
    private let run: WorkspaceRun
    public init(repository: any WorkspaceRunRepository, run: WorkspaceRun) {
        self.repository = repository; self.run = run
    }
    func start() async throws {
        do { try await repository.begin(run) } catch { throw WorkspaceHistoryError.persistence }
    }
    func requested(_ call: ModelToolCall, ordinal: Int) async throws {
        do { try await repository.requested(WorkspaceCall(runID: run.id, ordinal: ordinal, call: call)) }
        catch { throw WorkspaceHistoryError.persistence }
    }
    func returned(_ output: ModelToolOutput) async throws {
        do { try await repository.returned(runID: run.id, output: output) }
        catch { throw WorkspaceHistoryError.persistence }
    }
    func launched(_ callID: String) async throws {
        do { try await repository.launched(runID: run.id, callID: callID) }
        catch { throw WorkspaceHistoryError.persistence }
    }
    func finish(_ state: WorkspaceRunState) async throws {
        do { try await repository.finish(runID: run.id, state: state) }
        catch { throw WorkspaceHistoryError.persistence }
    }
}
