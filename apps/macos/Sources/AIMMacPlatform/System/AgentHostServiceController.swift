import AIMCore
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Registration is called only after explicit opt-in in settings.
@MainActor
public final class AgentHostServiceController {
    public static var identifier: String { AIMInstallationContext.helperIdentifier }
    private let service = SMAppService.agent(plistName: AIMInstallationContext.helperIdentifier + ".plist")
    public init() {}
    public var status: SMAppService.Status { service.status }
    public func enable() throws {
        guard service.status != .enabled else { return }
        try service.register()
    }
    /// Caller pauses all missions and waits for the runtime before unregistering.
    public func disable() async throws { try await service.unregister() }
}

/// Prevents idle system sleep only; never overrides lid-close or forced sleep.
public final class AgentHostWakeAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    public init() {}
    public func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            if enabled, assertion == 0 {
                var value: IOPMAssertionID = 0
                guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "AIM continuous missions" as CFString, &value) == kIOReturnSuccess else {
                    throw CocoaError(.featureUnsupported)
                }
                assertion = value
            } else if !enabled, assertion != 0 {
                IOPMAssertionRelease(assertion); assertion = 0
            }
        }
    }
    deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
}
