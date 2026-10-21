import XCTest
import CryptoKit
@testable import AIMCore

final class SourceCitationTests: XCTestCase {
    private let sources = [ConversationSource(url: "https://www.openai.com/a", title: "A", references: [1])!,
                           ConversationSource(url: "https://infoq.com/b", title: "B", references: [2])!,
                           ConversationSource(url: "https://openrouter.ai/c", title: "C", references: [3])!]

    func testAdjacentReferencesBecomeOneDomainPill() throws {
        let text = ConversationSourceProjection(text: "Price [1][2]. Beta [3], [1]. Alone [2]. Unknown [9]. Code `[1]`.", sources: sources).citedText
        XCTAssertTrue(text.contains("[\u{202F}openai.com\u{202F}+1\u{202F}](aim-source://1-2)"), text)
        XCTAssertTrue(text.contains("[\u{202F}openrouter.ai\u{202F}+1\u{202F}](aim-source://3-1)"), text)
        XCTAssertTrue(text.contains("[\u{202F}infoq.com\u{202F}](aim-source://2)"), text)
        XCTAssertTrue(text.contains("Unknown [9]"))
        XCTAssertTrue(text.contains("`[1]`"))
        let url = try XCTUnwrap(URL(string: "aim-source://3-1"))
        XCTAssertEqual(SourceCitationLink.numbers(url), [3, 1])
        XCTAssertEqual(SourceCitationLink.sources(url, in: sources).map(\.displayDomain), ["openrouter.ai", "openai.com"])
    }

    func testSiteDomainKeepsTheRegistrableName() {
        XCTAssertEqual(ConversationSource(url: "https://developers.openai.com/x")!.siteDomain, "openai.com")
        XCTAssertEqual(ConversationSource(url: "https://www.bbc.co.uk/news")!.siteDomain, "bbc.co.uk")
        XCTAssertEqual(ConversationSource(url: "https://infoq.com/a")!.siteDomain, "infoq.com")
        XCTAssertEqual(ConversationSource(url: "https://192.168.1.10/a")!.siteDomain, "192.168.1.10")
    }

    func testLinksArraysAndFencesStayUntouched() {
        let text = "See [1](https://x.dev) and [a][1].\n```\nlet x = a[1]\n```"
        XCTAssertEqual(ConversationSourceProjection(text: text, sources: sources).citedText, text)
    }

    func testDeclaredIconAndImageSignatures() {
        XCTAssertEqual(SourceFaviconStore.declaredIcon(in: #"<head><link rel="stylesheet" href="a.css"><link href='/i.png' rel="shortcut icon"></head>"#), "/i.png")
        XCTAssertEqual(SourceFaviconStore.declaredIcon(in: #"<link rel="icon" href="/i.svg">"#), "/i.svg")
        XCTAssertTrue(SourceFaviconStore.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])))
        XCTAssertTrue(SourceFaviconStore.isImage(Data([0x00, 0x00, 0x01, 0x00, 0x01])))
        XCTAssertFalse(SourceFaviconStore.isImage(Data("<html>".utf8)))
    }

    func testIconsAreCachedOnDiskAndInvalidDomainsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Self.png
        let key = SourceFaviconStore.cacheKey(for: URL(string: "https://example.com/")!)
        try png.write(to: folder.appending(path: key + ".icon"))
        let store = SourceFaviconStore(folder: folder)
        let cached = await store.icon(domain: "Example.com")
        XCTAssertEqual(cached, png)
        let invalid = await store.icon(domain: "../etc")
        XCTAssertNil(invalid)
    }
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testPageRelativeIconsAndMultipleRasterCandidates() throws {
        let html = #"<link rel="icon" href="logo.svg?v=1"><link rel="icon" href="missing.ico"><link rel="apple-touch-icon" href="../images/icon.png?a=1&amp;b=2">"#
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: html), ["missing.ico", "../images/icon.png?a=1&amp;b=2", "logo.svg?v=1"])
        let page = try XCTUnwrap(URL(string: "https://microsoft.github.io/project/docs/"))
        XCTAssertEqual(SourceFaviconStore.iconURL("../images/icon.png?a=1&amp;b=2", relativeTo: page)?.absoluteString,
                       "https://microsoft.github.io/project/images/icon.png?a=1&b=2")
        XCTAssertEqual(SourceFaviconStore.iconURL("https://cdn.example.com/icon.png", relativeTo: page)?.host, "cdn.example.com")
        XCTAssertNil(SourceFaviconStore.iconURL("https://cdn.example.com/icon.png?access_token=secret", relativeTo: page))
        XCTAssertNil(SourceFaviconStore.iconURL("http://microsoft.github.io/icon.png", relativeTo: page))
    }

    func testIconRequestsRejectPrivateLiteralsAndRemovePageSecrets() throws {
        for value in ["https://127.0.0.1/i", "https://192.168.1.2/i", "https://[::1]/i", "https://mac.local/i", "https://x.internal/i", "https://a.example:8443/i", "https://user:pass@example.com/i"] {
            XCTAssertFalse(SourceFaviconStore.allowedURL(try XCTUnwrap(URL(string: value))), value)
        }
        let page = try XCTUnwrap(URL(string: "https://microsoft.github.io/project/?token=secret#private"))
        XCTAssertEqual(SourceFaviconStore.pageURL(page)?.absoluteString, "https://microsoft.github.io/project/")
        XCTAssertTrue(SourceFaviconStore.isRenderableImage(Self.png))
        XCTAssertFalse(SourceFaviconStore.isRenderableImage(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    func testResolvedPrivateAndMappedAddressesCannotBecomeIconTargets() {
        for bytes: [UInt8] in [[127,0,0,1], [10,0,0,3], [172,16,0,2], [169,254,1,1], [192,168,1,10], [100,64,0,1], [0,0,0,0], [224,0,0,1]] {
            XCTAssertFalse(SourceFaviconStore.publicIPv4(bytes))
        }
        XCTAssertTrue(SourceFaviconStore.publicIPv4([8,8,8,8]))
        XCTAssertFalse(SourceFaviconStore.publicIPv6(Array(repeating: 0, count: 15) + [1]))
        XCTAssertFalse(SourceFaviconStore.publicIPv6(Array(repeating: 0, count: 10) + [255,255,192,168,1,2]))
        XCTAssertTrue(SourceFaviconStore.publicIPv6([0x26,0x06,0x47,0x00] + Array(repeating: 0, count: 11) + [1]))
    }

    func testLargePublicPageFindsLateFaviconButStopsAtOneMiB() {
        // Databricks currently declares its PNG after 512 KiB of inline page data.
        let declaration = #"<link rel="icon" href="/en-website-assets/favicon-32x32.png">"#
        let inside = Data((String(repeating: " ", count: 800_000) + declaration).utf8)
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: inside), ["/en-website-assets/favicon-32x32.png"])
        let beyond = Data((String(repeating: " ", count: 1_048_576) + declaration).utf8)
        XCTAssertEqual(SourceFaviconStore.declaredIcons(in: beyond), [])
    }

}
