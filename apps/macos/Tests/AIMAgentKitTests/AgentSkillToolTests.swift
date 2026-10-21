import AIMAgentKit
import AIMApplication
import XCTest

final class AgentSkillToolTests: XCTestCase {
    func testViewReadAndProposeStayWithinSkills() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-skill-tools-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("csv-clean", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "---\nname: csv-clean\ndescription: Clean CSV exports\n---\n\n1. Trim columns.\n"
            .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "print('x')".write(to: directory.appendingPathComponent("scripts/clean.py"), atomically: true, encoding: .utf8)
        let service = AgentSkillToolService(skills: SkillCatalog.discover(workspace: nil, global: root), global: root)

        let view = await service.execute(ToolRequest(name: "skill_view", arguments: ["name": "csv-clean"], risk: .readOnly))
        XCTAssertFalse(view.isError)
        XCTAssertTrue(view.content.contains("1. Trim columns."))
        XCTAssertTrue(view.content.contains("scripts/clean.py"))
        XCTAssertFalse(view.content.contains("description: Clean CSV"), "frontmatter is not repeated")

        let file = await service.execute(ToolRequest(name: "skill_read_file",
            arguments: ["name": "csv-clean", "path": "scripts/clean.py"], risk: .readOnly))
        XCTAssertEqual(file.content, "print('x')")
        let escape = await service.execute(ToolRequest(name: "skill_read_file",
            arguments: ["name": "csv-clean", "path": "../csv-clean/../../etc/hosts"], risk: .readOnly))
        XCTAssertTrue(escape.isError)
        let unknown = await service.execute(ToolRequest(name: "skill_view", arguments: ["name": "nope"], risk: .readOnly))
        XCTAssertTrue(unknown.isError)

        let proposed = await service.execute(ToolRequest(name: "skill_propose",
            arguments: ["name": "csv-clean", "description": "Clean CSV exports, v2", "instructions": "1. Trim.\n2. Dedupe."],
            risk: .localMutation))
        XCTAssertFalse(proposed.isError, proposed.content)
        XCTAssertTrue(proposed.content.contains("Proposed skill csv-clean"), "suggest level: proposals only")
        XCTAssertEqual(SkillCatalog.proposals(global: root).map(\.description), ["Clean CSV exports, v2"])
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: root).first?.description, "Clean CSV exports")
        let empty = await service.execute(ToolRequest(name: "skill_propose",
            arguments: ["name": "x", "description": "d", "instructions": "  "], risk: .localMutation))
        XCTAssertTrue(empty.isError)
    }

    func testLevelsDecideWhetherAgentChangesApply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-skill-levels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let off = AgentSkillToolService(skills: [], global: root, level: .off)
        let refused = await off.execute(ToolRequest(name: "skill_propose",
            arguments: ["name": "x", "description": "d", "instructions": "1. Step one, then verify."], risk: .localMutation))
        XCTAssertTrue(refused.isError)
        let autonomous = AgentSkillToolService(skills: [], global: root, level: .autonomous)
        let created = await autonomous.execute(ToolRequest(name: "skill_propose",
            arguments: ["name": "release-notes", "description": "Write release notes", "instructions": "1. Collect changes.\n2. Verify the file."],
            risk: .localMutation))
        XCTAssertTrue(created.content.hasPrefix("Created skill release-notes"), created.content)
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: root).map(\.name), ["release-notes"])
    }
}
