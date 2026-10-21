import AIMApplication
import XCTest

final class PerplexityAgentWireTests: XCTestCase {
    private let answer = #"{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer [2]"}]}"#

    func testCompletedAnswerPreservesStableSearchCitations() throws {
        let sources = #"{"type":"search_results","status":"completed","results":[{"id":2,"title":"Source B","url":"https://example.org/b"},{"id":1,"title":"Source [A]","url":"https://example.org/a"}]}"#
        let result = try ProviderWireFormat.decode(completed([answer, sources]), provider: .perplexity)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.text, "", "Source metadata must not append a bibliography to the answer")
        XCTAssertEqual(result.sources?.map(\.url), ["https://example.org/a", "https://example.org/b"])
        XCTAssertEqual(result.sources?.map(\.title), ["Source [A]", "Source B"])
        XCTAssertEqual(result.sources?.map(\.references), [[1], [2]])
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"type":"response.output_text.delta","delta":"Answer"}"#, provider: .perplexity).text, "Answer")
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"type":"response.output_item.done","item":{"type":"web_search_call"}}"#, provider: .perplexity).text, "")
    }

    func testRejectsUnsafeSourcesAndHostedActions() throws {
        for url in ["http://example.org", "https://user:secret@example.org", "https://example.org/a)malicious", "https://example.org/a b"] {
            let source = #"{"type":"search_results","results":[{"id":1,"title":"Link","url":"\#(url)"}]}"#
            XCTAssertThrowsError(try ProviderWireFormat.decode(completed([answer, source]), provider: .perplexity), url)
        }
        for type in ["code_interpreter_call", "mcp_call", "function_call"] {
            XCTAssertThrowsError(try ProviderWireFormat.decode(completed([answer, "{\"type\":\"\(type)\"}"]), provider: .perplexity))
            XCTAssertThrowsError(try ProviderWireFormat.decode("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"\(type)\"}}", provider: .perplexity))
        }
    }

    func testPartialOrEmptyTerminalIsNotSuccessful() throws {
        for payload in [#"{"type":"response.failed"}"#,
                        #"{"type":"response.incomplete"}"#,
                        completed([#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":" "}]}"#]),
                        completed([answer]).replacingOccurrences(of: #""status":"completed""#, with: #""status":"incomplete""#)] {
            XCTAssertThrowsError(try ProviderWireFormat.decode(payload, provider: .perplexity))
        }
    }

    private func completed(_ items: [String]) -> String {
        "{\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"status\":\"completed\",\"error\":null,\"output\":[\(items.joined(separator: ","))]}}"
    }
}
