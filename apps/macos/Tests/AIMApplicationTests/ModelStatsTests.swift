@testable import AIMApplication
import Foundation
import XCTest

final class ModelStatsTests: XCTestCase {
    func testEndpointsDecode() throws {
        let json = #"{"data":{"id":"anthropic/claude-haiku-4.5","endpoints":[{"name":"Azure | x","provider_name":"Azure","tag":"azure/global","context_length":200000,"max_completion_tokens":64000,"quantization":"unknown","pricing":{"prompt":"0.000001","completion":"0.000005","input_cache_read":"0.0000001"},"uptime_last_5m":100,"uptime_last_30m":99.5,"uptime_last_1d":99.9,"status":0,"latency_last_30m":null}]}}"#
        let endpoints = try OpenRouterEndpoints.decode(Data(json.utf8))
        XCTAssertEqual(endpoints.first?.providerName, "Azure")
        XCTAssertEqual(endpoints.first?.uptime30m, 99.5)
        XCTAssertEqual(endpoints.first?.pricing?.outputPerMillion ?? 0, 5, accuracy: 0.001)
    }

    func testHistoryIsHourlyAndKeptOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ModelStatsStore(url: url)
        let json = #"{"data":{"endpoints":[{"name":"A","provider_name":"A","uptime_last_30m":99}]}}"#
        let hosts = try OpenRouterEndpoints.decode(Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.recordUptime(model: "m", endpoints: hosts, now: now)
        await store.recordUptime(model: "m", endpoints: hosts, now: now.addingTimeInterval(600))
        let samples = await store.uptime(model: "m")
        XCTAssertEqual(samples.count, 1, "at most once an hour")
        await store.recordSpeed(model: "m", provider: "openrouter", firstTokenSeconds: 0.8, tokensPerSecond: 60, now: now)
        let reloaded = ModelStatsStore(url: url)
        let speed = await reloaded.speed(model: "m")
        XCTAssertEqual(speed.first?.tokensPerSecond, 60)
    }
}
