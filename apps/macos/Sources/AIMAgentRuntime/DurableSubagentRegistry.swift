import Foundation

/// Lifetimes belong to the runtime driver across parent turns and subscribers.
package actor DurableSubagentRegistry {
    private var pools: [UUID: AgentSubagentPool] = [:]
    private var roots: [UUID: UUID] = [:]
    func pool(context: RuntimeExecutionContext, parentChildID: UUID? = nil, create: @Sendable () -> AgentSubagentPool) async throws -> AgentSubagentPool {
        let key = parentChildID ?? context.executionID
        if let pool = pools[key] { try await pool.restoreChildren(); return pool }
        let pool = create(); pools[key] = pool; roots[key] = context.executionID
        try await pool.restoreChildren(); return pool
    }
    private func owned(_ id: UUID) -> [AgentSubagentPool] { roots.filter { $0.value == id }.compactMap { pools[$0.key] } }
    func pending(_ id: UUID) async -> Bool { for pool in owned(id) { if await pool.hasPendingChildren { return true } }; return false }
    func spendingPaused(_ id: UUID) async -> Bool { for pool in owned(id) { if await pool.hasSpendingPausedChildren { return true } }; return false }
    func blocked(_ id: UUID) async -> Bool { for pool in owned(id) { if await pool.hasBlockedChildren { return true } }; return false }
    func suspend(_ id: UUID) async { for pool in owned(id) { await pool.suspendChildren() } }
    func quiesce(_ id: UUID) async { for pool in owned(id) { await pool.quiesceChildren() } }
    func cancel(_ id: UUID) async {
        let keys = roots.filter { $0.value == id }.map(\.key)
        for key in keys { await pools[key]?.close(); pools.removeValue(forKey: key); roots.removeValue(forKey: key) }
    }
    func cancelDescendants(_ childID: UUID, context: RuntimeExecutionContext) async throws {
        let records = try await context.repository.children(parentExecutionID: context.executionID)
        var branch: Set<UUID> = [childID]
        var previousCount = 0
        while previousCount != branch.count {
            previousCount = branch.count
            for record in records where record.parentChildID.map(branch.contains) == true { branch.insert(record.id) }
        }
        for key in Array(pools.keys) where key != context.executionID && branch.contains(key) {
            await pools[key]?.close(); pools.removeValue(forKey: key); roots.removeValue(forKey: key)
        }
        for record in records where record.id != childID && branch.contains(record.id) {
            let current = try await context.repository.child(record.id)
            if !current.state.isTerminal {
                _ = try await context.repository.transitionChild(current.id, owner: context.owner,
                    expectedRevision: current.revision, to: .cancelled, result: "Ancestor cancelled; descendant stopped.")
            }
        }
    }
    func tick() async throws { for pool in Array(pools.values) { try await pool.tick() } }
    /// The person stops one child; nil when a pool of this execution accepted the request.
    func cancelChild(_ executionID: UUID, childID: UUID) async -> String? {
        var problem = "Unknown sub-agent ID."
        for pool in owned(executionID) {
            guard let result = await pool.cancelJob(childID, reason: "Cancelled by you.") else { return nil }
            if result != "Unknown sub-agent ID." { problem = result }
        }
        return problem
    }
}
