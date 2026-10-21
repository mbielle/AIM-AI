import Foundation
import Observation
@testable import AIMMacPlatform
import XCTest

@MainActor
final class MacUpdateControllerTests: XCTestCase {
    func testProductionSparkleDelegateSelectorsAreActuallyImplemented() {
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:didFindValidUpdate:",
                         "updaterDidNotFindUpdate:", "updater:didAbortWithError:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:",
                         "updater:willScheduleUpdateCheckAfterDelay:",
                         "supportsGentleScheduledUpdateReminders",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                         "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
                         "standardUserDriverWillFinishUpdateSession"] {
            XCTAssertTrue(SparkleUpdateClient.instancesRespond(to: NSSelectorFromString(selector)), selector)
        }
    }

    func testStartupPreservesPreferencesAndOnlyChecksWhenOptedIn() {
        for checks in [false, true] {
            for downloads in [false, true] {
                let fixture = Fixture(checks: checks, downloads: downloads)
                XCTAssertEqual(fixture.client.starts, 1)
                XCTAssertEqual(fixture.client.backgroundChecks, checks ? 1 : 0)
                XCTAssertEqual(fixture.client.preferenceWrites, 0)
                XCTAssertEqual(fixture.client.automaticallyDownloadsUpdates, downloads)
                fixture.finish()
            }
        }
    }

    func testRecreatingControllerDoesNotResetStoredPreferences() {
        let client = Client(checks: false, downloads: true)
        for _ in 0..<2 {
            let pair = AsyncStream<Bool>.makeStream()
            var controller: MacUpdateController? = MacUpdateController(client: client, networkBlocked: { false }, privacyChanges: pair.stream)
            XCTAssertNotNil(controller)
            controller = nil
            pair.continuation.finish()
        }
        XCTAssertEqual(client.preferenceWrites, 0)
        XCTAssertFalse(client.automaticallyChecksForUpdates)
        XCTAssertTrue(client.automaticallyDownloadsUpdates)
        XCTAssertEqual(client.backgroundChecks, 0)
    }

    func testOnlySparklesAcceptedUpdateCreatesAvailabilityAndNextEmptyCycleClearsIt() {
        let fixture = Fixture()
        // These are Sparkle decisions, not a second feed parser/comparator in AIM.
        for reason in ["empty feed", "same version", "older version", "skipped version"] {
            fixture.client.emit(.notFound)
            XCTAssertEqual(fixture.controller.state, .unavailable, reason)
        }
        fixture.client.emit(.found(version: "0.2"))
        XCTAssertEqual(fixture.controller.state, .available(version: "0.2"))
        XCTAssertTrue(fixture.controller.canPresentUpdate)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 1)
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        fixture.client.emit(.notFound)
        fixture.client.emit(.finished)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        fixture.finish()
    }

    func testBackgroundSessionAndRapidButtonRequestsNeverOverlap() {
        let fixture = Fixture()
        fixture.client.sessionInProgress = true
        fixture.client.canCheckForUpdates = false
        fixture.client.emit(.availabilityChanged)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 0)
        fixture.client.emit(.found(version: "0.2"))
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        // Sparkle allows focus of a gently presented update even though its session is active.
        fixture.client.canCheckForUpdates = true
        fixture.client.emit(.availabilityChanged)
        XCTAssertTrue(fixture.controller.canPresentUpdate)
        for _ in 0..<10 { fixture.controller.checkForUpdates() }
        XCTAssertEqual(fixture.client.manualChecks, 1)
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        XCTAssertEqual(fixture.client.backgroundChecks, 1)
        fixture.finish()
    }

    func testNetworkFailureFinishesAndManualRecoveryWorks() {
        let fixture = Fixture()
        fixture.client.emit(.finished)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.controller.state, .checking)
        fixture.client.emit(.found(version: "0.3"))
        XCTAssertEqual(fixture.controller.state, .available(version: "0.3"))
        fixture.client.emit(.finished)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        fixture.finish()
    }

    func testSchedulerPreparationReturnsToIdleWithoutASecondDriverCompletion() {
        let fixture = Fixture()
        fixture.client.emit(.finished)
        // SPUUpdater's scheduling probe is a session, but is not a new update check.
        fixture.client.canCheckForUpdates = false
        fixture.client.sessionInProgress = true
        fixture.client.emit(.availabilityChanged)
        XCTAssertEqual(fixture.controller.state, .checking)
        fixture.client.canCheckForUpdates = true
        fixture.client.sessionInProgress = false
        fixture.client.emit(.availabilityChanged)
        fixture.client.emit(.scheduled(3600))
        XCTAssertEqual(fixture.controller.state, .unavailable)
        XCTAssertTrue(fixture.controller.canCheckForUpdates)
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        XCTAssertEqual(fixture.client.backgroundChecks, 1)
        fixture.finish()
    }

    func testIdleAvailabilityClearsPendingPresentationButPreservesAFoundUpdate() {
        let fixture = Fixture(checks: false)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.controller.state, .checking)
        fixture.client.emit(.availabilityChanged)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        XCTAssertTrue(fixture.controller.canCheckForUpdates)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 2)
        fixture.client.emit(.found(version: "0.3"))
        fixture.client.emit(.availabilityChanged)
        XCTAssertEqual(fixture.controller.state, .available(version: "0.3"))
        // Existing presentation remains locked until the real update session finishes.
        fixture.client.emit(.finished)
        fixture.client.emit(.found(version: "0.3"))
        fixture.client.emit(.availabilityChanged)
        XCTAssertTrue(fixture.controller.canPresentUpdate)
        fixture.finish()
    }

    func testSchedulerEventsAreObservedWithoutAnotherTimerOrBackgroundCheck() {
        let fixture = Fixture()
        for delay in [3600.0, 725.0, 3600.0] {
            fixture.client.emit(.scheduled(delay))
            XCTAssertEqual(fixture.controller.nextScheduledCheckDelay, delay)
        }
        fixture.client.emit(.scheduled(nil))
        XCTAssertNil(fixture.controller.nextScheduledCheckDelay)
        XCTAssertEqual(fixture.client.starts, 1)
        XCTAssertEqual(fixture.client.backgroundChecks, 1)
        XCTAssertEqual(fixture.client.preferenceWrites, 0)
        fixture.finish()
    }

    func testPrivateStartupDefersStartAndRestoresExactPreferencesOnce() async {
        let fixture = Fixture(checks: true, downloads: false, blocked: true)
        XCTAssertEqual(fixture.client.starts, 0)
        XCTAssertTrue(fixture.client.automaticallyChecksForUpdates)
        XCTAssertTrue(fixture.client.suspended)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 0)
        let resumed = expectation(description: "private startup resumed")
        fixture.client.onBackground = { resumed.fulfill() }
        fixture.block.value = false
        fixture.changes.yield(false)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(fixture.client.automaticallyChecksForUpdates)
        XCTAssertFalse(fixture.client.automaticallyDownloadsUpdates)
        let repeated = expectation(description: "repeated privacy exits consumed")
        repeated.expectedFulfillmentCount = 2
        fixture.client.onSuspension = { if !$0 { repeated.fulfill() } }
        fixture.changes.yield(false)
        fixture.changes.yield(false)
        await fulfillment(of: [repeated], timeout: 2)
        XCTAssertEqual(fixture.client.starts, 1)
        XCTAssertEqual(fixture.client.backgroundChecks, 1)
        fixture.finish()
    }

    func testPrivateModeGuardBlocksActiveCycleAndLateCallbacksCannotExposeUpdate() async throws {
        let fixture = Fixture(checks: false, downloads: true)
        fixture.client.sessionInProgress = true
        XCTAssertThrowsError(try fixture.controller.requirePrivateModeActivation())
        fixture.client.sessionInProgress = false
        XCTAssertNoThrow(try fixture.controller.requirePrivateModeActivation())
        fixture.controller.suspendNetworkForPrivateMode()
        fixture.block.value = true
        fixture.changes.yield(true)
        fixture.client.emit(.found(version: "late"))
        fixture.client.emit(.scheduled(3600))
        XCTAssertEqual(fixture.controller.state, .unavailable)
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        XCTAssertNil(fixture.controller.nextScheduledCheckDelay)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 0)
        let resumed = expectation(description: "existing scheduler reset after privacy")
        fixture.client.onReset = { resumed.fulfill() }
        fixture.block.value = false
        fixture.changes.yield(false)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(fixture.client.resets, 1)
        XCTAssertFalse(fixture.client.suspended)
        XCTAssertFalse(fixture.client.automaticallyChecksForUpdates)
        XCTAssertTrue(fixture.client.automaticallyDownloadsUpdates)
        XCTAssertEqual(fixture.client.backgroundChecks, 0)
        fixture.finish()
    }

    func testQuittingWhilePrivateAndRecreatingKeepsPreferencesWithoutPersistentPause() async {
        let client = Client(checks: true, downloads: true)
        let block = Block(false)
        let first = AsyncStream<Bool>.makeStream()
        var controller: MacUpdateController? = MacUpdateController(client: client, networkBlocked: { block.value }, privacyChanges: first.stream)
        controller?.suspendNetworkForPrivateMode()
        block.value = true
        controller = nil
        first.continuation.finish()
        let second = AsyncStream<Bool>.makeStream()
        let restored = MacUpdateController(client: client, networkBlocked: { block.value }, privacyChanges: second.stream)
        XCTAssertEqual(client.preferenceWrites, 0)
        let resumed = expectation(description: "recreated controller resumed")
        client.onBackground = { resumed.fulfill() }
        block.value = false
        second.continuation.yield(false)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(client.automaticallyChecksForUpdates)
        XCTAssertTrue(client.automaticallyDownloadsUpdates)
        XCTAssertFalse(client.suspended)
        XCTAssertEqual(client.preferenceWrites, 0)
        XCTAssertTrue(restored.canCheckForUpdates)
        second.continuation.finish()
    }

    func testPrivatePauseClearsPresentationLockEvenWhenOldFinishArrivesWhileBlocked() async {
        let fixture = Fixture(checks: false)
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 1)
        fixture.controller.suspendNetworkForPrivateMode()
        fixture.block.value = true
        fixture.client.emit(.finished)
        XCTAssertEqual(fixture.controller.state, .unavailable)
        let resumed = expectation(description: "resume after ignored old finish")
        fixture.client.onReset = { resumed.fulfill() }
        fixture.block.value = false
        fixture.changes.yield(false)
        await fulfillment(of: [resumed], timeout: 2)
        fixture.client.emit(.found(version: "0.4"))
        XCTAssertTrue(fixture.controller.canPresentUpdate)
        fixture.controller.checkForUpdates()
        fixture.controller.checkForUpdates()
        XCTAssertEqual(fixture.client.manualChecks, 2)
        XCTAssertFalse(fixture.controller.canPresentUpdate)
        fixture.finish()
    }

    func testQualificationAndDisabledControllerNeverStartEvenAfterPrivacyExit() async {
        for qualification in [false, true] {
            let fixture = Fixture(blocked: true, starting: qualification, qualification: qualification)
            let consumed = expectation(description: "disabled privacy exit consumed")
            fixture.client.onSuspension = { if !$0 { consumed.fulfill() } }
            fixture.block.value = false
            fixture.changes.yield(false)
            await fulfillment(of: [consumed], timeout: 2)
            fixture.controller.checkForUpdates()
            fixture.client.emit(.found(version: "unexpected"))
            XCTAssertEqual(fixture.client.starts, 0)
            XCTAssertEqual(fixture.client.backgroundChecks, 0)
            XCTAssertEqual(fixture.client.manualChecks, 0)
            XCTAssertEqual(fixture.client.preferenceWrites, 0)
            XCTAssertEqual(fixture.controller.state, .unavailable)
            fixture.finish()
        }
    }

    func testStartupFailureRemainsUnavailableAndDoesNotCheck() {
        let client = Client(checks: true, downloads: false)
        client.startError = NSError(domain: "SyntheticUpdater", code: 1)
        let pair = AsyncStream<Bool>.makeStream()
        let controller = MacUpdateController(client: client, networkBlocked: { false }, privacyChanges: pair.stream)
        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(client.backgroundChecks, 0)
        XCTAssertEqual(client.manualChecks, 0)
        pair.continuation.finish()
    }

    func testAvailabilityIsObservableAndControllerStreamDoesNotRetainOwner() async {
        let fixture = Fixture()
        let changed = expectation(description: "observable state")
        withObservationTracking { _ = fixture.controller.state } onChange: { changed.fulfill() }
        fixture.client.emit(.found(version: "0.2"))
        await fulfillment(of: [changed], timeout: 2)
        let pair = AsyncStream<Bool>.makeStream()
        var controller: MacUpdateController? = MacUpdateController(client: Client(checks: false, downloads: false), networkBlocked: { false }, privacyChanges: pair.stream)
        weak var weakController = controller
        await Task.yield()
        controller = nil
        XCTAssertNil(weakController)
        pair.continuation.finish()
        fixture.finish()
    }

    @MainActor private final class Block { var value: Bool; init(_ value: Bool) { self.value = value } }
    @MainActor private final class Fixture {
        let client: Client
        let controller: MacUpdateController
        let block: Block
        let changes: AsyncStream<Bool>.Continuation
        init(checks: Bool = true, downloads: Bool = false, blocked: Bool = false, starting: Bool = true, qualification: Bool = false) {
            client = Client(checks: checks, downloads: downloads)
            block = Block(blocked)
            let pair = AsyncStream<Bool>.makeStream()
            changes = pair.continuation
            let block = block
            controller = MacUpdateController(client: client, startingUpdater: starting, qualification: qualification,
                                             networkBlocked: { block.value }, privacyChanges: pair.stream)
        }
        func finish() { changes.finish() }

    }
    @MainActor private final class Client: MacUpdateClient {
        var onEvent: (@MainActor (MacUpdateEvent) -> Void)?
        var preferenceWrites = 0
        var automaticallyChecksForUpdates: Bool { didSet { preferenceWrites += 1 } }
        var automaticallyDownloadsUpdates: Bool { didSet { preferenceWrites += 1 } }
        var canCheckForUpdates = true
        var sessionInProgress = false
        var suspended = false
        var resets = 0
        var starts = 0
        var backgroundChecks = 0
        var manualChecks = 0
        var startError: Error?
        var onSuspension: ((Bool) -> Void)?
        var onReset: (() -> Void)?
        var onBackground: (() -> Void)?
        init(checks: Bool, downloads: Bool) {
            automaticallyChecksForUpdates = checks
            automaticallyDownloadsUpdates = downloads
        }
        func setNetworkSuspended(_ suspended: Bool) { self.suspended = suspended; onSuspension?(suspended) }
        func resetUpdateCycle() { resets += 1; onReset?() }
        func startUpdater() throws { starts += 1; if let startError { throw startError } }
        func checkForUpdatesInBackground() { backgroundChecks += 1; onBackground?() }
        func checkForUpdates() { manualChecks += 1 }
        func emit(_ event: MacUpdateEvent) { onEvent?(event) }
    }
}
