import Foundation
import XCTest
@testable import AIMCore

private final class ProviderUsageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let code: Int
        let body: String
        switch token {
        case "Bearer fixture-account-a": code = 200; body = #"{"data":{"usage":8.14,"limit":20,"limit_remaining":11.86}}"#
        case "Bearer fixture-account-b": code = 200; body = #"{"data":{"usage":0}}"#
        case "Bearer fixture-rejected": code = 401; body = #"{"error":{"message":"private-provider-payload"}}"#
        case "Bearer fixture-throttled": code = 429; body = #"{"error":{"message":"private-provider-payload"}}"#
        case "Bearer fixture-malformed": code = 200; body = #"{"data":{"usage":true}}"#
        default: code = 503; body = #"{"error":{"message":"private-provider-payload"}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProviderAccountUsageTests: XCTestCase {
    func testReadOnlyRequestUsesCurrentKeyEndpointWithoutSecretsInURL() throws {
        let request = try ProviderAccountUsageService.request(provider: .openRouter, key: "fixture-account-a")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-account-a")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        for bad in ["", "line\nbreak", "space key", "nul\0key", String(repeating: "k", count: 4097)] {
            XCTAssertThrowsError(try ProviderAccountUsageService.request(provider: .openRouter, key: bad))
        }
        for provider in [ChatProvider.chatgpt, .openAI, .anthropic] {
            XCTAssertThrowsError(try ProviderAccountUsageService.request(provider: provider, key: "fixture")) { error in
                XCTAssertEqual(error as? ProviderAccountUsageError, .unsupportedProvider)
            }
        }
    }

    func testProviderMeasurementsPreserveMacEndpointValuesAndTheirOwner() throws {
        let account = UUID(), checked = Date(timeIntervalSince1970: 100)
        let body = Data(#"{"data":{"usage":8.14,"usage_daily":0.14,"usage_weekly":1.14,"usage_monthly":2.14,"byok_usage":3.14,"limit":20,"limit_remaining":11.86,"limit_reset":"monthly","include_byok_in_limit":false,"label":"do-not-retain-a-key-label","creator_user_id":"not-our-account-id"}}"#.utf8)
        let usage = try ProviderAccountUsageService.decodeOpenRouter(body, accountID: account, fetchedAt: checked)
        XCTAssertEqual(usage.accountID, account)
        XCTAssertEqual(usage.provider, .openRouter)
        XCTAssertEqual(usage.fetchedAt, checked)
        XCTAssertEqual(usage.creditUsageUSD, 8.14)
        XCTAssertEqual(usage.dailyCreditUsageUSD, 0.14)
        XCTAssertEqual(usage.weeklyCreditUsageUSD, 1.14)
        XCTAssertEqual(usage.monthlyCreditUsageUSD, 2.14)
        XCTAssertEqual(usage.byokUsageUSD, 3.14)
        XCTAssertEqual(usage.creditLimitUSD, 20)
        XCTAssertEqual(usage.creditRemainingUSD, 11.86)
        XCTAssertEqual(usage.limitReset, .monthly)
        XCTAssertEqual(usage.includesBYOKInLimit, false)
        // Provider totals are read without folding external BYOK into OpenRouter credits.
        XCTAssertNotEqual(usage.creditUsageUSD, 8.14 + 3.14)
    }

    func testAbsentAndInvalidAmountsRemainUnknownWhileMeasuredZeroIsPreserved() throws {
        let body = Data(#"{"data":{"usage":0,"usage_daily":true,"usage_weekly":"1.2","usage_monthly":-1,"byok_usage":{},"limit":null,"limit_remaining":false,"limit_reset":"unknown","include_byok_in_limit":"true"}}"#.utf8)
        let value = try ProviderAccountUsageService.decodeOpenRouter(body, accountID: UUID())
        XCTAssertEqual(value.creditUsageUSD, 0)
        XCTAssertNil(value.dailyCreditUsageUSD)
        XCTAssertNil(value.weeklyCreditUsageUSD)
        XCTAssertNil(value.monthlyCreditUsageUSD)
        XCTAssertNil(value.byokUsageUSD)
        XCTAssertNil(value.creditLimitUSD)
        XCTAssertNil(value.creditRemainingUSD)
        XCTAssertNil(value.limitReset)
        XCTAssertNil(value.includesBYOKInLimit)
    }

    func testNoMeasurementsAndOversizedResponsesAreRejectedWithoutFabricatedZero() {
        for raw in [#"{"data":{}}"#, #"{"data":{"usage":false}}"#, #"{"data":{"usage":-1}}"#, #"{"data":{"usage":1e999}}"#, #"{"error":{"message":"private-provider-payload"}}"#, #"{"data":null}"#, "not JSON"] {
            XCTAssertThrowsError(try ProviderAccountUsageService.decodeOpenRouter(Data(raw.utf8), accountID: UUID())) { error in
                XCTAssertEqual(error as? ProviderAccountUsageError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try ProviderAccountUsageService.decodeOpenRouter(Data(repeating: 32, count: 128 * 1024 + 1), accountID: UUID()))
    }

    func testFixtureFetchKeepsSeparateAccountAndKeySnapshotsWithoutNetworkOrLedgerWrites() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        let service = ProviderAccountUsageService(session: session, networkAdmission: {})
        let a = UUID(), b = UUID()
        let first = try await service.fetch(accountID: a, provider: .openRouter, key: "fixture-account-a")
        let second = try await service.fetch(accountID: b, provider: .openRouter, key: "fixture-account-b")
        XCTAssertEqual(first.accountID, a); XCTAssertEqual(first.creditUsageUSD, 8.14)
        XCTAssertEqual(second.accountID, b); XCTAssertEqual(second.creditUsageUSD, 0)
        XCTAssertNil(second.creditLimitUSD); XCTAssertNil(second.creditRemainingUSD)
        XCTAssertNotEqual(first.accountID, second.accountID)
    }

    func testFixtureErrorsAreTypedAndNeverExposeProviderPayload() async {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        let service = ProviderAccountUsageService(session: session, networkAdmission: {})
        for (key, expected) in [("fixture-rejected", ProviderAccountUsageError.credentialsRejected), ("fixture-throttled", .rateLimited), ("fixture-server-down", .unavailable), ("fixture-malformed", .invalidResponse)] {
            do { _ = try await service.fetch(accountID: UUID(), provider: .openRouter, key: key); XCTFail("Expected a safe provider error") }
            catch {
                XCTAssertEqual(error as? ProviderAccountUsageError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-provider-payload"))
                XCTAssertFalse(error.localizedDescription.contains(key))
            }
        }
        let refused = ProviderAccountUsageService(session: session, networkAdmission: { throw AIMNetworkPrivacyError.networkDisabled })
        do { _ = try await refused.fetch(accountID: UUID(), provider: .openRouter, key: "fixture-account-a"); XCTFail("Admission must be checked before the provider fixture") }
        catch { XCTAssertTrue(error is AIMNetworkPrivacyError) }
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUsageFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}
