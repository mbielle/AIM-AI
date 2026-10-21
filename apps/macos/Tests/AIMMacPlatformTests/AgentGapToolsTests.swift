import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class AgentGapToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-gaps-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func load() {\n    let value = 1\n    print(value)\n}\n".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try "obsolete\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    // MARK: Patch

    func testEnvelopePatchAppliesAllFilesTogetherAndUndoes() async throws {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.swift
        @@ func load
             let value = 1
        -    print(value)
        +    print(value + 1)
        *** Add File: src/b.swift
        +let b = 2
        *** Delete File: old.txt
        *** End Patch
        """
        let changes = try WorkspacePatch.parse(patch)
        XCTAssertEqual(changes.map(\.path), ["src/a.swift", "src/b.swift", "old.txt"])
        let service = WorkspaceEditService()
        let proposal = try await service.preparePatch(workspace: root.path, changes: changes)
        XCTAssertEqual(proposal.files.count, 3)
        XCTAssertEqual(read("src/a.swift")?.contains("value + 1"), false, "preparing writes nothing")
        try await service.applyPatch(proposal.id)
        XCTAssertEqual(read("src/a.swift"), "func load() {\n    let value = 1\n    print(value + 1)\n}\n")
        XCTAssertEqual(read("src/b.swift"), "let b = 2\n")
        XCTAssertNil(read("old.txt"))
        try await service.undoPatch(proposal.id)
        XCTAssertEqual(read("src/a.swift")?.contains("print(value)\n"), true)
        XCTAssertNil(read("src/b.swift"))
        XCTAssertEqual(read("old.txt"), "obsolete\n")
    }

    func testUnifiedDiffWithLooseWhitespaceAndStaleFiles() async throws {
        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,4 +1,4 @@
         func load() {
        -    let value = 1
        +    let value = 2
             print(value)
         }
        """
        let changes = try WorkspacePatch.parse(diff)
        let service = WorkspaceEditService()
        let proposal = try await service.preparePatch(workspace: root.path, changes: changes)
        try "changed meanwhile\n".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        do { try await service.applyPatch(proposal.id); XCTFail("stale file") }
        catch { XCTAssertEqual(read("src/a.swift"), "changed meanwhile\n") }

        let missing = try WorkspacePatch.parse("*** Begin Patch\n*** Update File: src/a.swift\n@@\n-not there\n+x\n*** End Patch")
        do { _ = try await service.preparePatch(workspace: root.path, changes: missing); XCTFail("context") }
        catch let error as WorkspacePatch.PatchError { guard case .contextNotFound = error else { return XCTFail("\(error)") } }
        XCTAssertThrowsError(try WorkspacePatch.parse("*** Begin Patch\n*** Update File: a\n*** Move to: b\n*** End Patch"))
    }

    func testMultipleEditsInOneFileAndNoSixteenEditCeiling() async throws {
        let service = WorkspaceEditService()
        let proposal = try await service.prepare(workspace: root.path, path: "src/a.swift",
            edits: [(old: "func load()", new: "func reload()"), (old: "print(value)", new: "debugPrint(value)")])
        try await service.apply(proposal.id)
        XCTAssertEqual(read("src/a.swift"), "func reload() {\n    let value = 1\n    debugPrint(value)\n}\n")
        do { _ = try await service.prepare(workspace: root.path, path: "src/a.swift", edits: [(old: "func reload() {", new: "x"), (old: "reload", new: "y")]); XCTFail("overlap") }
        catch {}
        for index in 0..<24 {
            let next = try await service.prepare(workspace: root.path, path: "src/a.swift",
                edits: [(old: "let value = \(index + 1)", new: "let value = \(index + 2)")])
            try await service.apply(next.id)
        }
        XCTAssertEqual(read("src/a.swift")?.contains("let value = 25"), true)
    }

    // MARK: Search

    func testRegexSearch() async throws {
        let service = WorkspaceFileToolService()
        let result = try await service.searchText(#"func\s+lo\w+\("#, workspace: root.path, regex: true)
        XCTAssertEqual(result.matches.map(\.path), ["src/a.swift"])
        let literal = try await service.searchText("func\\s", workspace: root.path)
        XCTAssertTrue(literal.matches.isEmpty, "literal by default")
        do { _ = try await service.searchText("(unclosed", workspace: root.path, regex: true); XCTFail("invalid regex") } catch {}
    }

    // MARK: Checkpoints

    func testCheckpointRestoresChangedDeletedAndCreatedFiles() async throws {
        let store = root.appendingPathComponent("store-\(UUID().uuidString)")
        let trashed = root.deletingLastPathComponent().appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashed); try? FileManager.default.removeItem(at: store) }
        let workspace = root.appendingPathComponent("src")
        let service = WorkspaceCheckpointService(workspace: workspace.path, storeRoot: store, trash: { url in
            try FileManager.default.moveItem(at: url, to: trashed.appendingPathComponent(url.lastPathComponent))
        })
        let first = try await service.checkpoint(label: "Before turn 1")
        let unchanged = try await service.checkpoint(label: "No change")
        XCTAssertEqual(unchanged, first, "unchanged files reuse the checkpoint")
        try "broken\n".write(to: workspace.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "new\n".write(to: workspace.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
        let outcome = try await service.restore(first)
        XCTAssertEqual(read("src/a.swift")?.hasPrefix("func load()"), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("new.swift").path))
        XCTAssertEqual(outcome.trashed, ["new.swift"])
        let listed = try await service.list()
        XCTAssertEqual(listed.count, 2, "the pre-restore state is itself a checkpoint")
        _ = try await service.restore(outcome.safety)
        XCTAssertEqual(read("src/a.swift"), "broken\n", "the restore can be undone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path), "nothing is written in the project")
    }

    // MARK: Web search parsers

    func testSearchResultParsers() {
        let html = """
        <tr><td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocs&amp;rut=x" class='result-link'>Swift <b>Docs</b></a></td></tr>
        <tr><td class='result-snippet'>The Swift &amp; docs.</td></tr>
        """
        let results = AgentWebSearchToolService.parseDuckDuckGoLite(html)
        XCTAssertEqual(results, [.init(title: "Swift Docs", url: "https://swift.org/docs", snippet: "The Swift & docs.")])
        let perplexity = Data(#"{"results":[{"title":"A","url":"https://a.example","snippet":"s"},{"title":"bad","url":"file:///etc"}]}"#.utf8)
        XCTAssertEqual(AgentWebSearchToolService.parsePerplexity(perplexity).map(\.url), ["https://a.example"])
        let openRouter = Data(#"{"choices":[{"message":{"content":"x","annotations":[{"type":"url_citation","url_citation":{"url":"https://b.example","title":"B","content":"c"}},{"type":"url_citation","url_citation":{"url":"https://b.example","title":"dup"}}]}}]}"#.utf8)
        XCTAssertEqual(AgentWebSearchToolService.parseOpenRouterAnnotations(openRouter).map(\.title), ["B"])
    }

    func testSearchWithoutBackendsExplainsHowToEnableIt() async {
        let service = AgentWebSearchToolService(backends: .init(allowKeyless: false))
        let result = await service.execute(ToolRequest(name: "web_search", arguments: ["query": "swift"], risk: .externalEffect))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Perplexity or OpenRouter key"))
    }
}
