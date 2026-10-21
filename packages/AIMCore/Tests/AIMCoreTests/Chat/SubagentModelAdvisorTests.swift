import XCTest
@testable import AIMCore

final class SubagentModelAdvisorTests: XCTestCase {
    private func model(_ id: String, input: String?, output: String?, tools: Bool = true, vision: Bool? = nil, efforts: [String]? = nil) -> ChatModel {
        var value = ChatModel(id: id, name: id, contextLength: 200_000, inputModalities: vision.map { $0 ? ["text", "image"] : ["text"] })
        value.supportedParameters = tools ? ["tools", "reasoning"] : ["temperature"]
        value.pricing = .init(prompt: input, completion: output)
        if let efforts { value.reasoning = .init(mandatory: false, supportedEfforts: efforts, defaultEffort: nil) }
        return value
    }

    private var catalogs: [ChatProvider: [ChatModel]] {
        [.openRouter: [model("a/cheap", input: "0.0000001", output: "0.0000004", efforts: ["low", "medium", "high"]),
                       model("b/mid", input: "0.000002", output: "0.00001", vision: false),
                       model("c/top", input: "0.000005", output: "0.000025", vision: true),
                       model("d/notools", input: "0.0000001", output: "0.0000001", tools: false),
                       model("e/second", input: "0.0000003", output: "0.000001"),
                       model("f/big", input: "0.000004", output: "0.00002")]]
    }

    func testSizeSpreadsCandidatesByPriceAndSkipsModelsWithoutTools() {
        let small = SubagentModelAdvisor.candidates(catalogs, request: .init(task: "list files", size: .small))
        XCTAssertEqual(small.map(\.model.id), ["a/cheap", "e/second", "b/mid", "f/big"])
        XCTAssertEqual(small.first?.suggestedEffort, "low")
        XCTAssertFalse(small.contains { $0.model.id == "d/notools" })
        let large = SubagentModelAdvisor.candidates(catalogs, request: .init(task: "redesign", size: .large))
        XCTAssertEqual(large.first?.model.id, "c/top")
        let vision = SubagentModelAdvisor.candidates(catalogs, request: .init(task: "screenshot", size: .large, needsVision: true))
        XCTAssertEqual(vision.first?.model.id, "c/top")
        XCTAssertFalse(vision.contains { $0.model.id == "b/mid" }, "a model the catalog declares text-only is excluded")
        XCTAssertFalse(SubagentModelAdvisor.candidates(catalogs, request: .init(task: "x", needsVision: true)).isEmpty)
    }

    func testUndisclosedCapabilitiesStayEligibleAndUnknownPricesComeLast() {
        let direct = ChatModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5")
        let result = SubagentModelAdvisor.candidates([.anthropic: [direct], .openRouter: [model("a/cheap", input: "0.0000001", output: "0.0000004")]], request: .init(task: "t", size: .small))
        XCTAssertEqual(result.map(\.model.id), ["a/cheap", "claude-sonnet-5-5"])
        XCTAssertTrue(SubagentModelAdvisor.render(result, rankedBy: "price").contains("input unknown/M"))
        XCTAssertTrue(SubagentModelAdvisor.render([], rankedBy: "price").hasPrefix("No connected model"))
    }

    func testJevRequestAndRanking() throws {
        let candidates = SubagentModelAdvisor.candidates(catalogs, request: .init(task: "fix a typo", size: .small))
        let request = try JevDecisionClient.request(candidates, task: .init(task: "fix a typo", size: .small), key: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let criteria = try XCTUnwrap(((body["questions"] as? [String: Any])?["best"] as? [String: Any])?["criteria"] as? [String: String])
        XCTAssertEqual(criteria.count, candidates.count)
        let response = #"{"model":"jev-1.13.0","answers":{"best":{"type":"choice","choice":"c2","confidence":0.8,"probabilities":{"c1":0.1,"c2":0.7,"c3":0.15,"c4":0.05}},"effort":{"type":"choice","choice":"medium","confidence":0.6,"probabilities":{}}},"usage":{"input_tokens":400,"output_tokens":0}}"#
        let ranked = try JevDecisionClient.ranked(candidates, response: Data(response.utf8))
        XCTAssertEqual(ranked.first?.model.id, candidates[1].model.id)
        XCTAssertEqual(ranked.first?.probability, 0.7)
        XCTAssertEqual(ranked.first { $0.model.id == "a/cheap" }?.suggestedEffort, "medium")
        XCTAssertThrowsError(try JevDecisionClient.ranked(candidates, response: Data("{}".utf8)))
    }
}

final class SubagentJournalTests: XCTestCase {
    func testTranscriptKeepsParentMessagesTurnsAndToolStates() {
        let child = UUID(), other = UUID(), start = Date(timeIntervalSince1970: 0)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
        let entries: [SubagentJournalEntry] = [
            .init(childID: child, kind: .reasoning, text: "Plan the search", at: at(1)),
            .init(childID: child, kind: .toolStarted, callID: "c1", name: "read_file", at: at(2)),
            .init(childID: other, kind: .text, text: "not mine", at: at(2)),
            .init(childID: child, kind: .toolFinished, text: "42 lines", callID: "c1", isError: false, at: at(3)),
            .init(childID: child, kind: .text, text: "Found it.", at: at(4)),
            .init(childID: child, kind: .parentMessage, text: "Also check tests", at: at(5)),
            .init(childID: child, kind: .toolStarted, callID: "c2", name: "run_command", at: at(6)),
            .init(childID: child, kind: .noteToParent, text: "Tests are slow", callID: "n1", at: at(7))]
        let transcript = SubagentTranscript(childID: child, prompt: "Find the bug", startedAt: start, entries: entries, running: false)
        XCTAssertEqual(transcript.items.count, 4)
        guard case let .turn(_, first) = transcript.items[1], case let .turn(_, second) = transcript.items[3] else { return XCTFail() }
        XCTAssertEqual(first.work.count, 2)
        guard case let .tools(_, firstTools) = first.work[1] else { return XCTFail() }
        XCTAssertEqual(firstTools.map(\.state), [.completed])
        XCTAssertEqual(firstTools.first?.output, "42 lines")
        guard case let .tools(_, secondTools) = second.work.first else { return XCTFail() }
        XCTAssertEqual(secondTools.map(\.name), ["run_command", "message_parent"])
        XCTAssertEqual(secondTools.first?.state, .needsReview, "an interrupted call is never shown as done")
        XCTAssertFalse(transcript.actions.contains { $0.input == "not mine" })
    }

    func testEntriesAreBoundedAndMasked() {
        let entry = SubagentJournalEntry(childID: UUID(), kind: .text, text: "api_key=sk-abcdefghijklmnop " + String(repeating: "x", count: 20_000))
        XCTAssertLessThanOrEqual(entry.text?.count ?? 0, SubagentJournalEntry.textLimit + 20)
        XCTAssertFalse(entry.text?.contains("sk-abcdefghijklmnop") ?? true)
    }
}
