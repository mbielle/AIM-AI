@testable import AIMApplication
import XCTest

final class ToolStreamAssemblerTests: XCTestCase {
    private func sse(_ events: [[String: Any]]) throws -> Data {
        var text = ""
        for event in events { text += "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n" }
        return Data((text + "data: [DONE]\n\n").utf8)
    }

    func testChatCompletionsStreamRebuildsTheNonStreamedAnswer() throws {
        let raw = try sse([
            ["id": "gen-1", "choices": [["index": 0, "delta": ["role": "assistant", "reasoning": "Need ", "reasoning_details": [["type": "reasoning.text", "text": "Need ", "index": 0]]]]]],
            ["choices": [["index": 0, "delta": ["reasoning": "sources.", "reasoning_details": [["type": "reasoning.text", "text": "sources.", "signature": "sig", "index": 0]]]]]],
            ["choices": [["index": 0, "delta": ["content": "Je cherche "]]]],
            ["choices": [["index": 0, "delta": ["content": "maintenant.", "tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":"]]]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"jev\"}"]]]], "finish_reason": "tool_calls"]]],
            ["choices": [], "usage": ["prompt_tokens": 1200, "completion_tokens": 40, "cost": 0.0042]]
        ])
        var assembler = ToolStreamAssembler(wire: .chatCompletions)
        var deltas: [ToolStreamDelta] = []
        // Fed in arbitrary chunks, as the network delivers it.
        for chunk in stride(from: 0, to: raw.count, by: 37).map({ raw[$0..<min($0 + 37, raw.count)] }) { deltas += assembler.feed(Data(chunk)) }
        XCTAssertEqual(deltas, [.reasoning("Need "), .reasoning("sources."), .text("Je cherche "), .text("maintenant.")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try assembler.response(raw: raw)) as? [String: Any])
        let choice = try XCTUnwrap((body["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Je cherche maintenant.")
        let call = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{\"query\":\"jev\"}")
        let detail = try XCTUnwrap((message["reasoning_details"] as? [[String: Any]])?.first)
        XCTAssertEqual(detail["text"] as? String, "Need sources.")
        XCTAssertEqual(detail["signature"] as? String, "sig")
        XCTAssertEqual((body["usage"] as? [String: Any])?["cost"] as? Double ?? 0, 0.0042, accuracy: 1e-9)
    }

    func testStreamedReceiptKeepsTheProvidersExactCost() throws {
        // Written as raw text: the provider's own digits, not a binary float re-encoded.
        let raw = Data("""
        data: {"id":"gen-2","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0.000489,"cost_details":{"upstream_inference_cost":0.000489}}}

        data: [DONE]

        """.utf8)
        var assembler = ToolStreamAssembler(wire: .chatCompletions)
        _ = assembler.feed(raw)
        XCTAssertEqual(OpenRouterUsageReceipt.costUSD(in: try assembler.response(raw: raw)), "0.000489")
        XCTAssertEqual(ToolStreamAssembler.costText(in: #"{"text":"say \"cost\": 9","usage":{"cost": 1.5e-05}}"#), "1.5e-05")
    }

    func testAnthropicStreamKeepsThinkingSignaturesAndToolInput() throws {
        let raw = try sse([
            ["type": "message_start", "message": ["id": "msg_1", "type": "message", "role": "assistant", "content": [], "usage": ["input_tokens": 900]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Plan."]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "abc"]],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Je lis."]],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "read_file", "input": [:]]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"path\":"]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "\"a.txt\"}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 30]]
        ])
        var assembler = ToolStreamAssembler(wire: .anthropic)
        XCTAssertEqual(assembler.feed(raw), [.reasoning("Plan."), .text("Je lis.")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try assembler.response(raw: raw)) as? [String: Any])
        XCTAssertEqual(body["stop_reason"] as? String, "tool_use")
        let blocks = try XCTUnwrap(body["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["signature"] as? String, "abc")
        XCTAssertEqual((blocks[2]["input"] as? [String: Any])?["path"] as? String, "a.txt")
        XCTAssertEqual((body["usage"] as? [String: Any])?["input_tokens"] as? Int, 900)
        XCTAssertEqual((body["usage"] as? [String: Any])?["output_tokens"] as? Int, 30)
    }

    func testResponsesStreamUsesTheCompletedResponseAndPlainBodiesPassThrough() throws {
        let raw = try sse([
            ["type": "response.output_text.delta", "delta": "Bon"],
            ["type": "response.output_text.delta", "delta": "jour"],
            ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": []]]
        ])
        var assembler = ToolStreamAssembler(wire: .responses)
        XCTAssertEqual(assembler.feed(raw), [.text("Bon"), .text("jour")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try assembler.response(raw: raw)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "resp_1")
        let plain = Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"x"}}]}"#.utf8)
        var passthrough = ToolStreamAssembler(wire: .chatCompletions)
        XCTAssertTrue(passthrough.feed(plain).isEmpty)
        XCTAssertEqual(try passthrough.response(raw: plain), plain)
    }
}
