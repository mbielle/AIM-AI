import Foundation
import XCTest
@testable import AIMCore

final class NativeChatProjectTests: XCTestCase {
    func testLegacyProjectsDefaultToUnpinnedAndDefaultMemory() throws {
        let project = NativeChatProject(name: "Legacy", instructions: "Preserve project rules")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "isPinned"); object.removeValue(forKey: "memoryScope")
        let restored = try JSONDecoder().decode(NativeChatProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(restored.isPinned); XCTAssertEqual(restored.memoryScope, .default)
        XCTAssertEqual(restored.id, project.id); XCTAssertEqual(restored.instructions, project.instructions)
        XCTAssertEqual(restored.createdAt, project.createdAt)
    }
    func testPinnedProjectOnlyMetadataRoundTripsInProjectArrayArchive() throws {
        let projects = [NativeChatProject(name: "Private research", isPinned: true, memoryScope: .projectOnly), NativeChatProject(name: "General")]
        let restored = try JSONDecoder().decode([NativeChatProject].self, from: JSONEncoder().encode(projects))
        XCTAssertEqual(restored, projects)
        XCTAssertTrue(restored[0].isPinned); XCTAssertEqual(restored[0].memoryScope, .projectOnly)
        XCTAssertFalse(restored[1].isPinned); XCTAssertEqual(restored[1].memoryScope, .default)
    }
    func testUnknownMemoryScopeNeverSilentlyBroadensToGlobalMemory() throws {
        let project = NativeChatProject(name: "Scoped", memoryScope: .projectOnly)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object["memoryScope"] = "future-unknown-scope"
        XCTAssertThrowsError(try JSONDecoder().decode(NativeChatProject.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
