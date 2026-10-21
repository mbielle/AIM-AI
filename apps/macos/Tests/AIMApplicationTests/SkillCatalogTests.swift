import AIMApplication
import XCTest

final class SkillCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-skills-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ folder: URL, name: String, description: String, body: String = "Steps.", extra: String = "") throws -> URL {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)\n"
            .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    func testFrontmatterParsing() {
        let parsed = SkillCatalog.parse("---\r\nname: pdf-tools\r\ndescription: \"Fill PDF forms: use for any .pdf\"\r\ndisable-model-invocation: true\r\n---\r\n# Steps\r\nDo it.")
        XCTAssertEqual(parsed?.name, "pdf-tools")
        XCTAssertEqual(parsed?.description, "Fill PDF forms: use for any .pdf")
        XCTAssertEqual(parsed?.body, "# Steps\nDo it.")
        XCTAssertEqual(parsed?.modelInvocable, false)
        XCTAssertNil(SkillCatalog.parse("name: x\ndescription: y"), "frontmatter fences are required")
        XCTAssertNil(SkillCatalog.parse("---\nname: ../escape\ndescription: y\n---\n"), "names cannot be paths")
        XCTAssertNil(SkillCatalog.parse("---\nname: ok\n---\nbody"), "a description is required")
    }

    func testWorkspaceOverridesGlobalAndUnsafeFoldersAreIgnored() throws {
        let global = root.appendingPathComponent("global", isDirectory: true)
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        try write(global, name: "deploy", description: "Global deploy")
        try write(global, name: "notes", description: "Global notes")
        try write(workspace.appendingPathComponent(".aim/skills"), name: "deploy", description: "Project deploy")
        try write(workspace.appendingPathComponent(".claude/skills"), name: "review", description: "Project review")
        // A symlinked skill folder and an oversized SKILL.md are skipped.
        let outside = try write(root.appendingPathComponent("outside"), name: "linked", description: "Outside")
        try FileManager.default.createSymbolicLink(at: global.appendingPathComponent("linked"), withDestinationURL: outside)
        let huge = try write(global, name: "huge", description: "Too big")
        try String(repeating: "x", count: 300_000).write(to: huge.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillCatalog.discover(workspace: workspace.path, global: global)
        XCTAssertEqual(skills.map(\.name), ["deploy", "notes", "review"])
        XCTAssertEqual(skills.first { $0.name == "deploy" }?.description, "Project deploy")
        XCTAssertEqual(skills.first { $0.name == "deploy" }?.source, .workspace)
        XCTAssertEqual(SkillCatalog.discover(workspace: workspace.path, global: global, disabled: ["notes"]).map(\.name), ["deploy", "review"])
    }

    func testCatalogIsBoundedAndExcludesHiddenSkills() throws {
        let global = root.appendingPathComponent("global", isDirectory: true)
        for index in 0..<70 {
            try write(global, name: String(format: "skill-%02d", index), description: String(repeating: "d", count: 150))
        }
        try write(global, name: "aaa-hidden", description: "Manual only", extra: "disable-model-invocation: true\n")
        let skills = SkillCatalog.discover(workspace: nil, global: global)
        let message = try XCTUnwrap(SkillCatalog.catalogMessage(skills, conversationID: UUID()))
        let lines = message.content.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertLessThanOrEqual(lines.count, SkillCatalog.maximumCatalogSkills)
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.count }, SkillCatalog.maximumCatalogCharacters)
        XCTAssertFalse(message.content.contains("aaa-hidden"))
        XCTAssertEqual(message.role, .user)
        XCTAssertNil(SkillCatalog.catalogMessage([], conversationID: UUID()))
    }

    func testReadFileStaysInsideTheSkillFolder() throws {
        let global = root.appendingPathComponent("global", isDirectory: true)
        let directory = try write(global, name: "tools", description: "Tools")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "echo hi".write(to: directory.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("leak.txt"),
                                                   withDestinationURL: root.appendingPathComponent("secret.txt"))
        let skill = try XCTUnwrap(SkillCatalog.discover(workspace: nil, global: global).first)

        XCTAssertEqual(try SkillCatalog.readFile(skill, relativePath: "scripts/run.sh"), "echo hi")
        XCTAssertEqual(SkillCatalog.supportingFiles(skill), ["scripts/run.sh"], "symlinks are not listed")
        for path in ["../secret.txt", "/etc/hosts", "scripts/../../secret.txt", "leak.txt", ""] {
            XCTAssertThrowsError(try SkillCatalog.readFile(skill, relativePath: path), path)
        }
        try String(repeating: "a", count: 2_000).write(to: directory.appendingPathComponent("long.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try SkillCatalog.readFile(skill, relativePath: "long.md", maximumBytes: 100).hasSuffix("[truncated at 100 bytes]"))
    }

    func testProposalAcceptVersionAndRollback() throws {
        let global = root.appendingPathComponent("global", isDirectory: true)
        try write(global, name: "weekly-report", description: "Old report")
        XCTAssertThrowsError(try SkillCatalog.propose(name: "bad name", description: "d", body: "b", global: global))
        XCTAssertThrowsError(try SkillCatalog.propose(name: "ok", description: "two\nlines", body: "b", global: global))

        try SkillCatalog.propose(name: "weekly-report", description: "New report", body: "1. Collect.\n2. Verify.", global: global)
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: global).first?.description, "Old report",
                       "a proposal is inactive until accepted")
        let proposal = try XCTUnwrap(SkillCatalog.proposals(global: global).first)
        XCTAssertEqual(proposal.source, .proposal)

        try SkillCatalog.accept(proposal: proposal, global: global)
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: global).first?.description, "New report")
        XCTAssertTrue(SkillCatalog.proposals(global: global).isEmpty)
        XCTAssertEqual(SkillCatalog.versions(name: "weekly-report", global: global).count, 1)

        try SkillCatalog.rollback(name: "weekly-report", global: global)
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: global).first?.description, "Old report")
        XCTAssertEqual(SkillCatalog.versions(name: "weekly-report", global: global).count, 1, "the replaced version is kept")
        XCTAssertThrowsError(try SkillCatalog.rollback(name: "missing", global: global))
    }

    func testImportSkipsExistingNamesAndHonorsSelection() throws {
        let source = root.appendingPathComponent("claude", isDirectory: true)
        let global = root.appendingPathComponent("global", isDirectory: true)
        try write(source, name: "alpha", description: "A")
        try write(source, name: "beta", description: "B")
        try write(source, name: "gamma", description: "C")
        try write(global, name: "beta", description: "Mine")
        XCTAssertEqual(try SkillCatalog.importSkills(from: source, names: ["alpha", "beta"], global: global), ["alpha"])
        XCTAssertEqual(SkillCatalog.discover(workspace: nil, global: global).map(\.description), ["A", "Mine"])
    }
}
