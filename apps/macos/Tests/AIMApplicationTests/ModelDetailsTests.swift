@testable import AIMApplication
import AIMCore
import Foundation
import XCTest

final class ModelDetailsTests: XCTestCase {
    private let openRouterJSON = """
    {"id":"anthropic/claude-sonnet-5.5","name":"Anthropic: Claude Sonnet 5.5","created":1780000000,
     "context_length":1000000,"description":"Balanced model.",
     "architecture":{"input_modalities":["text","image","file"],"output_modalities":["text"]},
     "pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003"},
     "top_provider":{"context_length":1000000,"max_completion_tokens":64000},
     "supported_parameters":["tools","reasoning","max_tokens"],"knowledge_cutoff":"2026-03"}
    """

    func testOpenRouterFactsDecodeIntoTheModel() throws {
        let model = try JSONDecoder().decode(ChatModel.self, from: Data(openRouterJSON.utf8))
        XCTAssertEqual(model.summary, "Balanced model.")
        XCTAssertEqual(model.pricing?.inputPerMillion ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(model.pricing?.outputPerMillion ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(model.pricing?.cacheReadPerMillion ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.topProvider?.maxCompletionTokens, 64_000)
        XCTAssertEqual(model.knowledgeCutoff, "2026-03")
        XCTAssertEqual(model.capabilities, [.vision, .files, .tools, .reasoning])
        XCTAssertNil(ChatModel.Pricing.perMillion("-1"), "OpenRouter's variable price is not shown as a number")
    }

    func testDirectProviderModelBorrowsOpenRouterFacts() throws {
        let reference = try JSONDecoder().decode(ChatModel.self, from: Data(openRouterJSON.utf8))
        let direct = ChatModel(id: "claude-sonnet-5-5-20260301", name: "Claude Sonnet 5.5", maxOutputTokens: 128_000)
        let enriched = ModelDetailsLookup.enriched(direct, provider: .anthropic, catalog: [reference])
        XCTAssertEqual(enriched.summary, "Balanced model.")
        XCTAssertEqual(enriched.pricing?.outputPerMillion ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(enriched.contextLength, 1_000_000)
        XCTAssertEqual(enriched.maxOutputTokens, 128_000, "Filling the public description must preserve the exact provider output capacity")
        XCTAssertTrue(enriched.capabilities.contains(.vision))
        XCTAssertEqual(enriched.id, direct.id, "the request still uses the provider's own id")

        let unknown = ChatModel(id: "claude-unreleased", name: "Unreleased")
        XCTAssertNil(ModelDetailsLookup.enriched(unknown, provider: .anthropic, catalog: [reference]).pricing)
    }

    func testRemoteModelDetailsMatchMacEnrichmentWithoutChangingTheRoute() throws {
        let reference = try JSONDecoder().decode(ChatModel.self, from: Data(openRouterJSON.utf8))
        let direct = ChatModel(id: "claude-sonnet-5-5-20260301", name: "Claude Sonnet 5.5", maxOutputTokens: 128_000)
        let expected = ModelDetailsLookup.enriched(direct, provider: .anthropic, catalog: [reference])
        let announcement = try XCTUnwrap(RemoteModelCatalogMetadata.announcements([direct], provider: .anthropic, favorites: [], additions: [], reference: [reference]).first)
        XCTAssertEqual(announcement.detail, expected)
        XCTAssertEqual(announcement.detail?.pricing?.outputPerMillion, 15)
        XCTAssertEqual(announcement.detail?.maxOutputTokens, 128_000)
        XCTAssertEqual(announcement.detail?.topProvider?.maxCompletionTokens, 64_000)
        XCTAssertEqual(announcement.capabilities, expected.capabilities.map(\.rawValue).sorted())
        XCTAssertEqual(announcement.provider, ChatProvider.anthropic.rawValue)
        XCTAssertEqual(announcement.id, direct.id)
    }

    func testSharedEnrichmentPreservesKnownDirectFactsAndDoesNotGuessDifferentModels() throws {
        let reference = try JSONDecoder().decode(ChatModel.self, from: Data(openRouterJSON.utf8))
        var direct = ChatModel(id: "claude-sonnet-5-5", name: "Direct", contextLength: 32_000, inputModalities: ["text"], maxOutputTokens: 8_000)
        direct.architecture = .init(inputModalities: ["text"], outputModalities: nil)
        direct.pricing = .init(prompt: "0.000001", completion: "0.000002")
        let enriched = try XCTUnwrap(ModelCatalogDetails.enrich([direct], provider: .anthropic, publicModels: [reference]).first)
        XCTAssertEqual(enriched.id, direct.id); XCTAssertEqual(enriched.name, direct.name)
        XCTAssertEqual(enriched.contextLength, 32_000); XCTAssertEqual(enriched.maxOutputTokens, 8_000)
        XCTAssertEqual(enriched.pricing, direct.pricing)
        XCTAssertEqual(enriched.architecture?.inputModalities, ["text"])
        XCTAssertFalse(enriched.capabilities.contains(.vision))
        let unknown = ChatModel(id: "claude-sonnet-5-5-extra", name: "Other")
        XCTAssertEqual(ModelCatalogDetails.enrich([unknown], provider: .anthropic, publicModels: [reference]), [unknown])
    }

    func testRemotePricingProvenanceDistinguishesReferenceDirectAndUnknownPrices() throws {
        let reference = try JSONDecoder().decode(ChatModel.self, from: Data(openRouterJSON.utf8))
        var direct = ChatModel(id: "claude-sonnet-5-5", name: "Direct")
        let borrowed = try XCTUnwrap(RemoteModelCatalogMetadata.announcements([direct], provider: .anthropic, favorites: [], additions: [], reference: [reference]).first)
        XCTAssertEqual(borrowed.isReferencePricing, true)
        direct.pricing = .init(prompt: "0.000001", completion: "0.000002")
        let native = try XCTUnwrap(RemoteModelCatalogMetadata.announcements([direct], provider: .anthropic, favorites: [], additions: [], reference: [reference]).first)
        XCTAssertEqual(native.isReferencePricing, false)
        XCTAssertEqual(native.detail?.pricing, direct.pricing)
        let router = try XCTUnwrap(RemoteModelCatalogMetadata.announcements([reference], provider: .openRouter, favorites: [], additions: [], reference: [reference]).first)
        XCTAssertEqual(router.isReferencePricing, false)
        let unknown = try XCTUnwrap(RemoteModelCatalogMetadata.announcements([ChatModel(id: "unknown", name: "Unknown")], provider: .anthropic, favorites: [], additions: [], reference: [reference]).first)
        XCTAssertNil(unknown.detail?.pricing)
        XCTAssertEqual(unknown.isReferencePricing, false)
    }

    func testDisplayNameDropsTheMakerPrefix() {
        XCTAssertEqual(ModelIdentity.displayName(ChatModel(id: "inclusionai/ling", name: "inclusionAI: Ling 3.1 Flash"), via: .openRouter), "Ling 3.1 Flash")
        XCTAssertEqual(ModelIdentity.creatorName("arcee-ai"), "Arcee AI")
    }
}
