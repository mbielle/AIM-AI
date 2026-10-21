import Foundation
import XCTest
@testable import AIMCore

final class RealtimeVoiceProtocolTests: XCTestCase {
    private func receipt(_ usage: String) -> RealtimeVoiceProtocol.Usage? {
        guard case .responseDone(_, let value) = RealtimeVoiceProtocol.parse("{\"type\":\"response.done\",\"response\":{\"status\":\"completed\",\"usage\":\(usage)}}") else { return nil }
        return value
    }

    func testMissingOrPartialUsageNeverBecomesAZeroReceipt() {
        for raw in ["{}", "null", #"{"input_tokens":10,"output_tokens":5}"#,
                    #"{"input_token_details":{"text_tokens":0,"audio_tokens":0,"cached_tokens":0},"output_token_details":{"text_tokens":0}}"#] {
            XCTAssertNil(receipt(raw), raw)
        }
        XCTAssertNil(RealtimeVoiceProtocol.costUSD(.init(), model: "gpt-realtime"))
    }

    func testExplicitCompleteZeroIsDistinctFromMissingUsage() throws {
        let value = try XCTUnwrap(receipt(#"{"input_tokens":0,"output_tokens":0,"total_tokens":0,"input_token_details":{"text_tokens":0,"audio_tokens":0,"cached_tokens":0},"output_token_details":{"text_tokens":0,"audio_tokens":0}}"#))
        XCTAssertEqual(value.totalTokens, 0)
        XCTAssertEqual(RealtimeVoiceProtocol.costUSD(value, model: "gpt-realtime"), 0)
    }

    func testOfficialResponseFixtureIncludesCachedTextAndAggregateTokens() throws {
        let value = try XCTUnwrap(receipt(#"{"total_tokens":253,"input_tokens":132,"output_tokens":121,"input_token_details":{"text_tokens":119,"audio_tokens":13,"image_tokens":0,"cached_tokens":64,"cached_tokens_details":{"text_tokens":64,"audio_tokens":0,"image_tokens":0}},"output_token_details":{"text_tokens":30,"audio_tokens":91}}"#))
        XCTAssertEqual(value.totalTokens, 253)
        XCTAssertEqual(RealtimeVoiceProtocol.costUSD(value, model: "gpt-realtime"), Decimal(string: "0.0069656"))
        XCTAssertNil(RealtimeVoiceProtocol.costUSD(value, model: "unpriced-model"))
    }

    func testCachedAudioIsDiscountedUsingItsOwnTokenSplit() throws {
        let value = try XCTUnwrap(receipt(#"{"input_token_details":{"text_tokens":100,"audio_tokens":200,"cached_tokens":200,"cached_tokens_details":{"text_tokens":50,"audio_tokens":150}},"output_token_details":{"text_tokens":10,"audio_tokens":20}}"#))
        XCTAssertEqual(value.totalTokens, 330)
        XCTAssertEqual(RealtimeVoiceProtocol.costUSD(value, model: "gpt-realtime"), Decimal(string: "0.00332"))
    }

    func testMissingOrInconsistentCacheSplitKeepsTheCostUnknown() throws {
        for cached in ["", #", "cached_tokens_details":{"text_tokens":10,"audio_tokens":9}"#,
                       #", "cached_tokens_details":{"text_tokens":0,"audio_tokens":20,"image_tokens":1}"#] {
            let raw = "{\"input_token_details\":{\"text_tokens\":10,\"audio_tokens\":20,\"cached_tokens\":20\(cached)},\"output_token_details\":{\"text_tokens\":0,\"audio_tokens\":0}}"
            let value = try XCTUnwrap(receipt(raw))
            XCTAssertEqual(value.totalTokens, 30)
            XCTAssertNil(RealtimeVoiceProtocol.costUSD(value, model: "gpt-realtime"))
        }
    }

    func testMalformedCountsAndInconsistentTotalsAreRejected() {
        for bad in ["true", "-1", "0.5", "1000000001", "\"10\""] {
            XCTAssertNil(receipt("{\"input_token_details\":{\"text_tokens\":\(bad),\"audio_tokens\":0,\"cached_tokens\":0},\"output_token_details\":{\"text_tokens\":0,\"audio_tokens\":0}}"))
        }
        XCTAssertNil(receipt(#"{"total_tokens":9,"input_token_details":{"text_tokens":10,"audio_tokens":0,"cached_tokens":0},"output_token_details":{"text_tokens":0,"audio_tokens":0}}"#))
        XCTAssertNil(receipt(#"{"input_token_details":{"text_tokens":10,"audio_tokens":0,"cached_tokens":11},"output_token_details":{"text_tokens":0,"audio_tokens":0}}"#))
    }
}
