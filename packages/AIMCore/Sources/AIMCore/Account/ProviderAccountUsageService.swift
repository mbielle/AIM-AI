import Foundation

/// A provider's view of the key stored on this device. These amounts cover all
/// applications using that key; they are never merged into AIM's activity ledger.
public struct ProviderAccountUsage: Equatable, Sendable {
    public enum LimitReset: String, Decodable, Sendable { case daily, weekly, monthly }
    public let accountID: UUID
    public let provider: ChatProvider
    public let fetchedAt: Date
    public let creditUsageUSD: Double?
    public let dailyCreditUsageUSD: Double?
    public let weeklyCreditUsageUSD: Double?
    public let monthlyCreditUsageUSD: Double?
    public let byokUsageUSD: Double?
    public let creditLimitUSD: Double?
    public let creditRemainingUSD: Double?
    public let limitReset: LimitReset?
    public let includesBYOKInLimit: Bool?
}

public enum ProviderAccountUsageError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedProvider, missingKey, credentialsRejected, rateLimited, unavailable, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "Account usage is unavailable through this provider connection."
        case .missingKey: "Connect an OpenRouter key on this iPhone to check its usage."
        case .credentialsRejected: "OpenRouter could not authenticate this key. Check the connection in Providers."
        case .rateLimited: "OpenRouter is limiting usage checks. Try again later."
        case .unavailable: "OpenRouter usage is unavailable right now. Try again later."
        case .invalidResponse: "OpenRouter did not return usable account measurements. Try again later."
        }
    }
}

/// Read-only current-key endpoint also used by macOS Usage → Accounts. It does
/// not generate a model response, require a management key, or expose secrets.
public struct ProviderAccountUsageService: Sendable {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    private let networkAdmission: @Sendable () throws -> Void
    public init(session: URLSession? = nil) {
        self.session = session ?? NativeChatTransport.secretSession()
        networkAdmission = { try AIMNetworkPrivacyPolicy.requireNetwork() }
    }
    /// Internal dependency injection isolates URLProtocol fixtures from the running
    /// app's privacy preferences. Public construction always applies the policy.
    init(session: URLSession, networkAdmission: @escaping @Sendable () throws -> Void) {
        self.session = session; self.networkAdmission = networkAdmission
    }

    public static func request(provider: ChatProvider, key: String) throws -> URLRequest {
        guard provider == .openRouter else { throw ProviderAccountUsageError.unsupportedProvider }
        guard !key.isEmpty, key.utf8.count <= 4096,
              !key.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            throw ProviderAccountUsageError.missingKey
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetch(accountID: UUID, provider: ChatProvider, key: String) async throws -> ProviderAccountUsage {
        let request = try Self.request(provider: provider, key: key)
        try networkAdmission()
        let body: Data
        let response: URLResponse
        do { (body, response) = try await session.data(for: request, delegate: NoRedirects()) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderAccountUsageError.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ProviderAccountUsageError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ProviderAccountUsageError.credentialsRejected
        case 429: throw ProviderAccountUsageError.rateLimited
        default: throw ProviderAccountUsageError.unavailable
        }
        return try Self.decodeOpenRouter(body, accountID: accountID)
    }

    public static func decodeOpenRouter(_ body: Data, accountID: UUID, fetchedAt: Date = .now) throws -> ProviderAccountUsage {
        guard body.count <= 128 * 1024, let root = try? JSONDecoder().decode(Response.self, from: body),
              root.data.hasMeasurement else { throw ProviderAccountUsageError.invalidResponse }
        let data = root.data
        return .init(accountID: accountID, provider: .openRouter, fetchedAt: fetchedAt,
                     creditUsageUSD: data.usage, dailyCreditUsageUSD: data.daily, weeklyCreditUsageUSD: data.weekly,
                     monthlyCreditUsageUSD: data.monthly, byokUsageUSD: data.byok,
                     creditLimitUSD: data.limit, creditRemainingUSD: data.remaining,
                     limitReset: data.reset, includesBYOKInLimit: data.includesBYOK)
    }

    private struct Response: Decodable { let data: Measurements }
    private struct Measurements: Decodable {
        let usage: Double?, daily: Double?, weekly: Double?, monthly: Double?, byok: Double?, limit: Double?, remaining: Double?
        let reset: ProviderAccountUsage.LimitReset?
        let includesBYOK: Bool?
        var hasMeasurement: Bool { [usage, daily, weekly, monthly, byok, limit, remaining].contains { $0 != nil } }
        private enum CodingKeys: String, CodingKey {
            case usage, daily = "usage_daily", weekly = "usage_weekly", monthly = "usage_monthly", byok = "byok_usage"
            case limit, remaining = "limit_remaining", reset = "limit_reset", includesBYOK = "include_byok_in_limit"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Missing, invalid, boolean and negative values remain unknown, never zero.
            func amount(_ key: CodingKeys) -> Double? {
                guard let value = try? values.decode(Double.self, forKey: key), value.isFinite, value >= 0 else { return nil }
                return value
            }
            usage = amount(.usage); daily = amount(.daily); weekly = amount(.weekly); monthly = amount(.monthly)
            byok = amount(.byok); limit = amount(.limit); remaining = amount(.remaining)
            reset = try? values.decode(ProviderAccountUsage.LimitReset.self, forKey: .reset)
            includesBYOK = try? values.decode(Bool.self, forKey: .includesBYOK)
        }
    }
}
