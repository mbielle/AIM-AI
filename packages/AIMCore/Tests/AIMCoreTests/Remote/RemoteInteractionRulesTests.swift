import XCTest
@testable import AIMCore

final class RemoteInteractionRulesTests: XCTestCase {
    func testRemoteFeaturedMetadataIsOptionalAndDoesNotRewriteExplicitAddition() throws {
        let legacy = Data(#"{"id":"fixture","name":"Fixture","provider":"anthropic"}"#.utf8)
        let old = try JSONDecoder().decode(RemoteModelAnnouncement.self, from: legacy)
        XCTAssertNil(old.isFeatured)
        let model = RemoteModelAnnouncement(id: "fixture", name: "Fixture", provider: "anthropic", isAdded: false, isAvailable: true, isFeatured: true)
        let restored = try JSONDecoder().decode(RemoteModelAnnouncement.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored, model)
        XCTAssertEqual(restored.isAdded, false)
        XCTAssertEqual(restored.isFeatured, true)
    }

    func testModesMenuPermissionsAndSessionActionsMatchReference() {
        XCTAssertEqual(RemoteMode.from(path: "/agent/session/a"), .agent)
        XCTAssertEqual(RemoteMode.from(path: "/code/session/a"), .code)
        XCTAssertEqual(RemoteMode.from(path: "/remote"), .code)
        XCTAssertEqual(RemoteMode.from(path: "/chat/session/a"), .chat)
        XCTAssertEqual(RemoteMode.from(path: "/"), .chat)

        XCTAssertEqual(RemoteMenuRules.entries(attachments: true, mode: .chat, goal: true).map(\.id), [.files, .camera, .photos, .connectors, .context])
        XCTAssertEqual(RemoteMenuRules.entries(attachments: false, mode: .code, goal: true).map(\.id), [.plan, .goal, .connectors, .context])
        XCTAssertEqual(RemoteMenuRules.entries(attachments: true, mode: .agent, goal: true).map(\.id), RemoteMenuEntryID.allCases)
        XCTAssertEqual(RemoteMenuRules.entries(attachments: false, mode: .code, goal: false).map(\.id), [.plan, .connectors, .context])

        XCTAssertEqual(RemotePermissionRules.options(for: .code).map(\.id), ["review", "accept"])
        XCTAssertEqual(RemotePermissionRules.options(for: .agent).map(\.id), ["always_ask", "smart", "auto"])
        XCTAssertNil(RemotePermissionRules.current(mode: .code, approvalMode: "plan").option)
        XCTAssertEqual(RemotePermissionRules.current(mode: .agent, approvalMode: "plan").labelKey, "remotePlanTitle")
        XCTAssertEqual(RemotePermissionRules.modeAfterPlan(mode: .code, remembered: nil), "review")
        XCTAssertEqual(RemotePermissionRules.modeAfterPlan(mode: .agent, remembered: "auto"), "auto")
        XCTAssertEqual(RemotePermissionRules.modeAfterPlan(mode: .code, remembered: "smart"), "review")

        XCTAssertEqual(RemoteSessionRules.primaryAction(status: "running", interrupted: false, mode: .agent), .stop)
        XCTAssertEqual(RemoteSessionRules.primaryAction(status: "idle", interrupted: true, mode: .agent), .resume)
        XCTAssertEqual(RemoteSessionRules.primaryAction(status: "idle", interrupted: true, mode: .code), .send)
    }

    func testAttachmentsAreFilteredAndReferencedWithoutEmbeddingBytes() {
        let small = RemoteAttachmentCandidate(name: "photo.png", size: 1_024, mimeType: "image/png")
        let large = RemoteAttachmentCandidate(name: "video.mov", size: RemoteAttachmentRules.maximumSize + 1, mimeType: "video/quicktime")
        XCTAssertEqual(RemoteAttachmentRules.sort(existingCount: 0, candidates: [small]).accepted, [small])
        XCTAssertEqual(RemoteAttachmentRules.sort(existingCount: 0, candidates: [large]).rejected.first?.reason, .tooLarge)
        XCTAssertEqual(RemoteAttachmentRules.sort(existingCount: 0, candidates: [.init(name: "empty", size: 0)]).rejected.first?.reason, .empty)
        XCTAssertEqual(RemoteAttachmentRules.sort(existingCount: 4, candidates: [small]).rejected.first?.reason, .tooMany)

        XCTAssertEqual(
            RemoteAttachmentRules.reference(transferID: "t-1", file: small),
            .init(transferID: "t-1", name: "photo.png", mimeType: "image/png", size: 1_024)
        )
        XCTAssertEqual(
            RemoteAttachmentRules.reference(transferID: "t-2", file: .init(name: "note", size: 5)).mimeType,
            "application/octet-stream"
        )
        XCTAssertEqual(RemoteAttachmentRules.messagePayload(text: "bonjour", attachments: []), .object(["text": .string("bonjour")]))

        let capabilities = RemoteCapabilities(features: ["attachments": true, "attachmentsAtCreation": true])
        XCTAssertTrue(RemoteAttachmentRules.availableAtCreation(capabilities: capabilities, mode: .code))
        XCTAssertTrue(RemoteAttachmentRules.availableAtCreation(capabilities: capabilities, mode: .agent))
        XCTAssertTrue(RemoteAttachmentRules.availableAtCreation(capabilities: capabilities, mode: .chat))
        XCTAssertTrue(RemoteAttachmentRules.availableAtCreation(
            capabilities: .init(features: ["attachments": true]),
            mode: .chat
        ))
    }

    func testDiffLinesKeepHeadersAndChangesStructurallyDistinct() {
        let lines = RemoteDiffRules.lines(in: """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1 @@
        -let old = true
        +let new = true
         context
        \\ No newline at end of file
        """)

        XCTAssertEqual(
            lines.map(\.kind),
            [.fileHeader, .fileHeader, .fileHeader, .hunkHeader, .deletion, .addition, .context, .metadata]
        )
    }

    func testAgentQuestionsAreSanitizedBoundedAndFormattedLikeDesktop() {
        let pending: RemoteJSONValue = .object([
            "kind": .string("question"),
            "questions": .array([
                .object([
                    "question": .string("Quelle base ?"),
                    "options": .array([
                        .object(["label": .string("SQLite"), "description": .string("Locale")]),
                        .object(["label": .string("Supabase")]),
                    ]),
                ]),
                .object([
                    "question": .string("Quels écrans ?"),
                    "options": .array([.object(["label": .string("Liste")]), .object(["label": .string("Détail")])]),
                    "multi": .bool(true),
                ]),
            ]),
        ])
        guard let questions = RemoteQuestionRules.pendingQuestions(from: pending) else {
            return XCTFail("Questions should be decoded")
        }
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].options[0].description, "Locale")
        XCTAssertEqual(questions[1].multi, true)
        XCTAssertNil(RemoteQuestionRules.pendingQuestions(from: .object(["kind": .string("approval")])))

        XCTAssertEqual(
            RemoteQuestionRules.composeAnswers(questions: [questions[0]], choices: [["SQLite"]], texts: [""], skipped: [false]),
            "SQLite"
        )
        XCTAssertEqual(
            RemoteQuestionRules.composeAnswers(
                questions: questions,
                choices: [["SQLite"], ["Liste", "Détail"]],
                texts: ["", "et la recherche"],
                skipped: [false, false]
            ),
            "1. Quelle base ? → SQLite\n2. Quels écrans ? → Liste, Détail — et la recherche"
        )
        XCTAssertEqual(
            RemoteQuestionRules.composeAnswers(questions: questions, choices: [[], []], texts: ["", ""], skipped: [true, false]),
            "1. Quelle base ? → (passée)\n2. Quels écrans ? → (sans réponse)"
        )
    }

    func testExternalImagesRequireExplicitEngineCapability() {
        XCTAssertTrue(RemoteEngineRules.supportsImageAttachments(agentID: nil, capabilities: nil))
        XCTAssertTrue(RemoteEngineRules.supportsImageAttachments(agentID: "aim", capabilities: nil))
        XCTAssertFalse(RemoteEngineRules.supportsImageAttachments(agentID: "hermes", capabilities: nil))
        XCTAssertFalse(RemoteEngineRules.supportsImageAttachments(agentID: "openclaw", capabilities: .init(engines: [.init(id: "openclaw", state: "ready", features: ["attachments": true, "imageAttachments": false])])))
        XCTAssertTrue(RemoteEngineRules.supportsImageAttachments(agentID: "hermes", capabilities: .init(engines: [.init(id: "hermes", state: "ready", features: ["imageAttachments": true])])))
    }

    func testModelEffortEnginesAndFilteringFollowAnnouncedCapabilities() {
        XCTAssertEqual(RemoteEffortRules.preview(modelID: "claude-sonnet-5").options.count, 5)
        XCTAssertEqual(RemoteEffortRules.preview(modelID: "gpt-5.6-sol").options.count, 6)
        XCTAssertEqual(RemoteEffortRules.preview(modelID: "grok-4.5").currentValue, "high")
        XCTAssertTrue(RemoteEffortRules.preview(modelID: "mistralai/mistral-medium-3.1").isAutomatic)

        let announced = RemoteCapabilities(
            models: [
                .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", provider: "Anthropic", capabilities: ["reasoning"], effortLevels: ["low", "high", "max"], currentEffort: "high"),
            ],
            features: ["effort": true]
        )
        let effort = RemoteEffortRules.effort(capabilities: announced, modelID: "claude-sonnet-5")
        XCTAssertEqual(effort.kind, .real)
        XCTAssertEqual(effort.options.map(\.value), ["low", "high", "max"])
        XCTAssertEqual(effort.currentValue, "high")

        let current = RemoteModelDescriptor(id: "claude-sonnet-5", name: "Claude Sonnet 5", provider: "Anthropic", capabilities: ["reasoning", "vision"])
        let other = RemoteModelDescriptor(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", provider: "OpenAI", capabilities: ["reasoning", "vision"])
        let unknownCaps = RemoteModelRules.rows(capabilities: nil, catalog: [current, other], current: current)
        XCTAssertFalse(unknownCaps.capabilitiesKnown)
        XCTAssertEqual(unknownCaps.rows.map(\.selectable), [false])

        let rows = RemoteModelRules.rows(
            capabilities: .init(models: [.init(id: other.id, name: other.name, provider: other.provider, capabilities: other.capabilities)]),
            catalog: [current, other],
            current: current
        )
        XCTAssertEqual(rows.currentAvailable, false)
        XCTAssertEqual(rows.rows.map(\.id), [current.id, other.id])
        XCTAssertEqual(rows.rows.map(\.selectable), [false, true])

        XCTAssertEqual(RemoteEngineRules.engines(capabilities: nil).map(\.id), [.aim, .openclaw, .hermes])
        XCTAssertTrue(RemoteEngineRules.engines(capabilities: nil).allSatisfy { !$0.selectable })
        let engines = RemoteEngineRules.engines(capabilities: .init(engines: [
            .init(id: "aim", state: "ready"),
            .init(id: "openclaw", state: "stopped"),
            .init(id: "hermes", state: "error"),
        ]))
        XCTAssertEqual(engines.map(\.selectable), [true, true, false])
    }
}
