import AIMApplication
import XCTest

final class MemoryTests: XCTestCase {
    func testExtractionRequiresEvidenceAndRejectsSecrets() throws {
        let source = "Remember that I prefer concise French answers. My project uses SwiftUI."
        let sourceMessageID = UUID()
        let output = #"{"memories":[{"kind":"preference","subject":"response language","content":"The user prefers concise French answers.","evidence":"I prefer concise French answers"},{"kind":"architecture","subject":"UI stack","content":"The project uses SwiftUI.","evidence":"My project uses SwiftUI"},{"kind":"fact","subject":"invented","content":"The user owns a dog.","evidence":"I own a dog"},{"kind":"fact","subject":"password","content":"The password is hunter2.","evidence":"I prefer concise French answers"}]}"#
        let items = MemoryExtraction.parse(output, source: source, projectID: nil, sourceMessageID: sourceMessageID)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.status == .provisional && $0.scope == "global" })
        XCTAssertEqual(items.map(\.subjectKey), ["response language", "UI stack"])
        XCTAssertEqual(items.first?.evidenceQuote, "I prefer concise French answers")
        XCTAssertEqual(items.first?.sourceMessageID, sourceMessageID)
        XCTAssertEqual(MemoryExtraction.parse("not json", source: source, projectID: nil), [])
        let sensitive = #"{"memories":[{"kind":"fact","subject":"email","content":"Email me at mat@example.com.","evidence":"Email me at mat@example.com"}]}"#
        XCTAssertTrue(MemoryExtraction.parse(sensitive, source: "Email me at mat@example.com", projectID: nil).isEmpty)
    }

    func testProjectScopingAndRecallExcludeArchivedOtherProjects() throws {
        let conversation = UUID(), project = UUID(), other = UUID()
        let source = "Use SwiftUI for this project."
        let output = #"{"memories":[{"kind":"architecture","subject":"UI stack","content":"This project uses SwiftUI.","evidence":"Use SwiftUI for this project"}]}"#
        let projectItem = try XCTUnwrap(MemoryExtraction.parse(output, source: source, projectID: project).first)
        let otherItem = MemoryItem(kind: .fact, scope: "project", scopeKey: other.uuidString,
                                   subjectKey: "SwiftUI", content: "Other project", status: .verified)
        var archived = projectItem
        archived.id = UUID(); archived.status = .archived
        let history = [ConversationMessage(conversationID: conversation, role: .user, content: "How should I use SwiftUI?", sequence: 0)]
        let selected = MemoryContext.relevant([projectItem, otherItem, archived], query: "SwiftUI", projectID: project)
        XCTAssertEqual(selected.map(\.id), [projectItem.id])
        let result = MemoryContext.messages(history, items: [projectItem, otherItem, archived],
                                            query: "SwiftUI", projectID: project, conversationID: conversation)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].content.contains("AI-extracted, unreviewed"))
        XCTAssertEqual(result.last, history.last)
        XCTAssertEqual(MemoryContext.messages(history, items: [projectItem], query: "SwiftUI",
                                              projectID: nil, conversationID: conversation), history)
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            let request = try ProviderChatService.request(provider: provider, modelID: "fixture", messages: result,
                                                          apiKey: "fixture", mode: .chat, catalogMaximumOutputTokens: 4096)
            XCTAssertTrue(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("This project uses SwiftUI"))
        }
    }

    func testOnlyRelevantAndPinnedMemoriesFitBudget() {
        let matching = MemoryItem(kind: .preference, scope: "global", scopeKey: "self", subjectKey: "language",
                                  content: "Use French language.", status: .verified)
        let unrelated = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "pet",
                                   content: "The user likes cats.", status: .provisional)
        var pinned = unrelated
        pinned.id = UUID(); pinned.isPinned = true
        let items = [matching, unrelated, pinned]
        XCTAssertEqual(MemoryContext.relevant(items, query: "French language", projectID: nil, maximumItems: 2).map(\.id),
                       [pinned.id, matching.id])
        XCTAssertTrue(MemoryContext.relevant(items, query: "French", projectID: nil, maximumBytes: 1).isEmpty)
    }

    func testSettingsDefaultToAutomaticMemoryAndRemainBackwardCompatible() throws {
        var settings = AppSettings()
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).memoryEnabled)
        settings.memoryEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testExtractionRequestDoesNotExposePerplexityWebSearch() throws {
        let id = UUID()
        let messages = try XCTUnwrap(MemoryExtraction.requestMessages(userText: "I prefer short answers.", conversationID: id))
        let request = try ProviderChatService.request(provider: .perplexity, modelID: "perplexity/sonar",
                                                      messages: messages, apiKey: "fixture", mode: .chat,
                                                      useWebSearch: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["tools"])
    }

    func testAutomaticAndExplicitRememberingAreDistinctButBothSupported() throws {
        let id = UUID()
        let ordinary = try XCTUnwrap(MemoryExtraction.requestMessages(userText: "I prefer concise answers.", conversationID: id))
        XCTAssertTrue(ordinary[0].content.contains("even without an explicit request"))
        XCTAssertFalse(MemoryExtraction.requestsRemembering("I prefer concise answers."))

        let french = "Souviens-toi de ma préférence pour les réponses concises."
        XCTAssertTrue(MemoryExtraction.requestsRemembering(french))
        XCTAssertTrue(MemoryExtraction.requestsRemembering("Please remember that my project uses SwiftUI."))
        XCTAssertFalse(MemoryExtraction.requestsRemembering("I do not remember that meeting."))
        let output = #"{"memories":[{"kind":"preference","subject":"answer length","content":"The user prefers concise answers.","evidence":"ma préférence pour les réponses concises"}]}"#
        XCTAssertEqual(MemoryExtraction.parse(output, source: french, projectID: nil).first?.subjectKey, "answer length")
    }
}

extension MemoryTests {
    func testProjectOnlyContextRejectsGlobalProfileEvenWhenRepositoryReturnsIt() {
        let project = UUID(), conversation = UUID()
        let global = MemoryItem(kind: .preference, scope: "global", scopeKey: "self", subjectKey: "private global profile", content: "Global private preference", status: .verified, isPinned: true)
        let scoped = MemoryItem(kind: .constraint, scope: "project", scopeKey: project.uuidString, subjectKey: "project rule", content: "Scoped project preference", status: .verified, isPinned: true)
        let other = MemoryItem(kind: .constraint, scope: "project", scopeKey: UUID().uuidString, subjectKey: "other", content: "Foreign private preference", status: .verified, isPinned: true)
        let all = [global, scoped, other]
        XCTAssertEqual(MemoryContext.profile(all, projectID: project, includeGlobal: false).map(\.id), [scoped.id])
        XCTAssertEqual(MemoryContext.relevant(all, query: "preference", projectID: project, includeGlobal: false).map(\.id), [scoped.id])
        let context = MemoryContext.messages([], items: all, query: "preference", projectID: project, conversationID: conversation, includeGlobal: false).map(\.content).joined()
        XCTAssertTrue(context.contains(scoped.content)); XCTAssertFalse(context.contains(global.content)); XCTAssertFalse(context.contains(other.content))
        XCTAssertTrue(MemoryContext.profile(all, projectID: project).contains { $0.id == global.id })
    }
}
