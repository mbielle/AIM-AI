@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ProviderOnboardingTests: XCTestCase {
    func testMissingDirectProviderKeyIsOnboardingNotCatalogFailure() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        for provider in [ChatProvider.anthropic, .openAI, .google, .deepSeek, .xAI, .perplexity] {
            model.selectedProvider = provider
            model.availableModels = [ChatModel(id: "stale", name: "Stale")]
            model.catalogError = "stale error"
            await model.loadModels()
            XCTAssertFalse(model.isLoadingModels, provider.name)
            XCTAssertTrue(model.availableModels.isEmpty, provider.name)
            XCTAssertNil(model.catalogError, provider.name)
        }
    }
}
