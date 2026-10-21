import AIMApplication
import AIMMacPlatform
import XCTest

private actor FixedActivitySampler: ActivitySampling {
    var next: ActivitySample?
    func set(_ sample: ActivitySample?) { next = sample }
    func sample(settings: ActivitySettings) -> ActivitySample? { next }
}

final class ActivityTrackerTests: XCTestCase {
    func testOptInTrackingAndDisableDiscard() async throws {
        let repository = SQLiteActivityRepository(database: try AIMDatabase(inMemory: true))
        let sampler = FixedActivitySampler()
        let tracker = ActivityTracker(sampler: sampler, repository: repository)
        let start = Date(timeIntervalSince1970: 1_000_000)
        await sampler.set(ActivitySample(application: "Xcode", title: "", url: nil, isPrivate: false))

        try await tracker.tick(settings: .init(), now: start)
        let initial = try await repository.search("", since: nil, until: nil, limit: 10)
        XCTAssertTrue(initial.isEmpty)
        try await tracker.tick(settings: .init(isEnabled: true), now: start)
        try await tracker.tick(settings: .init(isEnabled: true), now: start.addingTimeInterval(10))
        try await tracker.tick(settings: .init(), now: start.addingTimeInterval(11))
        let discarded = try await repository.search("", since: nil, until: nil, limit: 10)
        XCTAssertTrue(discarded.isEmpty)

        try await tracker.tick(settings: .init(isEnabled: true), now: start.addingTimeInterval(20))
        try await tracker.tick(settings: .init(isEnabled: true), now: start.addingTimeInterval(30))
        await sampler.set(nil)
        try await tracker.tick(settings: .init(isEnabled: true), now: start.addingTimeInterval(35))
        let entries = try await repository.search("", since: nil, until: nil, limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.application, "Xcode")
        XCTAssertEqual(entries.first?.startedAt, start.addingTimeInterval(20))
    }

    func testSensitiveAndBrowserSamplesAreNeverPersisted() async throws {
        let repository = SQLiteActivityRepository(database: try AIMDatabase(inMemory: true))
        let sampler = FixedActivitySampler()
        let tracker = ActivityTracker(sampler: sampler, repository: repository)
        let settings = ActivitySettings(isEnabled: true)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for name in ["Safari", "Google Chrome", "1Password", "Revolut"] {
            await sampler.set(ActivitySample(application: name, title: "Ordinary title", url: nil, isPrivate: false))
            try await tracker.tick(settings: settings, now: start)
            try await tracker.tick(settings: settings, now: start.addingTimeInterval(10))
        }
        await sampler.set(ActivitySample(application: "Xcode", title: "Private", url: nil, isPrivate: true))
        try await tracker.tick(settings: settings, now: start.addingTimeInterval(20))
        let excluded = try await repository.search("", since: nil, until: nil, limit: 10)
        XCTAssertTrue(excluded.isEmpty)
        XCTAssertFalse(MacActivitySampler.permitsApplication(bundleIdentifier: "com.apple.Safari", name: "Safari"))
        XCTAssertFalse(MacActivitySampler.permitsApplication(bundleIdentifier: nil, name: "Google Chrome"))
        XCTAssertTrue(MacActivitySampler.permitsApplication(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"))
    }
}
