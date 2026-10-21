import AIMApplication
import XCTest

final class ActivityRetentionTests: XCTestCase {
    func testRepositoryPurgesOnlyEntriesOlderThanCutoff() async throws {
        let repository = SQLiteActivityRepository(database: try AIMDatabase(inMemory: true))
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        try await repository.record(ActivityEntry(application: "Finder", title: "", startedAt: cutoff.addingTimeInterval(-120), endedAt: cutoff.addingTimeInterval(-60)))
        try await repository.record(ActivityEntry(application: "Xcode", title: "", startedAt: cutoff.addingTimeInterval(-30), endedAt: cutoff))
        try await repository.record(ActivityEntry(application: "Terminal", title: "", startedAt: cutoff.addingTimeInterval(30), endedAt: cutoff.addingTimeInterval(60)))

        let firstPurge = try await repository.purge(olderThan: cutoff)
        XCTAssertEqual(firstPurge, 1)
        let remaining = try await repository.search("", since: nil, until: nil, limit: 20)
        XCTAssertEqual(remaining.map(\.application), ["Terminal", "Xcode"])
        let secondPurge = try await repository.purge(olderThan: .distantFuture)
        XCTAssertEqual(secondPurge, 2)
        let empty = try await repository.search("", since: nil, until: nil, limit: 20)
        XCTAssertTrue(empty.isEmpty)
    }

    func testRetentionIsPrivacyBoundedNotAProviderQuota() {
        XCTAssertEqual(ActivitySettings(retentionDays: 365).retentionDays, 30)
        XCTAssertEqual(ActivitySettings(retentionDays: 0).retentionDays, 1)
        XCTAssertFalse(ActivitySettings().isEnabled)
    }
}
