import AIMApplication
import XCTest

final class SkillLearningTests: XCTestCase {
    private func run(calls: Int, state: WorkspaceRunState = .completed, viewing skill: String? = nil) throws -> WorkspaceRunHistory {
        var record = WorkspaceRun(conversationID: UUID(), provider: .openRouter, modelID: "m", workspacePath: "/w")
        record.state = state
        var list: [WorkspaceCall] = []
        for index in 0..<calls {
            let call = index == 0 && skill != nil
                ? ModelToolCall(id: "c\(index)", name: "skill_view", jsonArguments: ["name": .string(skill!)])
                : ModelToolCall(id: "c\(index)", name: "read_file", jsonArguments: ["path": .string("f\(index).txt")])
            var entry = try WorkspaceCall(runID: record.id, ordinal: index, call: call)
            entry.state = .succeeded
            entry.result = String(repeating: "r", count: 500)
            list.append(entry)
        }
        return WorkspaceRunHistory(run: record, calls: list)
    }

    private func messages() -> [ConversationMessage] {
        let id = UUID()
        return [ConversationMessage(conversationID: id, role: .user, content: "Write the report", sequence: 0),
                ConversationMessage(conversationID: id, role: .assistant, content: "Done", sequence: 1),
                ConversationMessage(conversationID: id, role: .user, content: "No, dates must be YYYY-MM-DD", sequence: 2),
                ConversationMessage(conversationID: id, role: .assistant, content: "Fixed the dates.", sequence: 3)]
    }

    func testDigestNeedsALongNormallyEndedRunAndIsBounded() throws {
        XCTAssertNil(SkillLearning.digest(messages: messages(), run: try run(calls: 5)))
        XCTAssertNil(SkillLearning.digest(messages: messages(), run: try run(calls: 12, state: .failed)))
        XCTAssertNil(SkillLearning.digest(messages: messages(), run: try run(calls: 12, state: .cancelled)))
        let digest = try XCTUnwrap(SkillLearning.digest(messages: messages(), run: try run(calls: 200, state: .unverified)))
        XCTAssertTrue(digest.contains("dates must be YYYY-MM-DD"))
        XCTAssertTrue(digest.contains("Fixed the dates."))
        XCTAssertTrue(digest.contains("200 in total"))
        XCTAssertLessThanOrEqual(digest.count, 24_001)
        XCTAssertFalse(digest.contains(String(repeating: "r", count: 200)), "tool results are clipped")
    }

    func testViewedSkillsAndReviewMessage() throws {
        let history = try run(calls: 9, viewing: "report-format")
        XCTAssertEqual(SkillLearning.viewedSkills(history), ["report-format"])
        let message = SkillLearning.reviewMessage(digest: "summary", skills: [],
            viewedBodies: ["report-format": "Use ISO dates."], conversationID: UUID())
        XCTAssertTrue(message.content.contains("untrusted data"))
        XCTAssertTrue(message.content.contains("## report-format\nUse ISO dates."))
        XCTAssertTrue(message.content.contains("NONE"))
    }

    func testProposalParsingRejectsInvalidAndSensitiveOutput() {
        func turn(_ arguments: [String: String]) -> ModelToolTurn {
            ModelToolTurn(text: "", calls: [ModelToolCall(id: "p", name: "propose_skill", arguments: arguments)])
        }
        let instructions = "1. Write dates as YYYY-MM-DD.\n2. Read the report back and check every date."
        let valid = SkillLearning.proposal(from: turn(["name": "Report-Dates", "description": "Format dates in reports",
                                                       "instructions": instructions]))
        XCTAssertEqual(valid?.name, "report-dates")
        XCTAssertNil(SkillLearning.proposal(from: ModelToolTurn(text: "NONE", calls: [])))
        XCTAssertNil(SkillLearning.proposal(from: turn(["name": "../x", "description": "d", "instructions": instructions])))
        XCTAssertNil(SkillLearning.proposal(from: turn(["name": "x", "description": "d", "instructions": "too short"])))
        XCTAssertNil(SkillLearning.proposal(from: turn(["name": "deploy", "description": "Deploy",
            "instructions": instructions + "\nUse api_key = abcdefghijklmnopqrstuvwxyz to authenticate."])))
        XCTAssertNil(SkillLearning.proposal(from: turn(["name": "deploy", "description": "Deploy",
            "instructions": instructions + "\nexport OPENAI=sk-proj-ABCDEFGHIJKLMNOPQRSTUV"])))
    }

    func testLearnedProposalKeepsItsOrigin() throws {
        let global = FileManager.default.temporaryDirectory.appendingPathComponent("aim-learned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: global) }
        try SkillCatalog.propose(name: "report-dates", description: "Format dates", body: "1. Use ISO dates.",
                                 origin: "learned", global: global)
        XCTAssertEqual(SkillCatalog.proposals(global: global).first?.origin, "learned")
        XCTAssertNil(SkillCatalog.discover(workspace: nil, global: global).first, "still inactive")
    }

    private func install(_ name: String, body: String, origin: String?, in global: URL) throws {
        let folder = global.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Old\n\(origin.map { "aim-origin: \($0)\n" } ?? "")---\n\n\(body)\n"
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func description(_ name: String, in global: URL) -> String? {
        SkillCatalog.discover(workspace: nil, global: global).first { $0.name == name }?.description
    }

    func testLevelsGateAutomaticChanges() throws {
        let global = FileManager.default.temporaryDirectory.appendingPathComponent("aim-levels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: global) }
        let long = String(repeating: "Step with a pitfall and a check. ", count: 10)
        try install("mine", body: long, origin: nil, in: global)
        try install("learned-one", body: long, origin: "learned", in: global)

        XCTAssertThrowsError(try SkillLearning.commit(name: "new", description: "New", instructions: long, level: .off, global: global))
        XCTAssertEqual(try SkillLearning.commit(name: "new", description: "New", instructions: long, level: .suggest, global: global),
                       .proposed(reason: nil))
        XCTAssertNil(description("new", in: global))

        // Autonomous: new skills and improvements of learned skills apply; the person's skills and big cuts stay proposals.
        XCTAssertEqual(try SkillLearning.commit(name: "fresh", description: "Fresh", instructions: long, level: .autonomous, global: global),
                       .applied(replacedExisting: false))
        XCTAssertEqual(try SkillLearning.commit(name: "learned-one", description: "Better", instructions: long + " One more check.",
                                                level: .autonomous, global: global), .applied(replacedExisting: true))
        XCTAssertEqual(description("learned-one", in: global), "Better")
        XCTAssertEqual(SkillCatalog.versions(name: "learned-one", global: global).count, 1, "the previous version is kept")
        guard case .proposed(let personal?) = try SkillLearning.commit(name: "mine", description: "Changed", instructions: long,
                                                                      level: .autonomous, global: global) else { return XCTFail() }
        XCTAssertTrue(personal.contains("you wrote"))
        XCTAssertEqual(description("mine", in: global), "Old")
        guard case .proposed(let cut?) = try SkillLearning.commit(name: "learned-one", description: "Shorter", instructions: "1. Only this.",
                                                                 level: .autonomous, global: global) else { return XCTFail() }
        XCTAssertTrue(cut.contains("remove a large part"))

        // Unrestricted: even the person's skill is rewritten, with the old version kept.
        XCTAssertEqual(try SkillLearning.commit(name: "mine", description: "Rewritten", instructions: "1. Short.",
                                                level: .unrestricted, global: global), .applied(replacedExisting: true))
        XCTAssertEqual(description("mine", in: global), "Rewritten")
        try SkillCatalog.rollback(name: "mine", global: global)
        XCTAssertEqual(description("mine", in: global), "Old")
    }
}
