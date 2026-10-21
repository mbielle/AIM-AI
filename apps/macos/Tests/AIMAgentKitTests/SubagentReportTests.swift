import AIMAgentKit
import AIMApplication
import XCTest

private actor ScriptedConversation: SteerableModelToolConversation {
    var turns: [ModelToolTurn]
    private(set) var corrections: [String] = []
    init(_ turns: [ModelToolTurn]) { self.turns = turns }
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn { try await next(outputs: outputs, userMessages: []) }
    func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        corrections += userMessages
        guard !turns.isEmpty else { throw ModelToolError.invalidProtocol }
        return turns.removeFirst()
    }
}

final class SubagentReportTests: XCTestCase {
    func testReportValidationAndArrays() async throws {
        let service = SubagentReportToolService()
        let missing = await service.execute(ToolRequest(name: "subagent_report", arguments: ["summary": "x", "confidence": "sure"], risk: .readOnly))
        XCTAssertTrue(missing.isError)
        let saved = await service.execute(ToolRequest(name: "subagent_report", arguments: [
            "summary": "Renamed the helper", "confidence": "High",
            "changes": "[\"src/a.swift\",\"src/b.swift\"]", "evidence": "read both files back", "not_checked": ""],
            risk: .readOnly))
        XCTAssertFalse(saved.isError)
        let report = await service.report
        XCTAssertEqual(report?.changes, ["src/a.swift", "src/b.swift"])
        XCTAssertEqual(report?.evidence, ["read both files back"])
        XCTAssertEqual(report?.notChecked, [])
        XCTAssertEqual(report?.confidence, .high)
        XCTAssertTrue(report?.json.contains("\"not_checked\":[]") == true)
    }

    func testMissingReportGetsExactlyOneCorrection() async throws {
        let call = ModelToolCall(id: "r1", name: "subagent_report", jsonArguments: ["summary": .string("done"), "confidence": .string("low")])
        let inner = ScriptedConversation([ModelToolTurn(text: "All done.", calls: []), ModelToolTurn(text: "", calls: [call])])
        let reports = SubagentReportToolService()
        let conversation = ReportEnforcingConversation(inner: inner, reports: reports)
        let turn = try await conversation.next(outputs: [])
        XCTAssertEqual(turn.text, "All done.")
        XCTAssertEqual(turn.calls.map(\.name), ["subagent_report"])
        let corrections = await inner.corrections
        XCTAssertEqual(corrections, [ReportEnforcingConversation.correction])

        // A second report-less ending is accepted as is: no loop of corrections.
        let stubborn = ScriptedConversation([ModelToolTurn(text: "a", calls: []), ModelToolTurn(text: "b", calls: [])])
        let once = ReportEnforcingConversation(inner: stubborn, reports: SubagentReportToolService())
        let final = try await once.next(outputs: [])
        XCTAssertEqual(final.text, "a\n\nb")
        XCTAssertTrue(final.calls.isEmpty)
        let count = await stubborn.corrections.count
        XCTAssertEqual(count, 1)
    }
}
