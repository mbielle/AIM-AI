@testable import AIMApplication
import XCTest

final class SkillHubAndUsageTests: XCTestCase {
    private func temporaryGlobal() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ name: String, origin: String?, in global: URL) throws {
        let folder = global.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originLine = origin.map { "aim-origin: \($0)\n" } ?? ""
        try "---\nname: \(name)\ndescription: d\n\(originLine)---\n\nBody".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func testUsageOrdersCatalogAndOnlyStaleLearnedSkillsArchive() throws {
        let global = try temporaryGlobal()
        try write("mine", origin: nil, in: global)
        try write("learned-used", origin: "learned", in: global)
        try write("learned-stale", origin: "learned", in: global)
        let old = Date.now.addingTimeInterval(-90 * 86_400)
        SkillUsage.noteSeen(["mine", "learned-used", "learned-stale"], at: old, global: global)
        SkillUsage.recordUse("learned-used", global: global)
        SkillUsage.recordUse("learned-used", global: global)
        XCTAssertEqual(SkillUsage.records(global: global)["learned-used"]?.uses, 2)
        let ordered = SkillUsage.ordered(SkillCatalog.discover(workspace: nil, global: global), global: global)
        XCTAssertEqual(ordered.first?.name, "learned-used")

        let archived = try SkillUsage.archiveStale(olderThan: 60, global: global)
        XCTAssertEqual(archived, ["learned-stale"], "person-written and recently used skills stay")
        XCTAssertEqual(Set(SkillCatalog.discover(workspace: nil, global: global).map(\.name)), ["mine", "learned-used"])
        let item = try XCTUnwrap(SkillUsage.archived(global: global).first)
        try SkillUsage.restore(folder: item.folder, global: global)
        XCTAssertTrue(SkillCatalog.discover(workspace: nil, global: global).contains { $0.name == "learned-stale" })
        XCTAssertEqual(try SkillUsage.archiveStale(olderThan: 60, global: global), [], "a restored skill ages from its restore")
    }

    func testSourceParsing() {
        XCTAssertEqual(SkillHub.parse("anthropics/skills/skills/pdf"), .init(owner: "anthropics", repo: "skills", path: "skills/pdf", ref: nil))
        XCTAssertEqual(SkillHub.parse("https://github.com/anthropics/skills/tree/main/skills/pdf")?.ref, "main")
        XCTAssertEqual(SkillHub.parse("github:o/r/a/SKILL.md@v1"), .init(owner: "o", repo: "r", path: "a", ref: "v1"))
        XCTAssertNil(SkillHub.parse("o/r/../../etc"))
        XCTAssertNil(SkillHub.parse("justone"))
    }

    func testInstallLandsAsProposalsWithProvenance() async throws {
        let global = try temporaryGlobal()
        let api = "https://api.github.com/repos/o/r/contents/"
        let responses: [String: String] = [
            api + "pack": #"[{"type":"dir","name":"alpha","path":"pack/alpha"},{"type":"dir","name":"notaskill","path":"pack/notaskill"}]"#,
            api + "pack/alpha": #"[{"type":"file","name":"SKILL.md","path":"pack/alpha/SKILL.md","size":60,"download_url":"https://raw.example/alpha/SKILL.md"},{"type":"dir","name":"scripts","path":"pack/alpha/scripts"}]"#,
            api + "pack/alpha/scripts": #"[{"type":"file","name":"run.sh","path":"pack/alpha/scripts/run.sh","size":10,"download_url":"https://raw.example/alpha/run.sh"}]"#,
            api + "pack/notaskill": #"[{"type":"file","name":"README.md","path":"pack/notaskill/README.md","size":5,"download_url":"https://raw.example/readme"}]"#,
            "https://raw.example/alpha/SKILL.md": "---\nname: alpha\ndescription: Alpha skill\naim-origin: learned\n---\n\nDo alpha.",
            "https://raw.example/alpha/run.sh": "echo alpha"
        ]
        let names = try await SkillHub.install(XCTUnwrap(SkillHub.parse("o/r/pack")), fetch: { url in
            guard let body = responses[url.absoluteString.replacingOccurrences(of: "?ref=", with: "")] else { throw SkillHubError.http(404) }
            return Data(body.utf8)
        }, global: global)
        XCTAssertEqual(names, ["alpha"])
        let proposal = try XCTUnwrap(SkillCatalog.proposals(global: global).first)
        XCTAssertEqual(proposal.origin, "hub:github.com/o/r/pack/alpha", "the author cannot claim to be a learned skill")
        XCTAssertEqual(SkillCatalog.supportingFiles(proposal), ["scripts/run.sh"])
        XCTAssertTrue(SkillCatalog.discover(workspace: nil, global: global).isEmpty, "inactive until accepted")
    }

    func testRealGitHubInstall() async throws {
        guard ProcessInfo.processInfo.environment["AIM_TEST_NETWORK"] == "1" else { throw XCTSkip("set AIM_TEST_NETWORK=1") }
        let global = try temporaryGlobal()
        let names = try await SkillHub.install(XCTUnwrap(SkillHub.parse("anthropics/skills/skills/pdf")), global: global)
        XCTAssertEqual(names, ["pdf"])
        XCTAssertTrue(SkillCatalog.proposals(global: global).first?.origin?.hasPrefix("hub:github.com/anthropics/skills") == true)
    }
}
