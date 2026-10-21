import AppKit
import Foundation

/// Process-wide coordination of background input. One run at a time may act on
/// a target process, and the person at the Mac always has priority: activating
/// the target app after an observation suspends automatic background actions
/// on it until a person approves the next one.
public actor CuaTargetLeaseCoordinator {
    public static let shared = CuaTargetLeaseCoordinator()

    public enum LeaseError: LocalizedError, Equatable {
        case heldByAnotherRun
        public var errorDescription: String? {
            "Another AIM run is already acting on this application in the background. Wait for it to finish."
        }
    }

    private struct Lease {
        let owner: UUID
        var expiresAt: Date
    }

    private var leases: [Int32: Lease] = [:]
    private var lastActivation: [Int32: Date] = [:]
    private var humanConflicts: Set<Int32> = []
    private var monitoring = false
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { .now }) {
        self.clock = clock
    }

    /// Starts tracking app activations (not keystrokes or pointer positions).
    public func startMonitoring() async {
        guard !monitoring else { return }
        monitoring = true
        await MainActor.run { ActivationObserver.install() }
    }

    public func recordActivation(pid: Int32) {
        lastActivation[pid] = clock()
    }

    /// True when the person activated the target since `date`, or a conflict
    /// on it has not yet been cleared by an approved action.
    public func humanInterventionSince(_ date: Date, pid: Int32) -> Bool {
        if humanConflicts.contains(pid) { return true }
        guard let activated = lastActivation[pid] else { return false }
        return activated >= date
    }

    public func markHumanConflict(pid: Int32) { humanConflicts.insert(pid) }
    public func clearHumanConflict(pid: Int32) { humanConflicts.remove(pid) }
    public func hasHumanConflict(pid: Int32) -> Bool { humanConflicts.contains(pid) }

    public func acquire(pid: Int32, owner: UUID, ttl: TimeInterval = 30) throws {
        let now = clock()
        if let lease = leases[pid], lease.owner != owner, lease.expiresAt > now {
            throw LeaseError.heldByAnotherRun
        }
        leases[pid] = Lease(owner: owner, expiresAt: now.addingTimeInterval(ttl))
    }

    public func release(owner: UUID) {
        leases = leases.filter { $0.value.owner != owner }
    }

    public func holder(of pid: Int32) -> UUID? {
        guard let lease = leases[pid], lease.expiresAt > clock() else { return nil }
        return lease.owner
    }
}

@MainActor
private enum ActivationObserver {
    static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { await CuaTargetLeaseCoordinator.shared.recordActivation(pid: pid) }
        }
    }
}
