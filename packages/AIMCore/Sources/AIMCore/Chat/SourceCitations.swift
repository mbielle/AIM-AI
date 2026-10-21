import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

public extension ConversationSource {
    /// The domain as people read it: "openai.com" rather than "www.openai.com".
    var displayDomain: String { domain.lowercased().hasPrefix("www.") ? String(domain.dropFirst(4)) : domain }

    /// The site name for a citation pill: "openai.com" for "developers.openai.com",
    /// keeping country suffixes such as "bbc.co.uk".
    var siteDomain: String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2, labels.allSatisfy({ !$0.isEmpty }), Int(labels.last!) == nil else { return displayDomain }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "gouv", "ac", "edu", "ne", "or"]
        let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// Citation pills: adjacent references such as "[1][2]" or "[1], [3]" become one link whose
/// text names the first source's domain ("openai.com +1") and whose URL lists every number.
public enum SourceCitationLink {
    public static let scheme = "aim-source"

    /// The reference numbers of a pill link, in order; empty for any other URL.
    public static func numbers(_ url: URL) -> [Int] {
        guard url.scheme == scheme else { return [] }
        return (url.host ?? "").split(separator: "-").compactMap { Int($0) }
    }

    /// The sources a pill names, in the order of its numbers.
    public static func sources(_ url: URL, in sources: [ConversationSource]) -> [ConversationSource] {
        var result: [ConversationSource] = []
        for number in numbers(url) {
            if let source = sources.first(where: { $0.references?.contains(number) == true }), !result.contains(source) { result.append(source) }
        }
        return result
    }
}

public extension ConversationSourceProjection {
    /// The answer with every recognised group of references turned into one pill link.
    /// Code spans and fenced blocks are left untouched; unknown numbers stay plain text.
    var citedText: String {
        let known = Set(sources.flatMap { $0.references ?? [] })
        // One or more "[n]" (or "[n, m]") separated by nothing, spaces or commas.
        let group = try! NSRegularExpression(pattern: #"(?<![\\\[\]])\[\d+(?:\s*,\s*\d+)*\](?:[ ,]*\[\d+(?:\s*,\s*\d+)*\])*(?![(:\[])"#)
        let number = try! NSRegularExpression(pattern: #"\d+"#)
        var fenced = false
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return line }
            guard !fenced else { return line }
            return line.components(separatedBy: "`").enumerated().map { index, span in
                guard index % 2 == 0 else { return span }
                var value = span
                for match in group.matches(in: span, range: NSRange(span.startIndex..., in: span)).reversed() {
                    guard let range = Range(match.range, in: span) else { continue }
                    let piece = String(span[range])
                    var numbers: [Int] = []
                    for found in number.matches(in: piece, range: NSRange(piece.startIndex..., in: piece)) {
                        if let r = Range(found.range, in: piece), let n = Int(piece[r]), known.contains(n), !numbers.contains(n) { numbers.append(n) }
                    }
                    let cited = numbers.compactMap { n in sources.first { $0.references?.contains(n) == true } }
                    guard let first = cited.first, let target = Range(match.range, in: value) else { continue }
                    let others = Set(cited.map(\.id)).count - 1
                    // Narrow no-break spaces pad the pill and keep it on one line.
                    let label = first.siteDomain.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") + (others > 0 ? "\u{202F}+\(others)" : "")
                    value.replaceSubrange(target, with: "[\u{202F}\(label)\u{202F}](\(SourceCitationLink.scheme)://\(numbers.map(String.init).joined(separator: "-")))")
                }
                return value
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }
}

/// Icons come from the cited site or HTTPS assets explicitly declared by its page,
/// never an icon-directory/proxy service. Raster declarations precede static SVG.
/// Cookies/referrers are omitted; bounded public requests produce small local PNGs.
public actor SourceFaviconStore {
    public static let shared = SourceFaviconStore()
    private let folder: URL
    private let session: URLSession
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private let fixture: (@Sendable (URL, Bool) async -> FixtureResponse?)?
    struct FixtureResponse: Sendable { let data: Data; let finalURL: URL; var status = 200 }
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private static let maximumBytes = 262_144
    private static let maximumHTMLBytes = 1_048_576

    public init(folder: URL? = nil, session: URLSession? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AIMSourceIcons")
        fixture = nil
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
            self.session = AIMManagedNetworkSession.make(configuration: configuration, delegate: SourceIconRedirectPolicy())
        }
    }

    /// Injected in-memory HTTP responses for deterministic tests; no DNS/socket is opened.
    init(folder: URL, fixture: @escaping @Sendable (URL, Bool) async -> FixtureResponse?) {
        self.folder = folder; self.fixture = fixture
        session = URLSession(configuration: .ephemeral)
    }

    public func icon(domain raw: String) async -> Data? {
        guard let url = URL(string: "https://\(raw.lowercased())/"), url.host?.lowercased() == raw.lowercased(), Self.allowedURL(url) else { return nil }
        return await icon(url: url)
    }

    static func cacheKey(for page: URL) -> String {
        "v3-s\(StaticSVGIconRenderer.version)-" + SHA256.hash(data: Data(page.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Exact-page cache, coalesced per key. At most 32 lookups wait/run (four active), 64 PNGs remain
    /// in memory and 128 recent files on disk; failures expire after five minutes.
    public func icon(url source: URL) async -> Data? {
        guard let page = Self.pageURL(source) else { return nil }
        let key = Self.cacheKey(for: page)
        if let cached = memory[key] { remember(cached, key: key); return cached }
        let file = folder.appending(path: key + ".icon")
        if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= Self.maximumBytes,
           let modified = values.contentModificationDate, Date.now.timeIntervalSince(modified) < 604_800,
           let data = try? Data(contentsOf: file), Self.isRenderableImage(data) { remember(data, key: key); return data }
        if let failed = failures[key], Date.now.timeIntervalSince(failed) < 300 { return nil }
        if let running = inFlight[key] { return await running.value }
        guard inFlight.count < 32 else { return nil }
        let task = Task {
            guard await SourceIconLookupSlots.shared.acquire() else { return nil as Data? }
            let value = await fetch(page: page)
            await SourceIconLookupSlots.shared.release()
            return value
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            remember(data, key: key)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            pruneDisk()
        } else if !AIMNetworkPrivacyPolicy.isEnabled {
            failures[key] = .now
            if failures.count > 128, let oldest = failures.min(by: { $0.value < $1.value })?.key { failures[oldest] = nil }
        }
        return data
    }

    private func remember(_ data: Data, key: String) {
        memory[key] = data; memoryOrder.removeAll { $0 == key }; memoryOrder.append(key)
        while memoryOrder.count > 64 { memory[memoryOrder.removeFirst()] = nil }
    }
    private func pruneDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
        let entries = files.compactMap { url -> (URL, Date)? in
            let name = url.deletingPathExtension().lastPathComponent
            let owned = name.hasPrefix("v3-s") || name.hasPrefix("v2-") || (name.contains(".") && name.range(of: #"^[a-z0-9.-]{1,253}$"#, options: .regularExpression) != nil)
            guard owned, url.pathExtension == "icon",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in entries.enumerated() where index >= 128 || Date.now.timeIntervalSince(entry.1) >= 604_800 { try? FileManager.default.removeItem(at: entry.0) }
    }

    private func fetch(page: URL) async -> Data? {
        guard !AIMNetworkPrivacyPolicy.isEnabled, !Task.isCancelled,
              let origin = URL(string: "https://\(page.host!)/") else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        if let data = await download(origin.appending(path: "favicon.ico")) { return data }
        var declared: [(url: URL, svg: Bool)] = [], checked = Set<URL>()
        for document in page == origin ? [page] : [page, origin] {
            guard ContinuousClock.now < deadline else { return nil }
            guard let pageData = await download(document, html: true) else { continue }
            for candidate in Self.declaredCandidates(in: pageData).prefix(4) {
                guard let url = Self.iconURL(candidate.href, relativeTo: document), checked.insert(url).inserted else { continue }
                declared.append((url, candidate.svg))
            }
        }
        // Raster declarations and same-site raster fallbacks precede SVG-only icons.
        let svg = declared.filter(\.svg).map(\.url)
        let raster = declared.filter { !$0.svg }.map(\.url)
        let candidates = raster + ["apple-touch-icon.png", "favicon.png"].map { origin.appending(path: $0) } + svg
        for url in candidates.prefix(10) {
            guard ContinuousClock.now < deadline else { return nil }
            if let data = await download(url) { return data }
        }
        return nil
    }

    private func download(_ url: URL, html: Bool = false) async -> Data? {
        guard !Task.isCancelled, !AIMNetworkPrivacyPolicy.isEnabled, Self.allowedURL(url) else { return nil }
        if let fixture {
            guard let response = await fixture(url, html), !Task.isCancelled, !AIMNetworkPrivacyPolicy.isEnabled,
                  response.status == 200, Self.allowedURL(response.finalURL), Self.sameSite(response.finalURL, url) else { return nil }
            return html ? Data(response.data.prefix(Self.maximumHTMLBytes)) : Self.normalizedIcon(response.data)
        }
        guard let host = url.host, await Self.resolvesPublicly(host), !Task.isCancelled, !AIMNetworkPrivacyPolicy.isEnabled else { return nil }
        var request = URLRequest(url: url)
        request.setValue(html ? "text/html" : "image/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, Self.allowedURL(finalURL), Self.sameSite(finalURL, url) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                if Task.isCancelled { return nil }
                // The managed session cancels network immediately on privacy activation.
                // Avoid taking the persisted-policy lock once for every byte decoded.
                if data.count.isMultiple(of: 4096), AIMNetworkPrivacyPolicy.isEnabled { return nil }
                data.append(byte)
                if data.count > (html ? Self.maximumHTMLBytes : Self.maximumBytes) {
                    return html ? Data(data.prefix(Self.maximumHTMLBytes)) : nil
                }
            }
        } catch { return nil }
        guard !AIMNetworkPrivacyPolicy.isEnabled, !Task.isCancelled else { return nil }
        return html ? data : Self.normalizedIcon(data)
    }

    static func normalizedIcon(_ data: Data) -> Data? {
        guard data.count <= maximumBytes else { return nil }
        if isRenderableImage(data), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) && output.length <= maximumBytes ? output as Data : nil
        }
        return StaticSVGIconRenderer.png(data)
    }

    static func pageURL(_ source: URL) -> URL? {
        guard var parts = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url, allowedURL(url) else { return nil }; return url
    }

    static func allowedURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.utf8.count <= 253, host.contains("."),
              host.range(of: #"^[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil,
              !host.contains(".."), host.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              !host.split(separator: ".").last!.allSatisfy(\.isNumber) else { return false }
        let privateSuffix = [".localhost", ".local", ".internal", ".lan", ".home", ".test", ".invalid"].contains(where: host.hasSuffix)
        let credentials: Set<String> = ["token", "access_token", "refresh_token", "api_key", "apikey", "password", "secret", "client_secret", "authorization", "auth", "signature"]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return !privateSuffix && !query.contains { credentials.contains($0.name.lowercased()) }
    }

    static func sameSite(_ left: URL, _ right: URL) -> Bool {
        func host(_ value: URL) -> String { let name = value.host?.lowercased() ?? ""; return name.hasPrefix("www.") ? String(name.dropFirst(4)) : name }
        return host(left) == host(right)
    }

    /// Reject a public-looking hostname that currently resolves to a private/local address.
    /// This is not DNS pinning: the URL loading system performs its own subsequent lookup.
    static func resolvesPublicly(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let lease = try? AIMNetworkPrivacyPolicy.beginOpaqueOperation("Source icon DNS lookup") else { return false }
            // getaddrinfo has no cancellation acknowledgement. Its actual return releases the fence.
            defer { lease.finish() }
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let entry = current {
                guard let pointer = entry.pointee.ai_addr else { return false }
                if entry.pointee.ai_family == AF_INET {
                    let address = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                    let bytes = withUnsafeBytes(of: address) { Array($0) }
                    guard publicIPv4(bytes) else { return false }
                } else if entry.pointee.ai_family == AF_INET6 {
                    let address = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: address) { Array($0) }
                    guard publicIPv6(bytes) else { return false }
                } else { return false }
                current = entry.pointee.ai_next
            }
            return true
        }.value
    }

    static func publicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b))
            || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 192 && b == 0 && (bytes[2] == 0 || bytes[2] == 2))
            || (a == 198 && (b == 18 || b == 19 || (b == 51 && bytes[2] == 100)))
            || (a == 203 && b == 0 && bytes[2] == 113))
    }

    static func publicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return publicIPv4(Array(bytes.suffix(4)))
        }
        // Global unicast only: excludes unspecified, loopback, local, multicast and scoped addresses.
        return bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
    }

    static func iconURL(_ href: String, relativeTo page: URL) -> URL? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        guard var parts = URLComponents(url: URL(string: decoded, relativeTo: page)?.absoluteURL ?? page, resolvingAgainstBaseURL: false),
              URL(string: decoded, relativeTo: page) != nil else { return nil }
        parts.fragment = nil
        guard let url = parts.url, allowedURL(url) else { return nil }
        return url
    }

    struct DeclaredIcon { let href: String; let svg: Bool }
    static func declaredIcon(in html: String) -> String? { declaredIcons(in: html).first }
    static func declaredIcons(in html: String) -> [String] { declaredCandidates(in: html).map(\.href) }
    static func declaredIcons(in page: Data) -> [String] { declaredCandidates(in: page).map(\.href) }
    /// The same byte ceiling applies to network input and parsing, including cached/test data.
    private static func declaredCandidates(in page: Data) -> [DeclaredIcon] {
        let bounded = Data(page.prefix(maximumHTMLBytes))
        guard let html = String(data: bounded, encoding: .utf8) ?? String(data: bounded, encoding: .isoLatin1) else { return [] }
        return declaredCandidates(in: html)
    }
    private static func declaredCandidates(in html: String) -> [DeclaredIcon] {
        // A bounded lexical scan, not a DOM: comments and quoted values cannot
        // introduce tags/attributes. Attribute names are exact ASCII HTML names.
        let bytes = Array(html.utf8.prefix(maximumHTMLBytes))
        var index = 0, links = 0
        var candidates: [DeclaredIcon] = []
        var rawText: String?
        while index < bytes.count, links < 256 {
            guard bytes[index] == 60 else { index += 1; continue } // <
            if let rawText {
                let closing = Array(("</" + rawText).utf8)
                guard bytes[index...].prefix(closing.count).map(asciiLowercase) == closing,
                      index + closing.count < bytes.count,
                      htmlSpace(bytes[index + closing.count]) || bytes[index + closing.count] == 62
                        || bytes[index + closing.count] == 47 else { index += 1; continue }
            } else if bytes[index...].starts(with: [60, 33, 45, 45]) { // <!--
                index += 4
                while index + 2 < bytes.count, !bytes[index...].starts(with: [45, 45, 62]) { index += 1 }
                guard index + 2 < bytes.count else { break }
                index += 3
                continue
            }
            var cursor = index + 1
            let closing = cursor < bytes.count && bytes[cursor] == 47
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, !htmlSpace(bytes[cursor]), bytes[cursor] != 47, bytes[cursor] != 62 { cursor += 1 }
            let name = String(decoding: bytes[nameStart..<cursor].map(asciiLowercase), as: UTF8.self)
            let attributesStart = cursor
            var quote: UInt8?
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if let delimiter = quote {
                    if byte == delimiter { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                cursor += 1
            }
            guard cursor < bytes.count else { break } // Truncated tags/quotes fail closed.
            index = cursor + 1
            if rawText != nil { rawText = nil; continue }
            if !closing, ["script", "style", "title", "textarea"].contains(name) { rawText = name; continue }
            guard !closing, name == "link" else { continue }
            links += 1
            let attributes = htmlAttributes(bytes, from: attributesStart, to: cursor)
            guard let rel = attributes["rel"]?.lowercased().split(whereSeparator: \.isWhitespace),
                  rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = attributes["href"], !href.isEmpty else { continue }
            let svg = attributes["type"]?.lowercased() == "image/svg+xml" || URL(string: href)?.pathExtension.lowercased() == "svg"
            candidates.append(.init(href: href, svg: svg))
        }
        return candidates.filter { !$0.svg } + candidates.filter(\.svg)
    }

    private static func htmlSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
    private static func asciiLowercase(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    private static func htmlAttributes(_ bytes: [UInt8], from start: Int, to end: Int) -> [String: String] {
        var attributes: [String: String] = [:], index = start
        while index < end {
            while index < end, htmlSpace(bytes[index]) || bytes[index] == 47 { index += 1 }
            let nameStart = index
            while index < end, !htmlSpace(bytes[index]), bytes[index] != 61, bytes[index] != 47 { index += 1 }
            guard index > nameStart else { index += 1; continue }
            let name = String(decoding: bytes[nameStart..<index].map(asciiLowercase), as: UTF8.self)
            while index < end, htmlSpace(bytes[index]) { index += 1 }
            var value = ""
            if index < end, bytes[index] == 61 { // =
                index += 1
                while index < end, htmlSpace(bytes[index]) { index += 1 }
                if index < end, bytes[index] == 34 || bytes[index] == 39 {
                    let quote = bytes[index]; index += 1
                    let valueStart = index
                    while index < end, bytes[index] != quote { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    if index < end { index += 1 }
                } else {
                    let valueStart = index
                    while index < end, !htmlSpace(bytes[index]) { index += 1 }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            // HTML keeps the first occurrence of a duplicate attribute, even empty.
            if attributes[name] == nil { attributes[name] = value }
        }
        return attributes
    }

    static func isImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return false }
        return Array(head.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] || Array(head.prefix(4)) == [0x00, 0x00, 0x01, 0x00]
            || head.starts(with: [0xFF, 0xD8, 0xFF]) || head.starts(with: [0x47, 0x49, 0x46, 0x38])
            || (head.starts(with: [0x52, 0x49, 0x46, 0x46]) && Array(head.suffix(4)) == [0x57, 0x45, 0x42, 0x50])
    }

    static func isRenderableImage(_ data: Data) -> Bool {
        guard data.count <= maximumBytes, isImage(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) != nil
    }
}

private final class SourceIconRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard !AIMNetworkPrivacyPolicy.isEnabled, let original = task.originalRequest?.url, let target = request.url,
              SourceFaviconStore.allowedURL(target), SourceFaviconStore.sameSite(original, target) else { completionHandler(nil); return }
        Task {
            guard let host = target.host, await SourceFaviconStore.resolvesPublicly(host), !AIMNetworkPrivacyPolicy.isEnabled else { completionHandler(nil); return }
            var safe = request
            safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Referer")
            completionHandler(safe)
        }
    }
}

/// Global resource bound across panels/stores. Waiting does not authorize network access;
/// the usual privacy/DNS checks run again after a slot becomes available.
private actor SourceIconLookupSlots {
    static let shared = SourceIconLookupSlots()
    private var active = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    func acquire() async -> Bool {
        if active < 4 { active += 1; return true }
        guard waiting.count < 28 else { return false }
        return await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active = max(0, active - 1) }
        else { waiting.removeFirst().resume(returning: true) }
    }
}
