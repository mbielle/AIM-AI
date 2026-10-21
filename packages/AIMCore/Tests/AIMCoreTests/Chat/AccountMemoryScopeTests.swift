import XCTest
@testable import AIMCore

final class AccountMemoryScopeTests: XCTestCase {
    func testProjectOnlyExcludesGlobalProfilePinnedLegacyAndForeignMemory() {
        let project = UUID(), other = UUID()
        var snapshot = AccountMemorySnapshot()
        snapshot.entries = [
            .init(subject: "Global profile", content: "global profile fixture", pinned: true, kind: "identity", scope: "global"),
            .init(subject: "Legacy global", content: "legacy global fixture", pinned: true),
            .init(subject: "Foreign", content: "foreign project fixture", projectID: other, pinned: true, scope: "project"),
            .init(subject: "Project", content: "selected project fixture", projectID: project, pinned: true, scope: "project"),
            .init(subject: "Legacy project", content: "selected legacy fixture", projectID: project, pinned: true)
        ]
        let context = AccountMemoryService.context(snapshot, query: "fixture", projectID: project, includeGlobal: false)
        XCTAssertTrue(context.contains("selected project fixture"))
        XCTAssertTrue(context.contains("selected legacy fixture"))
        for text in ["global profile fixture", "legacy global fixture", "foreign project fixture"] { XCTAssertFalse(context.contains(text)) }
        XCTAssertEqual(AccountMemoryService.context(snapshot, query: "fixture", projectID: nil, includeGlobal: false), "")
    }
    func testDefaultRemainsGlobalPlusMatchingProjectAndScopeValidationStillApplies() {
        let project = UUID()
        var snapshot = AccountMemorySnapshot()
        snapshot.entries = [
            .init(subject: "Global", content: "allowed global fixture", pinned: true),
            .init(subject: "Project", content: "allowed project fixture", projectID: project, pinned: true),
            .init(subject: "Invalid scope", content: "invalid scoped fixture", projectID: project, pinned: true, scope: "global"),
            .init(subject: "Archived", content: "archived fixture", projectID: project, pinned: true, archived: true)
        ]
        let context = AccountMemoryService.context(snapshot, query: "fixture", projectID: project)
        XCTAssertTrue(context.contains("allowed global fixture")); XCTAssertTrue(context.contains("allowed project fixture"))
        XCTAssertFalse(context.contains("invalid scoped fixture")); XCTAssertFalse(context.contains("archived fixture"))
        snapshot.enabled = false
        XCTAssertEqual(AccountMemoryService.context(snapshot, query: "fixture", projectID: project, includeGlobal: false), "")
    }
}
