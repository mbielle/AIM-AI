import Foundation

public struct AccountChatPreferences: Codable, Equatable, Sendable {
    public enum ResponseStyle: String, Codable, CaseIterable, Sendable { case balanced, concise, detailed }
    public var responseStyle: ResponseStyle = .balanced
    public var responseLanguage = ""
    public var customInstructions: String?
    public var subagentDefaults: [String: SubagentPreferences]?
    public var researchMode: AIMResearchMode?
    public var resolvedResearchMode: AIMResearchMode { researchMode ?? .hosted }
    public var automaticWebSearch: Bool?
    public var usesAutomaticWebSearch: Bool { automaticWebSearch != false }
    public var warmth: String?
    public var enthusiasm: String?
    public var formatting: String?
    public var emoji: String?
    public init() {}
    public var instructions: String {
        var parts: [String] = []
        switch responseStyle {
        case .balanced: break
        case .concise: parts.append("Use concise answers unless the request calls for detail.")
        case .detailed: parts.append("Provide detailed explanations when useful.")
        }
        if !responseLanguage.isEmpty { parts.append("Preferred response language: \(responseLanguage).") }
        for (name, value) in [("Warmth", warmth), ("Enthusiasm", enthusiasm), ("Formatting", formatting), ("Emoji", emoji)] {
            if let value, value != "default" { parts.append("Preferred \(name.lowercased()): \(value).") }
        }
        if let customInstructions, !customInstructions.isEmpty { parts.append(customInstructions) }
        return parts.joined(separator: "\n")
    }
}
