import Foundation
import AIMAgentKit

/// A compact, in-memory view of the current run. The durable journal remains the
/// source for full call arguments and results; this preview never stores them.
struct ToolProgressWindow {
    enum State: Equatable { case running, succeeded, failed, interrupted }
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String?
        let startedAt: Date
        var finishedAt: Date? = nil
        var state: State
        var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
    }

    private(set) var items: [Item] = []
    private(set) var totalStarted = 0
    private(set) var failedCount = 0
    private(set) var didCompact = false
    private(set) var stage: AgentRunStage = .preparingContext
    let startedAt = Date.now
    let visibleLimit = 20

    var omittedCount: Int { max(0, totalStarted - items.count) }

    mutating func start(id: String, name: String, detail: String? = nil, at now: Date = .now) {
        guard !items.contains(where: { $0.id == id }) else { return }
        totalStarted += 1
        items.append(Item(id: id, name: name, detail: detail, startedAt: now, state: .running))
        if items.count > visibleLimit { items.removeFirst(items.count - visibleLimit) }
    }

    mutating func finish(id: String, isError: Bool, at now: Date = .now) {
        guard let index = items.lastIndex(where: { $0.id == id && $0.state == .running }) else { return }
        if isError { failedCount += 1 }
        items[index].state = isError ? .failed : .succeeded
        items[index].finishedAt = now
    }

    mutating func interruptRunning() {
        for index in items.indices where items[index].state == .running {
            items[index].state = .interrupted
            items[index].finishedAt = .now
        }
    }

    mutating func setStage(_ stage: AgentRunStage) { self.stage = stage }
    mutating func markCompacted() { didCompact = true }
}
