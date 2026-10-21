import AIMAgentKit
import AIMApplication
import Foundation

actor ContinuityWakeTools: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["wait_for_event"]
    let scheduler: SQLiteSchedulerRepository?
    let context: RuntimeExecutionContext?
    init(scheduler: SQLiteSchedulerRepository?, context: RuntimeExecutionContext? = nil) { self.scheduler = scheduler; self.context = context }
    func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard request.name == "wait_for_event", let kind = request.arguments["kind"].flatMap(WakeCondition.Kind.init(rawValue:)) else { throw ExecutionStoreError.invalidTransition }
            var key = request.arguments["key"] ?? "", metadata = ["expected_wait": "true", "wait_condition": "system_event", "wake_kind": kind.rawValue]
            switch kind {
            case .deadline:
                guard let date = ISO8601DateFormatter().date(from: key), date > .now else { throw ExecutionStoreError.invalidTransition }
                metadata["wake_due"] = String(date.timeIntervalSince1970)
            case .folder:
                guard let workspace = request.workspacePath else { throw ExecutionStoreError.invalidTransition }
                let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
                let url = key.hasPrefix("/") ? URL(fileURLWithPath: key) : URL(fileURLWithPath: root).appending(path: key)
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == root || resolved.hasPrefix(root + "/") else { throw ExecutionStoreError.invalidTransition }
                key = resolved
                metadata["wake_baseline"] = try await Task.detached(priority: .utility) { try WakeFingerprint.fileSystem(resolved) }.value
            case .network: key = "connectivity"
            case .desktop: key = "unlocked"
            case .process:
                if let id = UUID(uuidString: key), let context,
                   let process = try await context.repository.processes(executionID: context.executionID).first(where: { $0.id == id }) {
                    guard process.state != "unknown" else { throw ExecutionStoreError.invalidTransition }
                    key = id.uuidString; metadata["wake_baseline"] = "durable_handle"
                } else {
                    guard let baseline = await WakeFingerprint.process(key) else { throw ExecutionStoreError.invalidTransition }
                    metadata["wake_baseline"] = baseline
                }
            case .script, .webhook, .mail:
                guard let id = UUID(uuidString: key), let task = try await scheduler?.task(id: id),
                      [.enabled, .running].contains(task.state), let trigger = task.spec?.trigger else { throw ExecutionStoreError.invalidTransition }
                switch (kind, trigger) {
                case (.script, .scriptResultChanged), (.webhook, .webhook), (.mail, .newMail): break
                default: throw ExecutionStoreError.invalidTransition
                }
                key = id.uuidString
                metadata["wake_baseline"] = String(Date.now.timeIntervalSince1970)
            case .subagent, .user: throw ExecutionStoreError.invalidTransition
            }
            metadata["wake_key"] = key
            return ToolResult(requestID: request.id, content: "System wait admitted; no model requests are needed until the condition changes.", metadata: metadata)
        } catch {
            return ToolResult(requestID: request.id, content: "Wait refused. Use a future ISO-8601 deadline, a selected-workspace file/folder, an observed application's PID, network/desktop, or an existing enabled script/mail/webhook task ID.", isError: true)
        }
    }
    func cancel(requestID: String) async {}
}
