import Foundation
import CoreFoundation

public struct AIMResearchHTTPRequest: Sendable {
    public enum Kind: Sendable { case search, page }
    public let request: URLRequest
    public let mode: AIMResearchMode
    public let kind: Kind
    public init(request: URLRequest, mode: AIMResearchMode, kind: Kind) {
        self.request = request; self.mode = mode; self.kind = kind
    }
}

public struct AIMResearchHTTPResponse: Sendable {
    public let data: Data
    public let contentType: String
    /// Exa's costDollars.total when reported; Brave is unknown. A direct page read makes no search API call.
    public let externalAPICostUSD: Double?
    public init(data: Data, contentType: String = "application/json", externalAPICostUSD: Double? = nil) {
        self.data = data; self.contentType = contentType; self.externalAPICostUSD = externalAPICostUSD
    }
}

public struct AIMResearchHTTPClient: Sendable {
    private let session: URLSession
    public static let maximumResponseBytes = 1_048_576
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
            self.session = AIMManagedNetworkSession.make(configuration: config, delegate: NoResearchRedirects())
        }
    }
    public func perform(_ operation: AIMResearchHTTPRequest) async throws -> AIMResearchHTTPResponse {
        try Task.checkCancellation(); try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let url = operation.request.url, url.scheme == "https", url.user == nil, url.password == nil else { throw AIMResearchError.unsafeURL }
        if operation.kind == .search {
            guard url.host == (operation.mode == .exa ? "api.exa.ai" : "api.search.brave.com"), operation.mode.isOrchestrated else { throw AIMResearchError.unsafeURL }
        }
        let (bytes, response) = try await session.bytes(for: operation.request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw AIMResearchError.unsafeURL }
        guard (200..<300).contains(http.statusCode) else { throw AIMResearchError.http(http.statusCode) }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > Self.maximumResponseBytes { throw AIMResearchError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if data.count.isMultiple(of: 4096) { try AIMNetworkPrivacyPolicy.requireNetwork() }
            guard data.count < Self.maximumResponseBytes else { throw AIMResearchError.responseTooLarge }
            data.append(byte)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let cost: Double?
        if operation.kind == .page { cost = 0 }
        else if operation.mode == .exa {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            cost = Self.money((root?["costDollars"] as? [String: Any])?["total"])
        } else { cost = nil }
        return .init(data: data, contentType: type, externalAPICostUSD: cost)
    }
    public static func money(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}

private final class NoResearchRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
