import Foundation

public enum RemoteProtectionPreset: String, CaseIterable, Sendable {
    case none, codeAgent, all, custom
    public var modes: [RemoteMode] {
        switch self {
        case .none: []
        case .codeAgent: [.code, .agent]
        case .all: [.chat, .code, .agent]
        case .custom: []
        }
    }
}

/// Authoritative account policy, read from the paired relay; never a local bypass.
public struct RemoteProtectionPolicy: Codable, Equatable, Sendable {
    public let version: Int
    public let revision: Int
    public let protectedModes: [RemoteMode]
    public let unlockAuthorized: Bool
    public init(revision: Int, protectedModes: [RemoteMode], unlockAuthorized: Bool = false) {
        self.unlockAuthorized = unlockAuthorized
        version = 1; self.revision = revision
        self.protectedModes = RemoteMode.allCases.filter { protectedModes.contains($0) }
    }
    enum CodingKeys: String, CodingKey { case version, revision; case protectedModes = "protected_modes", unlockAuthorized = "unlock_authorized" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        revision = try c.decode(Int.self, forKey: .revision)
        unlockAuthorized = try c.decode(Bool.self, forKey: .unlockAuthorized)
        let modes = try c.decode([RemoteMode].self, forKey: .protectedModes)
        guard version == 1, revision >= 0, Set(modes).count == modes.count else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Invalid protection policy")
        }
        protectedModes = RemoteMode.allCases.filter { modes.contains($0) }
    }
    public var preset: RemoteProtectionPreset {
        if protectedModes.isEmpty { return .none }
        if Set(protectedModes) == Set(RemoteProtectionPreset.codeAgent.modes) { return .codeAgent }
        if protectedModes.count == RemoteMode.allCases.count { return .all }
        return .custom
    }
    public func protects(_ mode: RemoteMode) -> Bool { protectedModes.contains(mode) }
}
