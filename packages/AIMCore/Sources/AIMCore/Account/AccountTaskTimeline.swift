import Foundation

public struct AccountTaskTransition: Sendable, Equatable {
    public enum State: Sendable { case running, waiting, finished }
    public var nodeID: UUID
    public var at: Date
    public var state: State
    public init(nodeID: UUID, at: Date, state: State) { self.nodeID = nodeID; self.at = at; self.state = state }
}

/// Wall-clock completion includes descendants. Parallel waits are counted once, and work by a child
/// prevents a waiting parent from being counted as idle. Missing terminal observations remain unknown.
public struct AccountTaskTimeline: Sendable {
    public let completedAt: Date?
    public let waitingSeconds: TimeInterval
    public init(rootID: UUID, startedAt: Date, nodeIDs: Set<UUID>, transitions: [AccountTaskTransition], now: Date) {
        let nodes = nodeIDs.union([rootID])
        var states: [UUID: AccountTaskTransition.State] = [rootID: .running]
        var finished: [UUID: Date] = [:]
        var previous = startedAt
        var waiting: TimeInterval = 0
        for event in transitions.sorted(by: { $0.at < $1.at }) where nodes.contains(event.nodeID) && event.at >= startedAt && event.at <= now {
            if !states.values.contains(.running), states.values.contains(.waiting) {
                waiting += max(0,event.at.timeIntervalSince(previous))
            }
            // Accepting a previously verified result does not extend its execution time.
            if finished[event.nodeID] == nil {
                states[event.nodeID] = event.state
                if event.state == .finished { finished[event.nodeID] = event.at }
            }
            previous = event.at
        }
        completedAt = nodes.allSatisfy { finished[$0] != nil } ? finished.values.max() : nil
        if completedAt == nil, !states.values.contains(.running), states.values.contains(.waiting) {
            waiting += max(0, now.timeIntervalSince(previous))
        }
        waitingSeconds = waiting
    }
}
