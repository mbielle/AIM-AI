import AIMCore
import AIMApplication
import Foundation
import Sparkle

@MainActor
enum MacUpdateEvent {
    case availabilityChanged
    case found(version: String)
    case notFound
    case finished
    case scheduled(TimeInterval?)
}

@MainActor
protocol MacUpdateClient: AnyObject {
    var onEvent: (@MainActor (MacUpdateEvent) -> Void)? { get set }
    var automaticallyChecksForUpdates: Bool { get }
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    func startUpdater() throws
    func setNetworkSuspended(_ suspended: Bool)
    func resetUpdateCycle()
    func checkForUpdatesInBackground()
    func checkForUpdates()
}

/// The production boundary always uses the real privacy and qualification guards.
@MainActor
final class SparkleUpdateClient: NSObject, MacUpdateClient, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var onEvent: (@MainActor (MacUpdateEvent) -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var networkSuspended = false
    private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onEvent?(.availabilityChanged) }
            },
            controller.updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onEvent?(.availabilityChanged) }
            }
        ]
    }

    var automaticallyChecksForUpdates: Bool { controller.updater.automaticallyChecksForUpdates }
    func setNetworkSuspended(_ suspended: Bool) { networkSuspended = suspended }
    func resetUpdateCycle() { controller.updater.resetUpdateCycle() }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var sessionInProgress: Bool { controller.updater.sessionInProgress }
    func startUpdater() throws { try controller.updater.start() }
    func checkForUpdatesInBackground() { controller.updater.checkForUpdatesInBackground() }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !networkSuspended, !AIMInstallationContext.isQualification else { throw AIMNetworkPrivacyError.networkDisabled }
        try RuntimePrivacyPolicy.requireApplicationNetwork()
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool {
        !networkSuspended && !AIMInstallationContext.isQualification && !RuntimePrivacyPolicy.isApplicationNetworkBlocked
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if networkSuspended || AIMInstallationContext.isQualification || RuntimePrivacyPolicy.isApplicationNetworkBlocked {
            request.url = URL(string: "aim-private-blocked://update")
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onEvent?(.found(version: item.displayVersionString))
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { onEvent?(.notFound) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { onEvent?(.finished) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { onEvent?(.finished) }
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) { onEvent?(.scheduled(delay)) }
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) { onEvent?(.scheduled(nil)) }

    // A scheduled update is represented by the sidebar. A click focuses Sparkle's existing session.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        onEvent?(.found(version: update.displayVersionString))
    }
    func standardUserDriverWillFinishUpdateSession() { onEvent?(.finished) }
}
