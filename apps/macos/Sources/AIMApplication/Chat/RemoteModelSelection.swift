import AIMCore
import Foundation

/// A model identifier alone is not a billing route. Legacy requests may omit
/// the provider only while the connected catalogs identify one unique route.
public enum RemoteModelSelection {
    public static func resolve(modelID: String, providerName: String?, connected: Set<ChatProvider>,
                               cache: ModelCatalogCache = .shared) async throws -> ChatProvider {
        guard !modelID.isEmpty else { throw RemoteModelSelectionError.unavailable }
        if let providerName {
            guard let provider = ChatProvider(rawValue: providerName), connected.contains(provider),
                  await cache.cached(provider)?.contains(where: { $0.id == modelID }) == true else {
                throw RemoteModelSelectionError.unavailable
            }
            return provider
        }
        var matches: [ChatProvider] = []
        for provider in ChatProvider.allCases where connected.contains(provider) {
            if await cache.cached(provider)?.contains(where: { $0.id == modelID }) == true { matches.append(provider) }
        }
        guard matches.count == 1, let provider = matches.first else {
            throw matches.isEmpty ? RemoteModelSelectionError.unavailable : RemoteModelSelectionError.ambiguous
        }
        return provider
    }
}

public enum RemoteModelSelectionError: String, Error, Sendable {
    case unavailable = "modele_inconnu"
    case ambiguous = "modele_ambigu"
}
