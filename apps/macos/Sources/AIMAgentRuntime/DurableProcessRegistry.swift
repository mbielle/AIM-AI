import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

/// The runtime owns process handles across turns. A crashed process is observed
/// as unknown, never started again from its old command text.
package actor DurableProcessRegistry {
    private var services: [UUID: RuntimeShellService] = [:]
    func service(context: RuntimeExecutionContext, workspace: String) async throws -> RuntimeShellService {
        if let service = services[context.executionID] { try await service.restore(); return service }
        let service = RuntimeShellService(context: context, workspace: workspace)
        try await service.restore(); services[context.executionID] = service; return service
    }
    func tick() async throws {
        for (id, service) in services {
            if try await service.context.repository.execution(id)?.state.isTerminal != false {
                await service.stop(); services.removeValue(forKey: id)
            } else { try await service.persist() }
        }
    }
    func stop(_ id: UUID) async { await services[id]?.stop(); services.removeValue(forKey: id) }
    func uncertain(_ id: UUID) async -> Bool { await services[id]?.hasUncertainProcess() ?? false }
    func pending(_ id: UUID) async throws -> UUID? { try await services[id]?.pendingProcess() }
}

actor RuntimeShellService: ToolExecutor, ToolRiskClassifying, ToolPreflighting, ToolReviewProviding, ToolSessionClosing, DurableToolExecutor {
    nonisolated let shell = WorkspaceShellToolService()
    nonisolated var supportedTools: Set<String> { shell.supportedTools }
    let context: RuntimeExecutionContext
    let workspace: String
    private var admissions: [UUID: String] = [:]
    private var persistedVersions: [UUID: Int] = [:]
    init(context: RuntimeExecutionContext, workspace: String) { self.context = context; self.workspace = workspace }
    nonisolated func risk(for arguments: [String: String]) -> ToolRisk { shell.risk(for: arguments) }
    nonisolated func risk(for name: String, arguments: [String: String]) -> ToolRisk { shell.risk(for: name, arguments: arguments) }
    nonisolated func preflightRefusal(_ request: ToolRequest) -> String? { shell.preflightRefusal(request) }
    func review(_ request: ToolRequest) async throws -> ToolReview? { try await shell.review(request) }
    func execute(_ request: ToolRequest) async -> ToolResult {
        guard request.workspacePath == workspace else { return ToolResult(requestID: request.id, content: "Process workspace mismatch.", isError: true) }
        if request.name == "start_command", let existing = admissions.first(where: { $0.value == request.id }) {
            return ToolResult(requestID: request.id, content: "Existing process handle \(existing.key). Read its receipt; never restart it blindly.",
                metadata: ["process_handle": existing.key.uuidString])
        }
        let result = await shell.execute(request)
        if request.name == "start_command", let id = result.metadata["process_handle"].flatMap(UUID.init(uuidString:)) { admissions[id] = request.id }
        do { try await persist() }
        catch { return ToolResult(requestID: request.id, content: "Process receipt could not be saved. Its effects may have occurred; reconciliation is required.", isError: true) }
        return result
    }
    func restore() async throws {
        let records = try await context.repository.processes(executionID: context.executionID)
        guard records.allSatisfy({ $0.workspacePath == workspace }) else { throw ExecutionStoreError.incompatibleCheckpoint }
        admissions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.admissionCallID) })
        persistedVersions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.version) })
        try await shell.restoreDurableSnapshots(records.map {
            var snapshot = try JSONDecoder().decode(WorkspaceShellToolService.DurableSnapshot.self, from: $0.payload)
            // Human acknowledgement changes the trusted row, never fabricates success/output.
            snapshot.state = $0.state; snapshot.version = $0.version
            return snapshot
        })
        try await persist()
    }
    func persist() async throws {
        for snapshot in try await shell.durableSnapshots() {
            guard let call = admissions[snapshot.id], persistedVersions[snapshot.id] != snapshot.version else { continue }
            try await context.repository.saveProcess(DurableProcess(id: snapshot.id, executionID: context.executionID,
                admissionCallID: call, workspacePath: workspace, state: snapshot.state, version: snapshot.version,
                payload: JSONEncoder().encode(snapshot)), owner: context.owner)
            persistedVersions[snapshot.id] = snapshot.version
        }
    }
    func hasUncertainProcess() async -> Bool { (try? await shell.durableSnapshots().contains { $0.state == "unknown" }) ?? true }
    func pendingProcess() async throws -> UUID? { try await shell.durableSnapshots().first { $0.state == "running" }?.id }
    func cancel(requestID: String) async { await shell.stopForRuntime(); try? await persist() }
    func stop() async { await shell.stopForRuntime(); try? await persist() }
    // Dispatcher release ends a turn, not the processes owned by the runtime.
    func closeSession() async {}
    nonisolated func recoveryPolicy(for name: String) -> ToolRecoveryPolicy { name == "read_command" ? .readOnly : name == "start_command" ? .reconcile : .neverReplay }
    func reconcile(_ call: ModelToolCall, workspacePath: String?) async throws -> ModelToolOutput? {
        guard call.name == "start_command", workspacePath == workspace,
              let id = admissions.first(where: { $0.value == call.id })?.key,
              let snapshot = try await shell.durableSnapshots().first(where: { $0.id == id }), snapshot.state != "unknown" else { return nil }
        return ModelToolOutput(id: call.id, content: "Durable process handle \(id), state \(snapshot.state). Read its receipt before acting.", isError: false,
            metadata: ["process_handle": id.uuidString, "process_state": snapshot.state, "reconciled_by": "durable_process_receipt"])
    }
    func exportToolState() async throws -> Data {
        try JSONEncoder().encode(["version": "1", "executionID": context.executionID.uuidString, "workspace": workspace,
            "environment": try await shell.exportToolState().base64EncodedString()])
    }
    func restoreToolState(_ data: Data, workspacePath: String?) async throws {
        let value = try JSONDecoder().decode([String: String].self, from: data)
        guard value["version"] == "1", value["executionID"] == context.executionID.uuidString,
              value["workspace"] == workspace, workspacePath == workspace else { throw ExecutionStoreError.incompatibleCheckpoint }
        if let encoded = value["environment"] {
            guard let bytes = Data(base64Encoded: encoded) else { throw ExecutionStoreError.incompatibleCheckpoint }
            try await shell.restoreToolState(bytes, workspacePath: workspacePath)
        } else if WorkspaceExecutionEnvironment.isIsolated { throw ExecutionStoreError.incompatibleCheckpoint }
    }
}
