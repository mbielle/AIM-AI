import Foundation

/// Capacity observations guide new placement; admission on the chosen Mac is
/// authoritative. An existing mission is never moved by this rule.
public struct RemoteWorkerAnnouncement: Codable, Equatable, Sendable {
    public let version: Int
    public let modes: [String]
    public let maximumRoots: Int
    public let runningRoots: Int
    public let queuedRoots: Int
    public let observedAt: Date
    public init(modes: [String], maximumRoots: Int, runningRoots: Int, queuedRoots: Int, observedAt: Date = Date()) {
        version = 1; self.modes = modes; self.maximumRoots = maximumRoots
        self.runningRoots = runningRoots; self.queuedRoots = queuedRoots; self.observedAt = observedAt
    }
    public func isUsable(at date: Date) -> Bool {
        version == 1 && maximumRoots > 0 && runningRoots >= 0 && queuedRoots >= 0
            && date.timeIntervalSince(observedAt) >= -90 && date.timeIntervalSince(observedAt) < 90
    }
}
public struct RemoteWorkerPlacement: Codable, Equatable, Sendable {
    public let version: Int
    public let machineID: String
    public let workspace: String
    public let placedAt: Date
    public init(machineID: String, workspace: String, placedAt: Date = Date()) {
        version = 1; self.machineID = machineID; self.workspace = workspace; self.placedAt = placedAt
    }
}
public enum RemoteWorkerPlacementRules {
    public static func choose(machines: [RemoteMachine], mode: RemoteMode, modelID: String,
        authorizedWorkspaces: [String: String], allowingExperimental: Bool = false, at date: Date = Date()) -> RemoteWorkerPlacement? {
        let eligible = machines.filter { machine in
            guard machine.isOnline(at: date), let capabilities = machine.capabilities,
                  RemoteContinuityRules.supported(capabilities: capabilities, allowingExperimental: allowingExperimental),
                  let worker = capabilities.worker, worker.isUsable(at: date), worker.modes.contains(mode.rawValue),
                  capabilities.models.contains(where: { $0.id == modelID }),
                  let workspace = authorizedWorkspaces[machine.id], workspace.hasPrefix("/"), !workspace.isEmpty else { return false }
            return mode != .chat
        }
        let chosen = eligible.sorted { lhs, rhs in
            let left = lhs.capabilities!.worker!, right = rhs.capabilities!.worker!
            let loadLeft = (Double(left.runningRoots) + Double(left.queuedRoots)) / Double(left.maximumRoots)
            let loadRight = (Double(right.runningRoots) + Double(right.queuedRoots)) / Double(right.maximumRoots)
            if loadLeft != loadRight { return loadLeft < loadRight }
            return lhs.id < rhs.id
        }.first
        guard let chosen, let workspace = authorizedWorkspaces[chosen.id] else { return nil }
        return RemoteWorkerPlacement(machineID: chosen.id, workspace: workspace, placedAt: date)
    }
}
