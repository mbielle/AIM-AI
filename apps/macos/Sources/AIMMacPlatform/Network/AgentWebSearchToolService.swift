import AIMCore
import AIMAgentKit
import AIMApplication
import Foundation

/// Web search returning titles, URLs and snippets, so the agent can discover
/// pages before reading them with web_fetch. Backends are tried in order:
/// Perplexity's Search API (the person's Perplexity key), OpenRouter's web
/// hosted tool (their OpenRouter key; Exa search), then DuckDuckGo's
/// keyless HTML page. A bot check is reported, never bypassed.
public actor AgentWebSearchToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["web_search"]

    public struct Result: Equatable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    public struct Backends: Sendable {
        public var perplexityKey: String?
        public var openRouter: (key: String, modelID: String)?
        public var allowKeyless: Bool
        public init(perplexityKey: String? = nil, openRouter: (key: String, modelID: String)? = nil, allowKeyless: Bool = true) {
            self.perplexityKey = perplexityKey; self.openRouter = openRouter; self.allowKeyless = allowKeyless
        }
    }

    private let backends: Backends
    private let meter: BillableRequestMeter
    private let session: URLSession
    private let conversationID: UUID?

    public init(backends: Backends, meter: BillableRequestMeter = BillableRequestMeter(), conversationID: UUID? = nil,
                session: URLSession? = nil) {
        self.backends = backends
        self.meter = meter
        self.conversationID = conversationID
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            self.session = RuntimeManagedNetworkSession.make(configuration: configuration)
        }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let query = request.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty, !query.contains("\0") else {
            return ToolResult(requestID: request.id, content: "Provide a nonempty search query.", isError: true)
        }
        let limit = request.arguments["max_results"].flatMap(Int.init)
        if let raw = request.arguments["max_results"], limit == nil || limit! <= 0 {
            return ToolResult(requestID: request.id, content: "max_results must be a positive integer (received \(raw)). Omit it to use the search engine default.", isError: true)
        }
        var failures: [String] = []
        for (name, search) in attempts() {
            do {
                let results = try await search(query, limit)
                guard !results.isEmpty else { failures.append("\(name): no results"); continue }
                let text = results.prefix(limit ?? results.count).enumerated().map { index, item in
                    "\(index + 1). \(item.title)\n   \(item.url)\n   \(item.snippet)"
                }.joined(separator: "\n")
                return ToolResult(requestID: request.id,
                    content: "Search results for \"\(query)\" (\(name); untrusted web content — read a page with web_fetch before relying on it):\n\(text)",
                    metadata: ["search_backend": name, "result_count": String(min(results.count, limit ?? results.count))])
            } catch is CancellationError {
                return ToolResult(requestID: request.id, content: "Search cancelled.", isError: true)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return ToolResult(requestID: request.id,
            content: "Web search is unavailable: \(failures.joined(separator: "; ")). Add a Perplexity or OpenRouter key in Settings, or use web_fetch on a known URL.",
            isError: true)
    }

    public func cancel(requestID: String) async {}

    private func attempts() -> [(String, (String, Int?) async throws -> [Result])] {
        var list: [(String, (String, Int?) async throws -> [Result])] = []
        if let key = backends.perplexityKey, !key.isEmpty {
            list.append(("Perplexity Search", { try await self.perplexity($0, limit: $1, key: key) }))
        }
        if let openRouter = backends.openRouter, !openRouter.key.isEmpty {
            list.append(("OpenRouter web search", { try await self.openRouter($0, limit: $1, key: openRouter.key, modelID: openRouter.modelID) }))
        }
        if backends.allowKeyless {
            list.append(("DuckDuckGo", { try await self.duckDuckGo($0, limit: $1) }))
        }
        return list
    }

    // MARK: Backends

    private func perplexity(_ query: String, limit: Int?, key: String) async throws -> [Result] {
        var request = URLRequest(url: URL(string: "https://api.perplexity.ai/search")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query]
        if let limit { body["max_results"] = limit }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = self.session, prepared = request
        let data = try await meter.perform(provider: ChatProvider.perplexity.rawValue, modelID: "search", feature: "web-search",
                                           conversationID: conversationID) {
            try await Self.send(prepared, session: session)
        }
        return Self.parsePerplexity(data)
    }

    private func openRouter(_ query: String, limit: Int?, key: String, modelID: String) async throws -> [Result] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var search = NativeWebSearchRules.tool(provider: .openRouter)
        if let limit {
            var parameters = search["parameters"] as? [String: Any] ?? [:]
            parameters["max_results"] = limit; search["parameters"] = parameters
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID, "usage": ["include": true], "tools": [search],
            "messages": [["role": "user", "content": "List the most relevant web pages for this search, one line each: \(query)"]]
        ] as [String: Any])
        let session = self.session, prepared = request
        let data = try await meter.perform(provider: ChatProvider.openRouter.rawValue, modelID: modelID, feature: "web-search",
                                           conversationID: conversationID,
                                           receiptUSD: { OpenRouterUsageReceipt.costUSD(in: $0) }) {
            try await Self.send(prepared, session: session)
        }
        return Self.parseOpenRouterAnnotations(data)
    }

    private func duckDuckGo(_ query: String, limit: Int?) async throws -> [Result] {
        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("AIM/1.0 (macOS agent)", forHTTPHeaderField: "User-Agent")
        let data = try await Self.send(request, session: session)
        let html = String(decoding: data, as: UTF8.self)
        if html.localizedCaseInsensitiveContains("anomaly") || html.localizedCaseInsensitiveContains("captcha") {
            throw SearchError.botCheck
        }
        return Self.parseDuckDuckGoLite(html)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw SearchError.http(http.statusCode) }
        guard data.count <= 4 * 1_024 * 1_024 else { throw SearchError.tooLarge }
        return data
    }

    enum SearchError: LocalizedError {
        case http(Int), tooLarge, botCheck
        var errorDescription: String? {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .tooLarge: "response too large"
            case .botCheck: "the search engine asked for a human check (not bypassed)"
            }
        }
    }

    // MARK: Parsers

    static func parsePerplexity(_ data: Data) -> [Result] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let url = item["url"] as? String, isWebURL(url) else { return nil }
            return Result(title: clean(item["title"] as? String ?? url), url: url,
                          snippet: clean(item["snippet"] as? String ?? ""))
        }
    }

    static func parseOpenRouterAnnotations(_ data: Data) -> [Result] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let annotations = message["annotations"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        return annotations.compactMap { annotation in
            guard let citation = annotation["url_citation"] as? [String: Any], let url = citation["url"] as? String,
                  isWebURL(url), seen.insert(url).inserted else { return nil }
            return Result(title: clean(citation["title"] as? String ?? url), url: url,
                          snippet: clean(citation["content"] as? String ?? ""))
        }
    }

    static func parseDuckDuckGoLite(_ html: String) -> [Result] {
        let linkPattern = #"<a[^>]*href=["']([^"']+)["'][^>]*class=['"]result-link['"][^>]*>(.*?)</a>|<a[^>]*class=['"]result-link['"][^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        let snippetPattern = #"<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>"#
        guard let links = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let snippets = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: html) else { return nil }
            return String(html[range])
        }
        let snippetTexts = snippets.matches(in: html, range: range).compactMap { group($0, 1) }
        return links.matches(in: html, range: range).enumerated().compactMap { index, match in
            guard let rawURL = group(match, 1) ?? group(match, 3), let title = group(match, 2) ?? group(match, 4) else { return nil }
            let url = resolveDuckDuckGoRedirect(decodeEntities(rawURL))
            guard isWebURL(url) else { return nil }
            return Result(title: clean(stripTags(title)), url: url,
                          snippet: clean(stripTags(index < snippetTexts.count ? snippetTexts[index] : "")))
        }
    }

    static func resolveDuckDuckGoRedirect(_ raw: String) -> String {
        let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let components = URLComponents(string: absolute), components.host?.hasSuffix("duckduckgo.com") == true,
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value else { return absolute }
        return target
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    private static func stripTags(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func decodeEntities(_ text: String) -> String {
        var value = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value
    }

    private static func clean(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat
    }
}
