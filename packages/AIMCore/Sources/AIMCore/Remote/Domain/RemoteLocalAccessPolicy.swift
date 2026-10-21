import Foundation

/// Device-local admission gate. Reading account mirror metadata does not authorize a host command.
public final class RemoteLocalAccessPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var suspended: Set<String>
    public init(suspendedMachineIDs: Set<String> = []) { suspended = suspendedMachineIDs }
    public func isSuspended(_ machineID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suspended.contains(machineID)
    }
    public func setEnabled(_ enabled: Bool, machineID: String) {
        lock.lock(); defer { lock.unlock() }
        if enabled { suspended.remove(machineID) } else { suspended.insert(machineID) }
    }
    public func requireAccess(to machineID: String) throws {
        guard !isSuspended(machineID) else { throw RemoteServiceError.commandRejected("remote_access_suspended") }
    }
}

public protocol RemoteAccessPolicyReceiving: Sendable {
    func setLocalAccessPolicy(_ policy: RemoteLocalAccessPolicy) async
}
