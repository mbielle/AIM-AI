import Foundation

/// One captured profile/provider turn. No persistent or cross-profile cache, fallback, cookies or scripts.
public actor AIMResearchSession: AIMResearchToolRuntime {
    public typealias Perform = @Sendable (AIMResearchHTTPRequest) async throws -> AIMResearchHTTPResponse
    private let mode: AIMResearchMode
    private let credential: @Sendable () async throws -> String
    private let perform: Perform
    private let resolvesPublicly: @Sendable (String) async -> Bool
    private struct Result: Codable, Sendable {
        let resultID: String, title: String, url: String, excerpt: String
    }
    private struct Document: Sendable { let text: String; let truncated: Bool }
    private var results: [String: Result] = [:]
    private var resultIDs: [String: String] = [:]
    private var queries: [String: [Result]] = [:]
    private var documents: [String: Document] = [:]
    private var charges: [Double?] = []
    private var reads = 0
    private var busy = false
    public init(mode: AIMResearchMode, credential: @escaping @Sendable () async throws -> String,
                client: AIMResearchHTTPClient = .init(), perform: Perform? = nil,
                resolvesPublicly: (@Sendable (String) async -> Bool)? = nil) {
        self.mode = mode; self.credential = credential; self.perform = perform ?? { try await client.perform($0) }
        self.resolvesPublicly = resolvesPublicly ?? { await SourceFaviconStore.resolvesPublicly($0) }
    }
    public func activity(name: String, arguments: [String: String], callID: String) throws -> NativeWebSearchActivity {
        let input: [String: String]
        if name == AIMResearchTools.searchName { input = ["type": "search", "query": try query(arguments)] }
        else if name == AIMResearchTools.readName {
            let result = try result(arguments)
            input = ["type": "open_page", "url": result.url]
        } else { throw AIMResearchError.invalidArguments }
        return .init(id: callID, status: .running, input: String(decoding: try JSONEncoder().encode(input), as: UTF8.self))
    }
    public func usage() -> NativeWebSearchUsage {
        let known = charges.allSatisfy { $0 != nil }
        let total = known ? charges.compactMap { $0 }.reduce(0, +) : nil
        return .init(requests: charges.count, additionalCostUSD: total, isRequestAggregate: true)
    }
    public func execute(name: String, arguments: [String: String]) async throws -> AIMResearchToolResult {
        try Task.checkCancellation(); try AIMNetworkPrivacyPolicy.requireNetwork()
        guard mode.isOrchestrated, !busy else { throw AIMResearchError.invalidArguments }
        busy = true; defer { busy = false }
        if name == AIMResearchTools.searchName { return try await search(try query(arguments)) }
        if name == AIMResearchTools.readName { return try await read(try result(arguments), offset: try offset(arguments)) }
        throw AIMResearchError.invalidArguments
    }
    private func query(_ args: [String: String]) throws -> String {
        guard Set(args.keys) == ["query"], let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty, query.utf8.count <= 2048, !query.contains("\0") else { throw AIMResearchError.invalidArguments }
        return query
    }
    private func result(_ args: [String: String]) throws -> Result {
        guard Set(args.keys).isSubset(of: ["resultID", "offset"]), let id = args["resultID"], let result = results[id] else { throw AIMResearchError.invalidArguments }
        _ = try offset(args)
        return result
    }
    private func offset(_ args: [String: String]) throws -> Int {
        guard let value = Int(args["offset"] ?? "0"), (0..<49_152).contains(value) else { throw AIMResearchError.invalidArguments }
        return value
    }
    private func search(_ query: String) async throws -> AIMResearchToolResult {
        let cacheKey = query
        if let cached = queries[cacheKey] { return try searchOutput(cached, cached: true) }
        guard charges.count < 4 else { throw AIMResearchError.limitReached }
        let key = try await credential()
        try Task.checkCancellation()
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: \.isWhitespace), !key.contains("\0") else { throw AIMResearchError.missingKey }
        var request: URLRequest
        if mode == .exa {
            request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "type": "fast", "numResults": 3, "contents": ["highlights": true]])
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            var url = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            url.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "3"), .init(name: "extra_snippets", value: "true"), .init(name: "text_decorations", value: "false")]
            request = URLRequest(url: url.url!); request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        }
        request.timeoutInterval = 25; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let chargeIndex = charges.count; charges.append(nil)
        let response = try await perform(.init(request: request, mode: mode, kind: .search))
        charges[chargeIndex] = response.externalAPICostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], root["error"] == nil else { throw AIMResearchError.invalidResponse }
        let items = mode == .exa ? root["results"] as? [[String: Any]] : (root["web"] as? [String: Any])?["results"] as? [[String: Any]]
        guard let items else { throw AIMResearchError.invalidResponse }
        var found: [Result] = [], seen = Set<String>()
        for item in items.prefix(10) {
            guard let raw = item["url"] as? String, var url = URLComponents(string: raw) else { continue }
            url.fragment = nil
            guard let page = url.url, page.absoluteString.utf8.count <= 8192, SourceFaviconStore.allowedURL(page), seen.insert(page.absoluteString).inserted else { continue }
            let id = resultIDs[page.absoluteString] ?? "web-\(results.count + 1)"
            let snippets = item["highlights"] as? [String] ?? item["extra_snippets"] as? [String] ?? []
            let text = ([item["description"] as? String ?? ""] + snippets).filter { !$0.isEmpty }.joined(separator: "\n")
            let result = Result(resultID: id, title: Self.bounded(item["title"] as? String ?? page.host ?? "Source", bytes: 256), url: page.absoluteString,
                                excerpt: Self.bounded(text, bytes: 1800))
            results[id] = result; resultIDs[page.absoluteString] = id; found.append(result)
            if found.count == 3 { break }
        }
        queries[cacheKey] = found
        return try searchOutput(found, cached: false)
    }
    private func searchOutput(_ values: [Result], cached: Bool) throws -> AIMResearchToolResult {
        struct Output: Encodable { let results: [Result]; let cached: Bool; let untrustedSourceData = true }
        let text = try encode(Output(results: values, cached: cached))
        return .init(text: text, sources: values.compactMap { ConversationSource(url: $0.url, title: $0.title) })
    }
    private func read(_ result: Result, offset: Int) async throws -> AIMResearchToolResult {
        let document: Document, cached: Bool
        if let existing = documents[result.url] { document = existing; cached = true }
        else {
            guard reads < 6, let url = URL(string: result.url), SourceFaviconStore.allowedURL(url),
                  let host = url.host, await resolvesPublicly(host) else { throw AIMResearchError.unsafeURL }
            try Task.checkCancellation(); reads += 1
            var request = URLRequest(url: url); request.timeoutInterval = 20; request.httpShouldHandleCookies = false
            request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
            let response = try await perform(.init(request: request, mode: mode, kind: .page))
            try Task.checkCancellation()
            guard response.contentType.contains("text/html") || response.contentType.contains("text/plain"),
                  let raw = String(data: response.data, encoding: .utf8) else { throw AIMResearchError.invalidResponse }
            let text = response.contentType.contains("text/html") ? Self.htmlText(raw) : raw
            document = Document(text: Self.bounded(text, bytes: 49_152), truncated: text.utf8.count > 49_152)
            documents[result.url] = document; cached = false
        }
        let bytes = Array(document.text.utf8)
        guard offset <= bytes.count else { throw AIMResearchError.invalidArguments }
        let end = min(bytes.count, offset + 12_000)
        struct Output: Encodable {
            let resultID: String, url: String, title: String, text: String
            let nextOffset: String?; let truncated: Bool; let cached: Bool
            let untrustedSourceData = true
        }
        let text = try encode(Output(resultID: result.resultID, url: result.url, title: result.title,
            text: String(decoding: bytes[offset..<end], as: UTF8.self), nextOffset: end < bytes.count ? String(end) : nil,
            truncated: document.truncated, cached: cached))
        return .init(text: text, sources: [ConversationSource(url: result.url, title: result.title)].compactMap { $0 })
    }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= ProjectSourceTools.maximumResultBytes else { throw AIMResearchError.responseTooLarge }
        return String(decoding: data, as: UTF8.self)
    }
    private static func bounded(_ text: String, bytes: Int) -> String { String(decoding: text.utf8.prefix(bytes), as: UTF8.self) }
    private static func htmlText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style|noscript)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<!--.*?-->|<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
