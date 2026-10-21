import AIMApplication
import XCTest

final class ProjectDraftTests: XCTestCase {
    func testDraftTracksExactUnsavedChangesAndRestoration() {
        let project = AIMProject(name: "App", instructions: "Use Swift")
        var draft = ProjectDraft(project: project)
        XCTAssertFalse(draft.isDirty)
        XCTAssertTrue(draft.isValid)
        draft.instructions += "UI"
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(project.instructions, "Use Swift")
        draft.instructions = project.instructions
        XCTAssertFalse(draft.isDirty)
        draft.name = "App "
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.projectID, project.id)
    }
    func testNewDraftAndSizeLimits() {
        var draft = ProjectDraft()
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.isValid)
        draft.name = "New project"
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(draft.isValid)
        draft.instructions = String(repeating: "x", count: 16_001)
        XCTAssertFalse(draft.isValid)
        draft.instructions = ""
        draft.name = String(repeating: "n", count: 121)
        XCTAssertFalse(draft.isValid)
    }
}
