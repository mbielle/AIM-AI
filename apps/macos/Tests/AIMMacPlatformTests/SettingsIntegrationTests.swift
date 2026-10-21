@testable import AIMMacPlatform
import XCTest

final class SettingsIntegrationTests: XCTestCase {
    func testBlockedSitesCoverSubdomainsOnly() {
        XCTAssertEqual(IntegrationPreferences.normalizedSite("https://www.Example.com/path?q=1"), "example.com")
        XCTAssertEqual(IntegrationPreferences.normalizedSite("news.site.org"), "news.site.org")
        XCTAssertNil(IntegrationPreferences.normalizedSite("not a site"))
        XCTAssertNil(IntegrationPreferences.normalizedSite("localhost"))
        let blocked = ["example.com"]
        XCTAssertTrue(IntegrationPreferences.isBlocked(host: "example.com", blocked: blocked))
        XCTAssertTrue(IntegrationPreferences.isBlocked(host: "shop.Example.com", blocked: blocked))
        XCTAssertFalse(IntegrationPreferences.isBlocked(host: "notexample.com", blocked: blocked))
        XCTAssertTrue(IntegrationPreferences.validBranchPrefix("aim/"))
        XCTAssertTrue(IntegrationPreferences.validBranchPrefix("team/me-"))
        XCTAssertFalse(IntegrationPreferences.validBranchPrefix("../x"))
        XCTAssertFalse(IntegrationPreferences.validBranchPrefix("-x"))
        XCTAssertFalse(IntegrationPreferences.validBranchPrefix("a b"))
    }

    func testHookConfigurationRoundTripsToItsFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "aim-hooks-\(UUID().uuidString)/hooks.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(AgentHookRunner.readConfiguration(file), .init())
        let configuration = AgentHookRunner.Configuration(
            hooks: [.init(event: "PreToolUse", matcher: "run_command", command: "/usr/local/bin/check", timeout: 20)],
            trusted_projects: ["/Users/example/repo"])
        try AgentHookRunner.writeConfiguration(configuration, to: file)
        XCTAssertEqual(AgentHookRunner.readConfiguration(file), configuration)
        XCTAssertEqual(AgentHookRunner.load(workspace: nil, globalFile: file)?.hooks.first?.command, "/usr/local/bin/check")
    }

    func testImportScannerFindsOtherAppsSetups() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "aim-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ path: String, _ text: String) throws {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(".claude/CLAUDE.md", "Prefer small commits.")
        try write(".claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: PDFs\n---\nUse it.")
        try write(".claude.json", #"{"mcpServers":{"github":{"command":"npx","args":["-y","@x/github"],"env":{"TOKEN":"abc"}},"docs":{"url":"https://mcp.example.com/sse"}}}"#)
        try write(".codex/config.toml", """
        model = "gpt-6"
        [mcp_servers.files]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]  # comment
        [mcp_servers.files.env]
        ROOT = "/tmp"
        [mcp_servers."remote"]
        url = "https://remote.example.com/mcp"
        [profiles.fast]
        model = "x"
        """)
        let sources = AIImportScanner.scan(home: home)
        let claude = try XCTUnwrap(sources.first { $0.kind == .claudeCode })
        XCTAssertEqual(claude.instructions?.text, "Prefer small commits.")
        XCTAssertEqual(claude.skillDirectories.map(\.lastPathComponent), ["pdf"])
        XCTAssertEqual(claude.servers.map(\.name), ["docs", "github"])
        XCTAssertEqual(claude.servers.last?.arguments, ["-y", "@x/github"])
        XCTAssertEqual(claude.servers.last?.environment, ["TOKEN": "abc"])
        let codex = try XCTUnwrap(sources.first { $0.kind == .codex })
        XCTAssertEqual(codex.servers.map(\.name), ["files", "remote"])
        XCTAssertEqual(codex.servers.first?.arguments, ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        XCTAssertEqual(codex.servers.first?.environment, ["ROOT": "/tmp"])
        XCTAssertEqual(codex.servers.last?.url, "https://remote.example.com/mcp")
        XCTAssertNil(sources.first { $0.kind == .cursor })
    }

    func testChatExportsFromChatGPTAndClaude() throws {
        let chatGPT = Data("""
        [{"title":"Trip","create_time":1700000000,"current_node":"c","mapping":{
          "root":{"parent":null,"children":["a"],"message":null},
          "a":{"parent":"root","children":["b","x"],"message":{"author":{"role":"user"},"content":{"parts":["Plan Lisbon"]}}},
          "x":{"parent":"a","children":[],"message":{"author":{"role":"assistant"},"content":{"parts":["Old branch"]}}},
          "b":{"parent":"a","children":["c"],"message":{"author":{"role":"system"},"content":{"parts":["hidden"]}}},
          "c":{"parent":"b","children":[],"message":{"author":{"role":"assistant"},"content":{"parts":["Day 1: Alfama"]}}}}}]
        """.utf8)
        let first = try XCTUnwrap(ChatExportReader.parse(chatGPT).first)
        XCTAssertEqual(first.title, "Trip")
        XCTAssertEqual(first.messages, [.init(isUser: true, text: "Plan Lisbon"), .init(isUser: false, text: "Day 1: Alfama")])
        let claude = Data(#"[{"name":"","created_at":"2026-01-02T10:00:00Z","chat_messages":[{"sender":"human","text":"Hi"},{"sender":"assistant","text":"","content":[{"type":"text","text":"Hello"}]}]}]"#.utf8)
        let second = try XCTUnwrap(ChatExportReader.parse(claude).first)
        XCTAssertEqual(second.title, "Imported conversation")
        XCTAssertEqual(second.messages.map(\.text), ["Hi", "Hello"])
        XCTAssertNotNil(second.createdAt)
        XCTAssertThrowsError(try ChatExportReader.parse(Data("{}".utf8)))
    }
}

/// Opt-in, read only: AIM_TEST_IMPORT_SCAN=1 lists what the real Mac offers (counts only).
final class ImportScanRealTests: XCTestCase {
    func testRealMacScanReadsWithoutChangingAnything() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIM_TEST_IMPORT_SCAN"] == "1", "Set AIM_TEST_IMPORT_SCAN=1")
        for source in AIImportScanner.scan() {
            print("[import-scan] \(source.name): instructions=\(source.instructions != nil) skills=\(source.skillDirectories.count) servers=\(source.servers.count)")
        }
    }
}
