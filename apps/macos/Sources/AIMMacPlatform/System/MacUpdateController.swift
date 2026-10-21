import AIMCore
import AIMApplication
import Foundation
import Observation

/// Sparkle owns version selection, skipped releases, scheduling and installation.
@MainActor
@Observable
public final class MacUpdateController {
    public enum State: Equatable, Sendable {
        case unavailable
        case checking
        case available(version: String)
    }

    public private(set) var state: State = .unavailable
    public private(set) var canCheckForUpdates = false
    public private(set) var canPresentUpdate = false
    public private(set) var nextScheduledCheckDelay: TimeInterval?
    @ObservationIgnored private let client: (any MacUpdateClient)?
    @ObservationIgnored private let networkBlocked: @MainActor () -> Bool
    @ObservationIgnored private let qualification: Bool
    @ObservationIgnored private let mayStartUpdater: Bool
    @ObservationIgnored private var privacyTask: Task<Void, Never>?
    @ObservationIgnored private var updaterStarted = false
    @ObservationIgnored private var presentationRequested = false
    @ObservationIgnored private var networkSuspended = false

    public enum PrivacyActivationError: LocalizedError {
        case updateInProgress
        public var errorDescription: String? { "An update session is active. Cancel it in the update window or wait for it to finish before enabling application private mode." }
    }

    public convenience init(startingUpdater: Bool = true) {
        let qualification = AIMInstallationContext.isQualification
        guard startingUpdater && !qualification else {
            self.init(client: nil, startingUpdater: false, qualification: qualification,
                      networkBlocked: { false }, privacyChanges: AsyncStream { $0.finish() })
            return
        }
        self.init(client: SparkleUpdateClient(),
                  startingUpdater: startingUpdater, qualification: qualification,
                  networkBlocked: { RuntimePrivacyPolicy.isApplicationNetworkBlocked },
                  privacyChanges: RuntimePrivacyPolicy.globalChanges())
    }

    /// Internal seam: tests exercise this controller without constructing Sparkle or app defaults.
    init(client: (any MacUpdateClient)?, startingUpdater: Bool = true, qualification: Bool = false,
         networkBlocked: @escaping @MainActor () -> Bool, privacyChanges: AsyncStream<Bool>) {
        self.client = client
        self.networkBlocked = networkBlocked
        self.qualification = qualification
        mayStartUpdater = startingUpdater && !qualification
        client?.onEvent = { [weak self] event in self?.receive(event) }
        if networkBlocked() { pauseUpdateNetwork() } else { startIfAllowed() }
        privacyTask = Task { [weak self] in
            for await enabled in privacyChanges {
                guard !Task.isCancelled else { return }
                self?.privacyChanged(enabled)
            }
        }
    }

    private var allowed: Bool { mayStartUpdater && !qualification && !networkBlocked() && !networkSuspended }

    private func startIfAllowed() {
        guard allowed, !updaterStarted, let client else { refreshAvailability(); return }
        do {
            updaterStarted = true
            try client.startUpdater()
            // Sparkle explicitly supports this immediately after start; its scheduler owns every later check.
            if client.automaticallyChecksForUpdates && !client.sessionInProgress {
                state = .checking
                client.checkForUpdatesInBackground()
            }
        } catch { updaterStarted = false; state = .unavailable }
        refreshAvailability()
    }

    private func privacyChanged(_ enabled: Bool) {
        if enabled { pauseUpdateNetwork() }
        else {
            let wasSuspended = networkSuspended
            networkSuspended = false
            client?.setNetworkSuspended(false)
            if wasSuspended && updaterStarted && allowed { client?.resetUpdateCycle() }
            startIfAllowed()
            refreshAvailability()
        }
    }

    public func requirePrivateModeActivation() throws {
        guard client?.sessionInProgress != true else { throw PrivacyActivationError.updateInProgress }
    }

    public func suspendNetworkForPrivateMode() { pauseUpdateNetwork() }

    private func pauseUpdateNetwork() {
        networkSuspended = true
        presentationRequested = false
        if mayStartUpdater { client?.setNetworkSuspended(true) }
        state = .unavailable
        nextScheduledCheckDelay = nil
        canCheckForUpdates = false
        canPresentUpdate = false
    }

    public func checkForUpdates() {
        guard allowed, updaterStarted, let client, client.canCheckForUpdates, !presentationRequested else { return }
        presentationRequested = true
        if case .available = state {} else { state = .checking }
        refreshAvailability()
        client.checkForUpdates()
    }

    private func receive(_ event: MacUpdateEvent) {
        guard allowed, updaterStarted else { return }
        switch event {
        case .availabilityChanged:
            if client?.sessionInProgress == true {
                if case .unavailable = state { state = .checking }
            } else if case .checking = state {
                // Sparkle also toggles sessionInProgress while preparing its next
                // scheduled check, without an update-driver completion callback.
                state = .unavailable
                presentationRequested = false
            }
        case .found(let version): state = .available(version: version)
        case .notFound, .finished:
            state = .unavailable
            presentationRequested = false
        case .scheduled(let delay): nextScheduledCheckDelay = delay
        }
        refreshAvailability()
    }

    private func refreshAvailability() {
        canCheckForUpdates = allowed && updaterStarted && client?.canCheckForUpdates == true && !presentationRequested
        if case .available = state { canPresentUpdate = canCheckForUpdates }
        else { canPresentUpdate = false }
    }

    isolated deinit { privacyTask?.cancel() }
}
