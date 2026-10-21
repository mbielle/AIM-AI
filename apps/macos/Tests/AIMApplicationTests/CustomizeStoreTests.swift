import AIMApplication
import XCTest

final class CustomizeStoreTests: XCTestCase {
    func testDecodeSkillsLeaderboard() throws {
        let json = #"{"skills":[{"source":"anthropics/skills","skillId":"pdf","name":"pdf","installs":205542},{"source":"bad","skillId":"x","name":"x"},{"source":"anthropics/skills","skillId":"pdf","name":"pdf"}]}"#
        let skills = try CustomizeStore.decodeSkills(Data(json.utf8))
        XCTAssertEqual(skills.map(\.id), ["anthropics/skills/pdf"], "Invalid sources and duplicates are dropped")
        XCTAssertEqual(skills.first?.installs, 205_542)
    }

    func testDecodeMarketplaceSources() {
        let json = #"{"name":"m","plugins":[{"name":"linear","description":"L","source":"./external_plugins/linear","category":"productivity"},{"name":"figma","description":"F","source":{"source":"url","url":"https://github.com/figma/mcp-server-guide.git","sha":"abc"}},{"name":"sub","description":"S","source":{"source":"git-subdir","url":"https://github.com/o/r.git","path":"packages/x","ref":"main"}}]}"#
        let plugins = CustomizeStore.decodeMarketplace(Data(json.utf8), repository: "anthropics/claude-plugins-official")
        XCTAssertEqual(plugins.map(\.repository), ["anthropics/claude-plugins-official", "figma/mcp-server-guide", "o/r"])
        XCTAssertEqual(plugins.map(\.path), ["external_plugins/linear", "", "packages/x"])
        XCTAssertEqual(plugins[1].ref, "abc")
        XCTAssertEqual(plugins[0].title, "Linear")
    }

    func testDecodeRegistryKeepsRemoteServersOnly() {
        let json = #"{"servers":[{"server":{"name":"io.x/notion","description":"N","remotes":[{"type":"streamable-http","url":"https://x.io/mcp","headers":[{"name":"Authorization","isRequired":true}]}]}},{"server":{"name":"io.y/local","description":"L","packages":[{"registryType":"npm"}]}},{"server":{"name":"io.z/tpl","remotes":[{"type":"sse","url":"https://{tenant}.z.io/sse"}]}}],"metadata":{"nextCursor":"io.x/notion:1"}}"#
        let page = CustomizeStore.decodeRegistry(Data(json.utf8))
        XCTAssertEqual(page.connectors.map(\.url), ["https://x.io/mcp"])
        XCTAssertEqual(page.connectors.first?.auth, .token)
        XCTAssertEqual(page.next, "io.x/notion:1")
    }

    func testCuratedConnectorsAreUniqueAndAddressed() {
        let ids = CustomizeCatalog.connectors.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(CustomizeCatalog.connectors.allSatisfy { $0.soon || $0.url?.hasPrefix("https://") == true })
    }

    /// Real network, opt-in: installs Anthropic's pdf skill into a temporary folder.
    func testRealSkillInstall() async throws {
        guard ProcessInfo.processInfo.environment["AIM_TEST_STORE"] != nil else { throw XCTSkip("opt-in") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aim-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CustomizeStore(cache: folder.appendingPathComponent("cache"))
        let top = try await store.skills(.allTime, page: 0)
        print("TOP skills:", top.prefix(5).map { "\($0.id) \($0.installs ?? 0)" })
        let installed = try await store.install(StoreSkill(source: "anthropics/skills", skillId: "pdf", name: "pdf"), into: folder)
        let files = try FileManager.default.subpathsOfDirectory(atPath: installed.path)
        print("INSTALLED pdf files:", files.count, files.prefix(6))
        let skills = SkillCatalog.scan(folder, source: .global)
        XCTAssertEqual(skills.first?.name, "pdf")
        XCTAssertEqual(skills.first?.origin, "store:anthropics/skills/pdf")
        let plugins = try await store.plugins()
        let linear = try XCTUnwrap(plugins.first { $0.name == "linear" })
        let contents = try await store.contents(linear)
        print("LINEAR plugin:", contents.skillFolders, contents.servers.map(\.url), contents.ignored)
        XCTAssertTrue(contents.servers.contains { $0.url == "https://mcp.linear.app/mcp" })
    }
}
