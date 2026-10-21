import AIMCore
import Testing
@testable import AIM

@MainActor @Suite("Shared brand logos")
struct AIMBrandLogoTests {
    @Test func creatorsUseExactDesktopMappings() {
        #expect(AIMBrandRegistry.asset(for: "aion-labs/aion-rp-llama") == "logo-aionlabs")
        #expect(AIMBrandRegistry.asset(for: "black-forest-labs/flux") == "logo-bfl")
        #expect(AIMBrandRegistry.asset(for: "oauth_slack") == "slackpng")
        #expect(AIMBrandRegistry.asset(for: "oauth_canva") == "brand-canva")
    }

    @Test func knownCatalogueNeedsNoNetworkForLogos() {
        for connector in ConnectorCatalog.connectors {
            #expect(AIMLogoImageCache.shared.image(asset: AIMBrandRegistry.asset(for: connector.id)) != nil, "Missing bundled connector logo: \(connector.id)")
        }
        for provider in ["sambanova", "deepinfra", "nebius", "novita", "venice", "aion-labs", "black-forest-labs"] {
            #expect(AIMLogoImageCache.shared.image(asset: AIMBrandRegistry.asset(for: provider)) != nil)
        }
    }

    @Test func repeatedRowsReuseDecodedBitmap() {
        let first = AIMLogoImageCache.shared.image(asset: "brand-canva")
        let second = AIMLogoImageCache.shared.image(asset: "brand-canva")
        #expect(first != nil)
        #expect(first === second)
    }
}
