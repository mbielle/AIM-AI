import AIMApplication
import Foundation

public actor AgentPlanToolService: ToolExecutor, DurableToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["update_plan"]
    private let repository: any AgentPlanRepository
    private let conversationID: UUID
    private let onUpdate: @Sendable (AgentPlan) -> Void

    public init(repository: any AgentPlanRepository, conversationID: UUID,
                onUpdate: @escaping @Sendable (AgentPlan) -> Void) {
        self.repository = repository; self.conversationID = conversationID; self.onUpdate = onUpdate
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard request.name == "update_plan", let steps = Self.validatedSteps(request.arguments["steps"]) else {
            return ToolResult(requestID: request.id, content: "Send a JSON array of 1–15 steps with title and todo/doing/done status; at most one step may be doing.", isError: true)
        }
        let plan = AgentPlan(conversationID: conversationID, steps: steps)
        do {
            try await repository.save(plan)
            onUpdate(plan)
            var notes: [String] = []
            let unchecked = steps.filter { $0.status != .done && ($0.doneWhen ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            if !unchecked.isEmpty {
                notes.append("Steps without done_when (how you will know they are finished): " +
                    unchecked.prefix(5).map { "“\($0.title)”" }.joined(separator: ", ") + ". Add a concrete check where possible.")
            }
            let finished = steps.filter { $0.status == .done && !($0.doneWhen ?? "").isEmpty }
            if !finished.isEmpty {
                notes.append("Marked done — make sure you actually verified: " +
                    finished.suffix(3).map { "\($0.title): \($0.doneWhen!)" }.joined(separator: "; ") + ".")
            }
            return ToolResult(requestID: request.id, content: (["Plan saved with \(steps.count) steps."] + notes).joined(separator: " "),
                metadata: ["action_outcome": "confirmed"])
        } catch {
            return ToolResult(requestID: request.id, content: "The plan could not be saved; the previous plan is unchanged.", isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    private struct State: Codable { let version: Int; let conversationID: UUID }
    public func exportToolState() throws -> Data {
        try JSONEncoder().encode(State(version: 1, conversationID: conversationID))
    }
    public func restoreToolState(_ data: Data, workspacePath: String?) throws {
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == 1, state.conversationID == conversationID else {
            throw ExecutionStoreError.incompatibleCheckpoint
        }
    }
    public nonisolated func recoveryPolicy(for name: String) -> ToolRecoveryPolicy {
        name == "update_plan" ? .reconcile : .neverReplay
    }
    public func reconcile(_ call: ModelToolCall, workspacePath: String?) async throws -> ModelToolOutput? {
        guard call.name == "update_plan", let steps = Self.validatedSteps(call.arguments["steps"]),
              let plan = try await repository.load(conversationID: conversationID),
              plan.conversationID == conversationID, plan.steps == steps else { return nil }
        onUpdate(plan)
        return ModelToolOutput(id: call.id, content: "Previously saved plan confirmed with \(steps.count) steps.",
            isError: false, metadata: ["reconciled_by": "persisted_conversation_plan", "action_outcome": "confirmed"])
    }
    private nonisolated static func validatedSteps(_ raw: String?) -> [AgentPlanStep]? {
        guard let raw, raw.utf8.count <= 12_000,
              let steps = try? JSONDecoder().decode([AgentPlanStep].self, from: Data(raw.utf8)),
              (1...15).contains(steps.count), steps.filter({ $0.status == .doing }).count <= 1,
              steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.title.contains("\0") && $0.title.utf8.count <= 200 &&
                  ($0.doneWhen?.utf8.count ?? 0) <= 600 && $0.doneWhen?.contains("\0") != true }) else { return nil }
        return steps
    }
}
