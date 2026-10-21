@testable import AIMMac
import AIMApplication
import AIMCore
import Foundation
import XCTest

final class ChatGPTDerivedCredentialTests: XCTestCase {
    func testMemoryCaptureRejectsLegacyRawCredentialBeforeProviderRequest() async throws {
        let database = try AIMDatabase(inMemory: true)
        let service = MemoryCaptureService(repository: SQLiteMemoryRepository(database: database),
                                           secureStore: RawChatGPTReadTrap())
        let conversation = Conversation(title: "Synthetic memory", provider: .chatgpt, modelID: "gpt-test")
        let text = "Remember that I prefer concise code examples."
        XCTAssertNotNil(MemoryExtraction.requestMessages(userText: text, conversationID: conversation.id))
        do {
            _ = try await service.proposals(userText: text, sourceMessageID: UUID(), conversation: conversation)
            XCTFail("A raw credential is not a verified ChatGPT plan grant")
        } catch ProviderCredentialError.expired {
            // Expected before any provider transport is constructed.
        } catch {
            XCTFail("Expected the session guard, not a raw credential read or provider request: \(type(of: error))")
        }
    }

    func testSkillReviewRejectsLegacyRawCredentialBeforeProviderRequest() async throws {
        XCTAssertTrue(ChatProvider.chatgpt.supportsWorkspaceTools, "Exercise the actual tool-capable branch")
        let service = SkillLearningService(secureStore: RawChatGPTReadTrap(), meter: BillableRequestMeter())
        let message = ConversationMessage(conversationID: UUID(), role: .user, content: "Review this synthetic run.", sequence: 0)
        do {
            _ = try await service.review(provider: .chatgpt, modelID: "gpt-test", message: message)
            XCTFail("A raw credential is not a verified ChatGPT plan grant")
        } catch ProviderCredentialError.expired {
            // Expected before any provider transport is constructed.
        } catch {
            XCTFail("Expected the session guard, not a raw credential read or provider request: \(type(of: error))")
        }
    }
}

/// Never returns an access token: even a regression cannot send a real request.
private struct RawChatGPTReadTrap: SecureStoring {
    enum UnexpectedAccess: Error { case rawCredential, mutation }
    func readData(forKey key: String) throws -> Data? {
        if key == ChatGPTPlanAuth.sessionKey { return nil }
        throw UnexpectedAccess.rawCredential
    }
    func store(_ data: Data, forKey key: String) throws { throw UnexpectedAccess.mutation }
    func removeData(forKey key: String) throws { throw UnexpectedAccess.mutation }
}
