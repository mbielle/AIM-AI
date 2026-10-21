import AIMAgentKit
import AIMApplication
import AIMCore
import CryptoKit
import Foundation

/// An external engine's own sub-agents (Hermes `delegate_task`, OpenClaw `sessions_spawn`) shown
/// like AIM's: one durable child per sub-agent under the task, with its journal (text, reasoning,
/// actions) for the Sub-agents panel. Observations only: the engine runs its children itself.
package actor ExternalSubagentTracker {
    private let context: RuntimeExecutionContext
    private let request: AgentRequest
    private var children: [String: DurableSubagent] = [:]
    private var order = 0
    package init(context: RuntimeExecutionContext, request: AgentRequest) { self.context = context; self.request = request }

    /// A stable child ID per engine sub-agent within this task.
    static func childID(executionID: UUID, origin: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data((executionID.uuidString + ":" + origin).utf8)))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], (hash[6] & 0x0f) | 0x50, hash[7],
                           (hash[8] & 0x3f) | 0x80, hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    @discardableResult
    package func started(_ origin: String, title: String?, prompt: String?) async -> UUID? {
        if let child = children[origin] { return child.id }
        let id = Self.childID(executionID: context.executionID, origin: origin)
        order += 1
        let goal = String((prompt ?? title ?? "Sub-agent").prefix(15_000))
        let name = String((title?.isEmpty == false ? title! : goal).split(separator: "\n").first.map(String.init)?.prefix(100) ?? "Sub-agent \(order)")
        var proposal = DurableSubagent(id: id, parentExecutionID: context.executionID, admissionCallID: "external:" + String(origin.prefix(200)),
            title: name, prompt: goal, workspacePath: request.workspacePath ?? "/", modelID: request.modelID,
            profile: "external", worktree: nil)
        proposal.providerID = request.provider?.rawValue
        do {
            var child = try await context.repository.admitChild(proposal, owner: context.owner)
            child = try await context.repository.transitionChild(child.id, owner: context.owner, expectedRevision: child.revision, to: .running)
            children[origin] = child
            return child.id
        } catch { return nil }
    }

    package func journal(_ origin: String, _ kind: SubagentJournalEntry.Kind, text: String? = nil, callID: String? = nil,
                         name: String? = nil, isError: Bool? = nil, streamed: Bool? = nil) async {
        guard let id = await started(origin, title: nil, prompt: nil),
              let payload = try? JSONEncoder().encode(SubagentJournalEntry(childID: id, kind: kind, text: text, callID: callID,
                                                                           name: name, isError: isError, streamed: streamed)) else { return }
        try? await context.repository.recordEvent(context.executionID, owner: context.owner, kind: SubagentJournalEntry.eventKind, payload: payload)
    }

    package func finished(_ origin: String, failed: Bool, result: String?) async {
        guard let child = children[origin] else { return }
        let updated = try? await context.repository.transitionChild(child.id, owner: context.owner, expectedRevision: child.revision,
            to: failed ? .failed : .accepted, result: result.map { String($0.prefix(400_000)) })
        children[origin] = updated ?? child
    }

    /// When the engine's turn ends, children it never reported as finished are closed.
    package func closeAll(cancelled: Bool) async {
        for (origin, child) in children where !child.state.isTerminal {
            let latest = (try? await context.repository.child(child.id)) ?? child
            guard !latest.state.isTerminal else { continue }
            let updated = try? await context.repository.transitionChild(latest.id, owner: context.owner, expectedRevision: latest.revision,
                to: cancelled ? .cancelled : .accepted, result: latest.result ?? (cancelled ? "Stopped with the task." : nil))
            children[origin] = updated ?? latest
        }
    }
}

/// One writer at a time for an external turn's checkpoint: the engine's calls (and its
/// sub-agents') run side by side, and each update reads, changes and saves the same record.
package actor AsyncSerialLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    package init() {}
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    package func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do { let value = try await body(); release(); return value }
        catch { release(); throw error }
    }
}
