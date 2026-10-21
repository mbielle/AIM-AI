import XCTest
@testable import AIMCore

final class RemoteConversationRulesTests: XCTestCase {
    func testSparsePendingAndAcknowledgedTimelineKeepsPersistedAssistantText() {
        for state in ["pending", "done"] {
            let message = RemoteTimelineMessage(id: "m", role: .assistant, content: "Visible instruction", reasoning: nil, toolCalls: [],
                timeline: [tool(id: "a", name: "open_app", status: state)])
            let segments = RemoteTimelineRules.displayTimeline(for: message)
            guard case let .text(_, text, _) = segments.first else { return XCTFail("Persisted text must remain visible") }
            XCTAssertEqual(text, "Visible instruction")
            XCTAssertEqual(segments.count, 2)
        }
    }

    func testOnlyLatestAssistantTurnStaysExpandedDuringApprovalAndResumption() {
        for status in ["running", "waiting_approval"] {
            XCTAssertTrue(RemoteTimelineRules.keepsLatestTurnExpanded(role: .assistant, isLatest: true, sessionStatus: status))
            XCTAssertFalse(RemoteTimelineRules.keepsLatestTurnExpanded(role: .assistant, isLatest: false, sessionStatus: status))
            XCTAssertFalse(RemoteTimelineRules.keepsLatestTurnExpanded(role: .user, isLatest: true, sessionStatus: status))
        }
        XCTAssertFalse(RemoteTimelineRules.keepsLatestTurnExpanded(role: .assistant, isLatest: true, sessionStatus: "idle"))
    }

    func testTimelineKeepsKnownSegmentsInOrderAndGroupsAdjacentTools() {
        let message = RemoteTimelineMessage(
            id: "m1",
            role: .assistant,
            content: "Ancien texte",
            reasoning: "Ancienne réflexion",
            toolCalls: [],
            timeline: [
                .object(["id": .string("r"), "type": .string("reasoning"), "text": .string("Réflexion exacte"), "state": .string("complete")]),
                tool(id: "a", name: "read_file", status: "done"),
                tool(id: "b", name: "read_file", status: "done"),
                .object(["id": .string("future"), "type": .string("future-segment")]),
                tool(id: "c", name: "execute_command", status: "running"),
                .object(["id": .string("t"), "type": .string("text"), "text": .string("Réponse exacte"), "state": .string("complete")]),
            ]
        )

        let timeline = RemoteTimelineRules.displayTimeline(for: message)
        XCTAssertEqual(timeline.map(\.id), ["r", "a", "b", "c", "t"])
        let grouped = RemoteTimelineRules.group(timeline)
        XCTAssertEqual(grouped.count, 3)
        guard case let .toolGroup(group) = grouped[1] else { return XCTFail("groupe attendu") }
        XCTAssertEqual(group.tools.map(\.name), ["read_file", "read_file", "execute_command"])
        XCTAssertEqual(group.segments.count, 3)
    }

    func testMixedAdjacentToolsShareOneActivityAndDecodePresentation() {
        let message = RemoteTimelineMessage(
            id: "m2",
            role: .assistant,
            content: "",
            timeline: [
                .object([
                    "id": .string("write"),
                    "type": .string("tool"),
                    "tool": .object([
                        "id": .string("write"),
                        "name": .string("write_file"),
                        "status": .string("done"),
                        "params": .object(["path": .string("App.swift")]),
                        "presentation": .object([
                            "kind": .string("create_file"),
                            "additions": .number(12),
                            "deletions": .number(2),
                        ]),
                    ]),
                ]),
                tool(id: "run", name: "execute_command", status: "done"),
            ]
        )

        let grouped = RemoteTimelineRules.group(RemoteTimelineRules.displayTimeline(for: message))
        guard case let .toolGroup(group) = grouped.first else { return XCTFail("groupe attendu") }
        XCTAssertEqual(group.tools.count, 2)
        XCTAssertEqual(group.additions, 12)
        XCTAssertEqual(group.deletions, 2)
        XCTAssertEqual(group.tools.first?.presentation.path, "App.swift")
        XCTAssertEqual(group.tools.last?.presentation.kind, .command)
    }

    func testDiffCountsIgnoreHeaders() {
        let counts = RemoteToolPresentationRules.diffCounts("""
        --- a/App.swift
        +++ b/App.swift
        @@ -1,2 +1,3 @@
        -old
        +new
        +extra
        """)
        XCTAssertEqual(counts.additions, 2)
        XCTAssertEqual(counts.deletions, 1)
    }

    func testLegacyTimelineRemainsReadable() {
        let legacy = RemoteTimelineMessage(
            id: "legacy",
            role: .assistant,
            content: "Réponse",
            reasoning: "Pensée",
            toolCalls: [.init(id: "x", name: "search_files", status: "done")]
        )
        XCTAssertEqual(RemoteTimelineRules.displayTimeline(for: legacy).map(\.typeName), ["reasoning", "text", "tool", "status"])
    }

    func testLegacyToolParametersStillProduceTypedPresentation() {
        let legacy = RemoteTimelineMessage(
            id: "legacy-params",
            role: .assistant,
            content: "",
            toolCalls: [
                .init(
                    id: "command",
                    name: "execute_command",
                    status: "done",
                    result: "ok",
                    parameters: .object(["command": .string("swift test")])
                ),
            ]
        )

        let timeline = RemoteTimelineRules.displayTimeline(for: legacy)
        guard case let .tool(_, tool) = timeline.first else { return XCTFail("tool expected") }
        XCTAssertEqual(tool.presentation.kind, .command)
        XCTAssertEqual(tool.presentation.command, "swift test")
        XCTAssertEqual(tool.presentation.outputPreview, "ok")
    }

    func testEndOfTurnActionsAndDisclaimerAppearExactlyOnce() {
        let messages = [
            RemoteTurnMessage(role: .user, content: "Question"),
            RemoteTurnMessage(role: .assistant, content: "Réponse"),
        ]
        XCTAssertEqual(RemoteResponseRules.endOfTurn(messages: messages, index: 1, status: "idle"), .init(actions: true, disclaimer: true, text: "Réponse"))
        XCTAssertEqual(RemoteResponseRules.endOfTurn(messages: messages, index: 1, status: "running"), .init(actions: false, disclaimer: false, text: "Réponse"))

        let fragments = [
            RemoteTurnMessage(role: .user, content: "Question"),
            RemoteTurnMessage(role: .assistant, content: "Réponse"),
            RemoteTurnMessage(role: .assistant, content: "<tool_call>{}</tool_call>"),
        ]
        XCTAssertEqual(RemoteResponseRules.endOfTurn(messages: fragments, index: 1, status: "idle").actions, false)
        XCTAssertEqual(RemoteResponseRules.endOfTurn(messages: fragments, index: 2, status: "idle"), .init(actions: true, disclaimer: true, text: "Réponse"))
        XCTAssertFalse(RemoteResponseRules.disclaimer(messages: [.init(role: .user, content: "Q")], index: 0, generationInProgress: false))
        XCTAssertTrue(RemoteResponseRules.chatGenerationInProgress(isLoading: true, stream: nil, conversationID: "c"))
        XCTAssertFalse(RemoteResponseRules.chatGenerationInProgress(isLoading: false, stream: .init(isComplete: false, conversationID: "other"), conversationID: "c"))
    }

    private func tool(id: String, name: String, status: String) -> RemoteJSONValue {
        .object([
            "id": .string(id),
            "type": .string("tool"),
            "tool": .object([
                "id": .string(id),
                "name": .string(name),
                "params": .object([:]),
                "status": .string(status),
            ]),
        ])
    }
}
