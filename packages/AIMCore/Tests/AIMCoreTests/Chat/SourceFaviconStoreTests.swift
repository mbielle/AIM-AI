import XCTest
@testable import AIMCore

private actor IconFixtures {
    private let responses: [String: Data]
    private let fallbackPNG: Data?
    private(set) var calls: [URL] = []
    init(_ responses: [String: Data], fallbackPNG: Data? = nil) { self.responses = responses; self.fallbackPNG = fallbackPNG }
    func load(_ url: URL, html: Bool) async -> SourceFaviconStore.FixtureResponse? {
        calls.append(url)
        try? await Task.sleep(for: .milliseconds(10))
        guard let data = responses[url.absoluteString] ?? (!html && url.path == "/favicon.ico" ? fallbackPNG : nil) else { return nil }
        return .init(data: data, finalURL: url)
    }
}

final class SourceFaviconStoreTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="3" fill="#123456"/><circle cx="8" cy="8" r="3" fill="#ff0000"/></svg>"##
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "aim-icon-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertDeclaredLogo(_ html: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let site = "https://declarations.example/"
        let good = site + "correct.png"
        // Every lure is renderable: selecting it must fail the requested-URL assertions.
        let fixtures = IconFixtures([
            site: Data(html.utf8), good: png, site + "decoy.png": png,
            site + "style.css": png, site + "commented.png": png
        ])
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        let icon = await store.icon(domain: "declarations.example")
        let expected = try XCTUnwrap(SourceFaviconStore.normalizedIcon(png), file: file, line: line)
        XCTAssertEqual(icon, expected, file: file, line: line)
        let calls = await fixtures.calls.map(\.absoluteString)
        XCTAssertEqual(calls, [site + "favicon.ico", site, good], file: file, line: line)
    }

    func testDataHrefCannotReplaceRealHref() async throws {
        try await assertDeclaredLogo(#"<link rel="icon" data-href="/decoy.png" href="/correct.png">"#)
    }

    func testDataRelCannotTurnStylesheetIntoIcon() async throws {
        try await assertDeclaredLogo(#"<link data-rel="icon" rel="stylesheet" href="/style.css"><link rel="icon" href="/correct.png">"#)
    }

    func testCommentedLinkCannotReplaceActiveIcon() async throws {
        try await assertDeclaredLogo(#"<!-- <link rel="icon" href="/commented.png"> --><link rel="icon" href="/correct.png">"#)
    }

    func testDeclarationAttributeCaseOrderAndQuoting() async throws {
        for html in [
            #"<LINK HREF='/correct.png' TYPE='image/png' REL='shortcut ICON'>"#,
            #"<link href=/correct.png rel=icon>"#,
            #"<link title="a > b" rel="icon" href="/correct.png">"#,
            #"<link title='rel="icon" href="/decoy.png"' rel="stylesheet" href="/style.css"><link rel="icon" href="/correct.png">"#,
            #"<div title='<link rel="icon" href="/decoy.png">'></div><link rel="icon" href="/correct.png">"#,
            #"<script>const lure = '<link rel="icon" href="/decoy.png">';</ScRiPt><link rel="icon" href="/correct.png">"#,
            #"<style>/* <link rel="icon" href="/decoy.png"> */</style><link rel="icon" href="/correct.png">"#,
            #"<textarea><link rel="icon" href="/decoy.png"></textarea><link rel="icon" href="/correct.png">"#,
            #"<!-- title=" --><link rel="icon" href="/correct.png">"#,
            #"<linkage rel="icon" href="/decoy.png"><link rel="icon" href="/correct.png">"#
        ] {
            try await assertDeclaredLogo(html)
        }
    }

    func testExactTypeNamePreservesRasterPriority() async throws {
        try await assertDeclaredLogo(#"<link rel="icon" data-type="image/svg+xml" type="image/png" href="/correct.png"><link rel="icon" href="/decoy.png">"#)
    }

    func testParserKeepsByteAndLinkLimitsAndIgnoresUnclosedMarkup() {
        let icon = #"<link rel="icon" href="/correct.png">"#
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: Data((String(repeating: " ", count: 1_048_576) + icon).utf8)), [])
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: String(repeating: " ", count: 1_048_576) + icon), [])
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: String(repeating: #"<link rel="stylesheet" href="/style.css">"#, count: 256) + icon), [])
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: "<!-- " + icon), [])
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: #"<link title="unfinished > <link rel='icon' href='/decoy.png'>"#), [])
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: #"<link rel="icon" rel="stylesheet" href="/correct.png" href="/decoy.png">"#), ["/correct.png"])
    }

    func testStoreFetchesAtMostFourDeclaredCandidates() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let site = "https://candidate-limit.example/"
        let html = (1...5).map { "<link rel=\"icon\" href=\"/candidate\($0).png\">" }.joined()
        let fixtures = IconFixtures([site: Data(html.utf8), site + "candidate5.png": png])
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        let result = await store.icon(domain: "candidate-limit.example")
        XCTAssertNil(result)
        let calls = await fixtures.calls.map(\.absoluteString)
        XCTAssertEqual(calls, ["favicon.ico", "", "candidate1.png", "candidate2.png", "candidate3.png", "candidate4.png", "apple-touch-icon.png", "favicon.png"].map { site + $0 })
    }

    func testGitHubProjectRelativeRasterAndExplicitCDNAreFetchedWithoutDirectoryService() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let page = "https://microsoft.github.io/AI_Agents_Hackathon/winners/"
        let asset = "https://microsoft.github.io/AI_Agents_Hackathon/assets/images/favicon.png"
        let fixtures = IconFixtures([
            page: Data(#"<link rel="icon" href="../assets/images/favicon.png">"#.utf8), asset: png
        ])
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        let icon = await store.icon(url: URL(string: page + "?token=private#account")!)
        XCTAssertTrue(try XCTUnwrap(icon).starts(with: [0x89,0x50,0x4e,0x47]))
        let calls = await fixtures.calls
        XCTAssertTrue(calls.contains(URL(string: asset)!))
        XCTAssertTrue(calls.allSatisfy { $0.query == nil && $0.fragment == nil && $0.host == "microsoft.github.io" })

        let cdnRoot = try folder(); defer { try? FileManager.default.removeItem(at: cdnRoot) }
        let site = "https://source.example/"
        let cdn = "https://assets.cdn.example/brand.png?v=3"
        let cdnFixtures = IconFixtures([site: Data("<link rel=\"icon\" href=\"\(cdn)\">".utf8), cdn: png])
        let cdnStore = SourceFaviconStore(folder: cdnRoot, fixture: { await cdnFixtures.load($0, html: $1) })
        let cdnIcon = await cdnStore.icon(domain: "source.example")
        XCTAssertNotNil(cdnIcon)
        let cdnCalls = await cdnFixtures.calls
        XCTAssertTrue(cdnCalls.contains(URL(string: cdn)!))
        XCTAssertTrue(cdnCalls.allSatisfy { ["source.example", "assets.cdn.example"].contains($0.host ?? "") })
    }

    func testRasterWinsOverSVGAndSVGOnlySiteIsRasterizedLocally() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let site = "https://icons.example/"
        let html = Data(#"<link rel="icon" href="/logo.svg"><link rel="apple-touch-icon" href="/raster.png">"#.utf8)
        let fixtures = IconFixtures([site: html, site + "logo.svg": Data(svg.utf8), site + "raster.png": png])
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        let first = await store.icon(domain: "icons.example")
        XCTAssertNotNil(first)
        let calls = await fixtures.calls
        XCTAssertFalse(calls.contains(URL(string: site + "logo.svg")!))

        let svgRoot = try folder(); defer { try? FileManager.default.removeItem(at: svgRoot) }
        let svgSite = "https://svg-only.example/"
        let svgFixtures = IconFixtures([svgSite: Data(#"<link rel="icon" type="image/svg+xml" href="/favicon.svg">"#.utf8), svgSite + "favicon.svg": Data(svg.utf8)])
        let svgStore = SourceFaviconStore(folder: svgRoot, fixture: { await svgFixtures.load($0, html: $1) })
        let renderedData = await svgStore.icon(domain: "svg-only.example")
        let rendered = try XCTUnwrap(renderedData)
        XCTAssertTrue(SourceFaviconStore.isRenderableImage(rendered))
        XCTAssertTrue(rendered.starts(with: [0x89,0x50,0x4e,0x47]))
    }

    func testHostileAssetURLsAndCrossOriginRedirectResponseAreRejected() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let page = URL(string: "https://source.example/")!
        for value in ["http://cdn.example/x.png", "https://127.0.0.1/x.png", "https://lan.local/x.png", "data:image/svg+xml,evil", "https://user:pass@cdn.example/x.png", "https://cdn.example/x.png?access_token=secret"] {
            XCTAssertNil(SourceFaviconStore.iconURL(value, relativeTo: page), value)
        }
        let store = SourceFaviconStore(folder: root, fixture: { url, _ in
            .init(data: Data([0x89,0x50,0x4e,0x47]), finalURL: URL(string: "https://unannounced.example/x.png")!)
        })
        let value = await store.icon(url: page)
        XCTAssertNil(value)
    }

    func testConcurrentSamePageCoalescesAndCacheDoesNotRefetch() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = IconFixtures([:], fallbackPNG: png)
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        let results = await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
            for _ in 0..<24 { group.addTask { await store.icon(domain: "coalesced.example") } }
            var all: [Data?] = []; for await value in group { all.append(value) }; return all
        }
        XCTAssertEqual(results.count, 24); XCTAssertTrue(results.allSatisfy { $0 != nil && $0 == results.first! })
        let firstCalls = await fixtures.calls
        XCTAssertEqual(firstCalls.count, 1)
        let cached = await store.icon(domain: "coalesced.example")
        XCTAssertNotNil(cached)
        let after = await fixtures.calls
        XCTAssertEqual(after.count, 1)
    }

    func testCacheMemoryAndDiskStayBounded() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = IconFixtures([:], fallbackPNG: png)
        let store = SourceFaviconStore(folder: root, fixture: { await fixtures.load($0, html: $1) })
        for index in 0..<65 { _ = await store.icon(domain: "icon\(index).example") }
        let first = URL(string: "https://icon0.example/")!
        try FileManager.default.removeItem(at: root.appending(path: SourceFaviconStore.cacheKey(for: first) + ".icon"))
        _ = await store.icon(url: first)
        let firstCalls = await fixtures.calls.filter { $0.host == "icon0.example" }
        XCTAssertEqual(firstCalls.count, 2, "The oldest PNG must leave the 64-entry memory cache")
        for index in 65..<132 { _ = await store.icon(domain: "icon\(index).example") }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(files.count, 128)
    }
}
