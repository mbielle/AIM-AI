@testable import AIMApplication
import XCTest

final class ToolJSONContractTests: XCTestCase {
    func testOpenAIArrayArgumentsRemainTypedAndUseSameSchema() throws {
        let tool = ModelToolDefinition(name: "browser_select_option", description: "Select choices",
            requiredArguments: ["target", "values"], argumentKinds: ["values": .array])
        let schema = OpenAIToolWire.schema(tool)
        let parameters = try XCTUnwrap(schema["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["values"]?["type"] as? String, "array")
        XCTAssertEqual((properties["values"]?["items"] as? [String: String])?["type"], "string")

        let item: [String: Any] = ["type": "function_call", "status": "completed", "call_id": "call-1",
                                   "name": tool.name, "arguments": #"{"target":"menu","values":["fr","en"]}"#]
        let data = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "output": [item]])
        let call = try XCTUnwrap(OpenAIToolWire.decode(data, tools: [tool]).turn.calls.first)
        XCTAssertEqual(call.jsonArguments["values"], .array([.string("fr"), .string("en")]))
        XCTAssertEqual(call.arguments["values"], #"["fr","en"]"#)

        var bad = item
        bad["arguments"] = #"{"target":"menu","values":[1]}"#
        let invalid = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "output": [bad]])
        XCTAssertThrowsError(try OpenAIToolWire.decode(invalid, tools: [tool]))
    }

    func testGeminiNumberBooleanAndOptionalNullAreValidated() throws {
        let tool = ModelToolDefinition(name: "desktop_click", description: "Click",
            requiredArguments: ["window_id", "x", "y"], optionalArguments: ["click_count", "confirm"],
            argumentKinds: ["x": .number, "y": .number, "click_count": .integer, "confirm": .boolean])
        let parts: [[String: Any]] = [["functionCall": ["name": tool.name,
            "args": ["window_id": "42", "x": 15.5, "y": -4, "click_count": 2, "confirm": NSNull()]]]]
        let data = try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP",
            "content": ["role": "model", "parts": parts]]]])
        let call = try XCTUnwrap(GeminiToolWire.decode(data, tools: [tool]).turn.calls.first)
        XCTAssertEqual(call.jsonArguments["x"], .number(15.5))
        XCTAssertEqual(call.jsonArguments["y"], .integer(-4))
        XCTAssertEqual(call.arguments["click_count"], "2")
        XCTAssertNil(call.jsonArguments["confirm"])
    }

    func testNestedAndOversizedArgumentsFailBeforeExecutor() throws {
        let nested = "{\"x\":" + String(repeating: "[", count: 18) + "\"too deep\"" + String(repeating: "]", count: 18) + "}"
        XCTAssertThrowsError(try ToolJSONValue.decodeObject(Data(nested.utf8)))
        XCTAssertThrowsError(try ToolJSONValue.decodeObject(Data(#"{"x":"\u0000"}"#.utf8)))
        XCTAssertThrowsError(try ToolJSONValue.decodeObject(Data("[]".utf8)))
        XCTAssertThrowsError(try ToolJSONValue.decodeObject(Data(repeating: 0x20, count: ToolPayloadLimits.argumentsJSONBytes + 1)))
    }

    func testPlanAndQuestionArraysHaveStructuredSchemasAndValidation() throws {
        let plan = ModelToolDefinition(name: "update_plan", description: "Plan", requiredArguments: ["steps"],
            argumentKinds: ["steps": .planSteps])
        let steps: ToolJSONValue = .array([.object(["title": .string("Inspect"), "status": .string("doing")])])
        XCTAssertEqual(try plan.normalized(["steps": steps])["steps"], steps)
        XCTAssertThrowsError(try plan.normalized(["steps": .array([.object([
            "title": .string("Inspect"), "status": .string("finished")
        ])])]))
        let planSchema = OpenAIToolWire.schema(plan)
        let planParameters = try XCTUnwrap(planSchema["parameters"] as? [String: Any])
        let planProperties = try XCTUnwrap(planParameters["properties"] as? [String: [String: Any]])
        let planItem = try XCTUnwrap(planProperties["steps"]?["items"] as? [String: Any])
        XCTAssertEqual(planItem["additionalProperties"] as? Bool, false)

        let questions = ModelToolDefinition(name: "ask_user", description: "Ask", optionalArguments: ["questions"],
            argumentKinds: ["questions": .questionItems])
        let items: ToolJSONValue = .array([.object(["question": .string("Which folder?"),
            "options": .array([.string("A"), .string("B")]), "multi": .boolean(false)])])
        XCTAssertEqual(try questions.normalized(["questions": items])["questions"], items)
        XCTAssertThrowsError(try questions.normalized(["questions": .array([.object([
            "question": .string("Which folder?"), "multi": .string("yes")
        ])])]))
    }
}
