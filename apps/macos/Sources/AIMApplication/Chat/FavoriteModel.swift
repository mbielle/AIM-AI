import AIMCore
import Foundation

public struct FavoriteModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let provider: ChatProvider
    public let modelID: String
    public let name: String
    public var id: String { "\(provider.rawValue):\(modelID)" }

    public init(provider: ChatProvider, modelID: String, name: String) throws {
        guard !modelID.isEmpty, modelID.utf8.count <= 255, !modelID.contains(".."),
              modelID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }),
              !name.contains("\0") else { throw FavoriteModelError.invalidModel }
        self.provider = provider; self.modelID = modelID
        self.name = String((name.isEmpty ? modelID : name).prefix(200))
    }

    public static func toggling(_ item: FavoriteModel, in favorites: [FavoriteModel]) throws -> [FavoriteModel] {
        if favorites.contains(where: { $0.id == item.id }) { return favorites.filter { $0.id != item.id } }
        return favorites + [item]
    }
}

public enum FavoriteModelError: LocalizedError {
    case invalidModel
    public var errorDescription: String? {
        switch self {
        case .invalidModel: "This model identifier cannot be saved as a favorite."
        }
    }
}
