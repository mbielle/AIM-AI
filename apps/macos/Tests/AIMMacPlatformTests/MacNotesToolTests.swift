import AIMAgentKit
import AIMApplication
import Foundation
@testable import AIMMacPlatform
import XCTest

final class MacNotesToolTests: XCTestCase {
    func testNotesArgumentsAndSensitiveScopeAreValidatedBeforeAutomation() async throws {
        let runner = FixtureNotesRunner()
        let service = MacNotesToolService(runner: runner)
        let invalid: [(String, [String: String])] = [
            ("notes_list", ["limit": "101"]),
            ("notes_search", ["query": ""]),
            ("notes_get", ["id": ""]),
            ("notes_create", ["title": "", "body": "Text"]),
            ("notes_replace", ["id": "one", "expected_modified": "now", "title": "T"]),
            ("notes_append", ["id": "one", "expected_modified": "now", "text": ""]),
            ("notes_delete", ["id": "one"])
        ]
        for (name, arguments) in invalid {
            let result = await service.execute(ToolRequest(name: name, arguments: arguments,
                risk: name.hasPrefix("notes_") ? .computerAction : .computerRead))
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.content.contains("Invalid Notes"), result.content)
        }
        let scripts = await runner.scripts
        XCTAssertTrue(scripts.isEmpty)
        let observe = try service.missionIntent(for: ToolRequest(name: "notes_get",
            arguments: ["id": "one"], risk: .computerRead))
        XCTAssertEqual(observe?.operation, .observe)
        XCTAssertEqual(observe?.target,
            try MissionResource(kind: .application, identifier: "com.apple.Notes"))
        let delete = try service.missionIntent(for: ToolRequest(name: "notes_delete",
            arguments: ["id": "one", "expected_modified": "today"], risk: .computerAction))
        XCTAssertEqual(delete?.operation, .permanentDelete)
        XCTAssertTrue(delete?.operation.requiresExactApproval == true)
    }

    func testNotesReadPagesAndMutationsProduceVerifiableResults() async throws {
        let runner = FixtureNotesRunner(rows: [
            [["meta", "2"], ["n1", "First", "today", "f1", "false", "false"]],
            [["n1", "First", "First\nBody", "today", "f1", "0", "false", "false"]],
            [["n2", "New", "New\nBody", "later", "f1", "0", "false", "false"]],
            [["n1", "Changed", "Changed\nBody", "later", "f1", "0", "false", "false"]],
            [["n1", "Changed", "Changed\nBody\nMore", "later", "f1", "0", "false", "false", "Changed\nBody"]],
            [["n1", "0"]]
        ])
        let service = MacNotesToolService(runner: runner)
        let page = await service.execute(ToolRequest(name: "notes_list", arguments: ["limit": "1"], risk: .computerRead))
        XCTAssertFalse(page.isError, page.content)
        XCTAssertTrue(page.content.contains("\"nextOffset\":1"), page.content)
        let detail = await service.execute(ToolRequest(name: "notes_get", arguments: ["id": "n1"], risk: .computerRead))
        XCTAssertFalse(detail.isError, detail.content)
        let create = await service.execute(ToolRequest(name: "notes_create",
            arguments: ["title": "New", "body": "Body"], risk: .computerAction))
        XCTAssertEqual(create.actionOutcome, .confirmed)
        let replace = await service.execute(ToolRequest(name: "notes_replace",
            arguments: ["id": "n1", "expected_modified": "today", "title": "Changed", "body": "Body"],
            risk: .computerAction))
        XCTAssertEqual(replace.actionOutcome, .confirmed)
        let append = await service.execute(ToolRequest(name: "notes_append",
            arguments: ["id": "n1", "expected_modified": "later", "text": "More"], risk: .computerAction))
        XCTAssertEqual(append.actionOutcome, .confirmed)
        let delete = await service.execute(ToolRequest(name: "notes_delete",
            arguments: ["id": "n1", "expected_modified": "later"], risk: .computerAction))
        XCTAssertEqual(delete.actionOutcome, .confirmed)
        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 6)
        XCTAssertTrue(scripts[3].contains("AIM_STALE_NOTE"))
        XCTAssertTrue(scripts[5].contains("delete nt"))
    }

    func testNotesFolderCoverageAndUnverifiedMutationAreExplicit() async {
        let runner = FixtureNotesRunner(rows: [
            [["meta", "2"], ["f1", "Personal", "a1", "false"]],
            [["n2", "Wrong title", "Body", "later", "f1", "0", "false", "false"]]
        ])
        let service = MacNotesToolService(runner: runner)
        let folders = await service.execute(ToolRequest(name: "notes_folders", arguments: [:], risk: .computerRead))
        XCTAssertFalse(folders.isError, folders.content)
        XCTAssertTrue(folders.content.contains("\"truncated\":true"), folders.content)
        let create = await service.execute(ToolRequest(name: "notes_create",
            arguments: ["title": "Requested", "body": "Body"], risk: .computerAction))
        XCTAssertTrue(create.isError)
        XCTAssertEqual(create.actionOutcome, .unknown)
    }

    func testNotesScriptLiteralsCannotBreakOutOfFixedAppleScript() {
        let title = "A \"quoted\" & <tag>"
        let script = NotesScripts.create(title: title, body: "line one\nline two", folderID: nil)
        XCTAssertTrue(script.contains("&amp;"))
        XCTAssertTrue(script.contains("&lt;tag&gt;"))
        XCTAssertTrue(script.contains("&quot;quoted&quot;"))
        XCTAssertFalse(script.contains("line one\nline two"))
        XCTAssertTrue(NotesScripts.literal("x\" & delete every note")
            .contains("\\\" & delete every note"))
    }

    func testFixedNotesScriptsCompileWithoutExecutingAutomation() {
        let scripts = [NotesScripts.folders,
                       NotesScripts.list(folderID: "folder", offset: 0, limit: 10),
                       NotesScripts.search(query: "keyword", folderID: nil, offset: 0, limit: 10),
                       NotesScripts.get(id: "note"),
                       NotesScripts.create(title: "Title", body: "Body", folderID: nil),
                       NotesScripts.replace(id: "note", expectedModified: "today", title: "Title", body: "Body"),
                       NotesScripts.append(id: "note", expectedModified: "today", text: "More"),
                       NotesScripts.delete(id: "note", expectedModified: "today")]
        for body in scripts {
            let source = "\(NotesScripts.safeText)\nwith timeout of 30 seconds\n\(body)\nend timeout"
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
        }
    }
}

private actor FixtureNotesRunner: MacAutomationScriptRunning {
    private var replies: [[[String]]]
    var scripts: [String] = []
    init(rows: [[[String]]] = []) { replies = rows }
    func run(_ script: String, helpers: String, timeoutSeconds: Int) throws -> [[String]] {
        guard helpers.contains("on safeText"), timeoutSeconds == 30 else {
            throw NSError(domain: "Invalid Notes runner configuration", code: 1)
        }
        scripts.append(script)
        guard !replies.isEmpty else { throw NSError(domain: "Unexpected Notes call", code: 1) }
        return replies.removeFirst()
    }
}
