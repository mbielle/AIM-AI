import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation
import PDFKit

/// A bounded, cookie-free text fetch. Remote content is untrusted tool output.
public actor AgentWebFetchToolService: ToolExecutor {
    static let maximumBytes = 10 * 1_024 * 1_024
    public nonisolated let supportedTools: Set<String> = ["web_fetch"]
    private let session: URLSession
    private var running: [String: Task<(String, URL), Error>] = [:]

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            // A redirect is followed only to another public HTTP(S) address, never to a local one
            // and never from HTTPS down to HTTP.
            self.session = RuntimeManagedNetworkSession.make(configuration: configuration, delegate: PublicRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard request.name == "web_fetch", let raw = request.arguments["url"],
              raw.utf8.count <= 4_096, let url = URL(string: raw), Self.isAllowed(url) else {
            return ToolResult(requestID: request.id, content: "Enter a public HTTP or HTTPS URL without embedded credentials. Local and private-network addresses are not supported.", isError: true)
        }
        let offset = max(0, Int(request.arguments["offset"] ?? "0") ?? 0)
        let task = Task { try await fetch(url, offset: offset) }
        running[request.id] = task
        defer { running.removeValue(forKey: request.id) }
        do {
            let (content, finalURL) = try await task.value
            return ToolResult(requestID: request.id, content: content, metadata: ["url": finalURL.absoluteString])
        } catch {
            return ToolResult(requestID: request.id, content: "The page could not be read: \(error.localizedDescription)", isError: true)
        }
    }

    public func cancel(requestID: String) async { running[requestID]?.cancel() }

    private func fetch(_ url: URL, offset: Int) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,text/plain,application/pdf,application/json,application/xml;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let finalURL = response.url, Self.isAllowed(finalURL) else { throw FetchError.invalidResponse }
        let mime = response.mimeType?.lowercased() ?? ""
        let pdf = mime == "application/pdf" || (mime == "application/octet-stream" && finalURL.pathExtension.lowercased() == "pdf")
        guard pdf || mime.hasPrefix("text/") || ["application/json", "application/xml", "application/xhtml+xml"].contains(mime) else {
            throw FetchError.unsupportedContent
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), Self.maximumBytes))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw FetchError.tooLarge }
            data.append(byte)
        }
        if pdf { return (Self.page(try Self.pdfText(data), offset: offset), finalURL) }
        // Older sites still serve Latin-1 or Windows-1252 pages.
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else { throw FetchError.unsupportedContent }
        let text: String
        if mime == "text/html" || mime == "application/xhtml+xml" {
            text = decoded
                .replacingOccurrences(of: "(?is)<(script|style|noscript)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "(?s)<[^>]*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        } else { text = decoded }
        return (Self.page(text, offset: offset), finalURL)
    }

    /// About 25k tokens per call: whole articles fit, and a long research run stays affordable
    /// since every later step re-sends what was read. Longer texts are read in further calls.
    static let pageCharacters = 100_000
    static func page(_ text: String, offset: Int) -> String {
        guard offset > 0 || text.count > pageCharacters else { return text }
        guard offset < text.count else { return "[No more text: the document has \(text.count) characters.]" }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: pageCharacters, limitedBy: text.endIndex) ?? text.endIndex
        var piece = String(text[start..<end])
        if offset > 0 { piece = "[Text from character \(offset).]\n" + piece }
        let next = text.distance(from: text.startIndex, to: end)
        if next < text.count { piece += "\n[Text continues: \(text.count - next) more characters. Call web_fetch again with offset \(next).]" }
        return piece
    }

    /// The selectable text of a PDF, page by page (scanned pages have none).
    static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw FetchError.unreadablePDF }
        var text = "PDF text (\(document.pageCount) pages; layout, figures and scanned pages are not included).\n"
        var found = false
        for index in 0..<min(document.pageCount, 2_000) {
            try Task.checkCancellation()
            let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty { found = true }
            text += "\n--- Page \(index + 1) ---\n" + (pageText.isEmpty ? "[No selectable text on this page.]" : pageText) + "\n"
            if text.utf8.count > 4 * 1_024 * 1_024 { text += "\n[Remaining pages not read: text limit reached.]"; break }
        }
        guard found else { throw FetchError.unreadablePDF }
        return text
    }

    nonisolated static func isPublic(_ url: URL) -> Bool { isAllowed(url) }
    private nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        // Numeric IPv6 literals (including IPv4-mapped forms) are excluded;
        // this tool is for public Web pages, not local network exploration.
        if host.contains(":") || host.hasPrefix("0x") || host.allSatisfy(\.isNumber) { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            let a = octets[0], b = octets[1]
            if a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) { return false }
        }
        return true
    }
}

private final class PublicRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url, hops: Self.hops(task)) ? request : nil)
    }
    private static func hops(_ task: URLSessionTask) -> Int {
        // URLSession does not count redirects; the task description carries the count.
        let count = (Int(task.taskDescription ?? "") ?? 0) + 1
        task.taskDescription = String(count)
        return count
    }
    static func allows(from original: URL?, to target: URL?, hops: Int) -> Bool {
        guard hops <= 5, let target, AgentWebFetchToolService.isPublic(target) else { return false }
        return !(original?.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https")
    }
}

private enum FetchError: LocalizedError {
    case invalidResponse, unsupportedContent, tooLarge, unreadablePDF
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an error, or redirected to an address that is not a public HTTP(S) page."
        case .unsupportedContent: "Only Web pages, text and PDF documents are supported."
        case .unreadablePDF: "This PDF has no selectable text, or it is locked."
        case .tooLarge: "This page exceeds the 10 MB reading limit."
        }
    }
}
