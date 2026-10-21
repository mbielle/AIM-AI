import Foundation

/// Local presentation only. Never included in provider requests or message content.
public struct ConversationAppearance: Codable, Equatable, Sendable {
    public enum Typeface: String, Codable, CaseIterable, Sendable {
        case lora, system
    }

    public let typeface: Typeface
    public let textSize: Int

    public init(typeface: Typeface = .lora, textSize: Int = 15) {
        self.typeface = typeface
        self.textSize = min(max(textSize, 12), 24)
    }

    public var codeSize: Int { max(11, textSize - 3) }
    public var tableSize: Int { max(12, textSize - 2) }
    public var mathSize: Int { textSize + 2 }
    public func headingSize(level: Int) -> Int {
        textSize + (level == 1 ? 10 : level == 2 ? 6 : 2)
    }

    private enum CodingKeys: String, CodingKey { case typeface, textSize }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decodeIfPresent(String.self, forKey: .typeface)
        self.init(typeface: name.flatMap(Typeface.init(rawValue:)) ?? .lora,
                  textSize: try values.decodeIfPresent(Int.self, forKey: .textSize) ?? 15)
    }
}
