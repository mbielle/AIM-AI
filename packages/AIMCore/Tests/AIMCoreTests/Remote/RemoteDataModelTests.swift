import XCTest
@testable import AIMCore

final class RemoteDataModelTests: XCTestCase {
    func testCapabilitiesDecodeTheComputerContractIncludingEffortAndEngines() throws {
        let data = Data(
            #"""
            {
              "version": 4,
              "models": [{
                "id": "claude-sonnet-5",
                "name": "Claude Sonnet 5",
                "provider": "anthropic",
                "via": "aim",
                "capabilities": ["vision"],
                "effort": { "levels": ["low", "medium", "high"], "current": "medium" }
              }],
              "engines": [{ "id": "aim", "state": "ready", "version": "2.4" }],
              "features": { "attachments": true, "terminal": false }
            }
            """#.utf8
        )

        let value = try JSONDecoder().decode(RemoteCapabilities.self, from: data)

        XCTAssertEqual(value.version, 4)
        XCTAssertEqual(value.models.first?.via, "aim")
        XCTAssertEqual(value.models.first?.effortLevels, ["low", "medium", "high"])
        XCTAssertEqual(value.models.first?.currentEffort, "medium")
        XCTAssertEqual(value.engines.first?.version, "2.4")
        XCTAssertEqual(value.features["attachments"], true)
    }

    func testPendingApprovalAndMessageMetadataKeepStructuredRemoteData() {
        let approval = RemotePendingApproval(
            messageID: "approval-1",
            toolName: "shell",
            summary: "Run tests",
            kind: "question",
            questions: [.object(["question": .string("Continue?")])]
        )
        let tool = RemoteToolCall(
            id: "tool-1",
            name: "shell",
            parameters: .object(["command": .string("swift test")]),
            status: "done",
            result: .string("ok")
        )
        let stats = RemoteRunStats(milliseconds: 1_250, tokens: 42, estimated: false, inputTokens: 12, outputTokens: 30)

        XCTAssertEqual(approval.questions?.first?.objectValue?["question"]?.stringValue, "Continue?")
        XCTAssertEqual(tool.parameters?.objectValue?["command"]?.stringValue, "swift test")
        XCTAssertEqual(tool.legacy.result, "ok")
        XCTAssertEqual(stats.duration, 1.25, accuracy: 0.001)
    }

    func testRemoteFolderUsesItsCanonicalPathAsIdentity() {
        let folder = RemoteFolder(json: .object([
            "path": .string("/Users/example/Developer/AIM"),
            "name": .string("AIM"),
            "isProjects": .bool(true),
        ]))

        XCTAssertEqual(folder?.id, "/Users/example/Developer/AIM")
        XCTAssertEqual(folder?.name, "AIM")
        XCTAssertEqual(folder?.isProjectsDirectory, true)
    }

    func testGoalConfigurationClampsTheComputerTurnLimit() {
        XCTAssertEqual(RemoteGoalConfiguration(maximumTurns: 0).maximumTurns, 1)
        XCTAssertEqual(RemoteGoalConfiguration(maximumTurns: 20).maximumTurns, 20)
        XCTAssertEqual(RemoteGoalConfiguration(maximumTurns: 500).maximumTurns, 50)
    }

    func testPriorityOrderingKeepsRunningThenPinnedThenRecent() {
        let now = Date()
        let recent = session(id: "recent", updatedAt: now)
        let pinned = session(id: "pinned", updatedAt: now.addingTimeInterval(-100), isPinned: true)
        let running = session(id: "running", status: "running", updatedAt: now.addingTimeInterval(-200))

        XCTAssertEqual(
            RemoteSessionOrdering.sorted([recent, pinned, running], by: .priority).map(\.id),
            ["running", "pinned", "recent"]
        )
        XCTAssertEqual(
            RemoteSessionOrdering.sorted([running, pinned, recent], by: .chronological).map(\.id),
            ["recent", "pinned", "running"]
        )
    }

    func testUnifiedDiffBuildsStructuredFilesAndCounters() {
        let result = RemoteDiffResult(diff: """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,3 @@
        -old
        +new
        +second
        diff --git a/README.md b/README.md
        new file mode 100644
        --- /dev/null
        +++ b/README.md
        +hello
        """)

        XCTAssertEqual(result.files.map(\.path), ["Sources/App.swift", "README.md"])
        XCTAssertEqual(result.additions, 3)
        XCTAssertEqual(result.deletions, 1)
        XCTAssertEqual(result.files.last?.status, "added")
    }

    func testSearchNormalizesCaseAndAccents() {
        let messages = [
            RemoteMessage(id: "1", sessionID: "s", sequence: 1, role: .assistant, content: "Résumé détaillé", reasoning: nil, timeline: nil),
            RemoteMessage(id: "2", sessionID: "s", sequence: 2, role: .user, content: "Autre", reasoning: nil, timeline: nil),
        ]
        XCTAssertEqual(RemoteConversationSearch.matchingMessageIDs(query: "resume", messages: messages), ["1"])
    }

    private func session(
        id: String,
        status: String = "idle",
        updatedAt: Date,
        isPinned: Bool = false
    ) -> RemoteSession {
        .init(
            id: id,
            machineID: "machine",
            mode: .code,
            title: id,
            workspace: nil,
            modelID: nil,
            approvalMode: nil,
            status: status,
            messageCount: 0,
            updatedAt: updatedAt,
            agentSystem: nil,
            phase: nil,
            isSilent: false,
            isInterrupted: false,
            isPinned: isPinned
        )
    }
}
