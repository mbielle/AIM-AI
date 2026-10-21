import AIMApplication
import Foundation

/// Only trusted host executors export state or reconcile an effect.
public protocol DurableToolExecutor: ToolExecutor, AnyObject {
    func exportToolState() async throws -> Data
    func restoreToolState(_ data: Data, workspacePath: String?) async throws
    func recoveryPolicy(for name: String) -> ToolRecoveryPolicy
    func reconcile(_ call: ModelToolCall, workspacePath: String?) async throws -> ModelToolOutput?
}
