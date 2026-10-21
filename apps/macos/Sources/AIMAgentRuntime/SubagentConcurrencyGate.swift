import Foundation

/// Shared across all root pools in the owning process. Queueing never calls a model.
package actor SubagentConcurrencyGate {
    package static let shared = SubagentConcurrencyGate()
    private var limit = 3
    private var active: Set<UUID> = []
    package func configure(_ maximum: Int) { limit = max(1, maximum) }
    func acquire() async throws -> UUID {
        while true {
            try Task.checkCancellation()
            if active.count < limit {
                let id = UUID(); active.insert(id); return id
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func release(_ id: UUID) { active.remove(id) }
}
