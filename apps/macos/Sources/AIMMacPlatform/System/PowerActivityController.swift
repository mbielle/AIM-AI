import Foundation

public actor PowerActivityController {
    private var activity: NSObjectProtocol?

    public init() {}

    public func setEnabled(_ enabled: Bool, reason: String = "AIM AI is running an active task") {
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: reason
            )
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
