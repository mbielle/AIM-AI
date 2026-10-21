import Foundation

public struct NativeSkillManifest: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var version: String
    public var origin: String
    public var requiresMac: Bool?
    public var availabilityNote: String?
    public init(name: String, summary: String, version: String, origin: String, requiresMac: Bool? = nil, availabilityNote: String? = nil) { self.name = name; self.summary = summary; self.version = version; self.origin = origin; self.requiresMac = requiresMac; self.availabilityNote = availabilityNote }
}
/// Versioned read-only section of get_mac_settings. Older Macs fail decoding explicitly.
public enum NativeSkillImportContract {
    public static func request(name: String? = nil) throws -> RemoteJSONValue {
        if let name, !NativeSkillRules.validName(name) { throw NativeSkillError.invalidPath }
        var fields: [String: RemoteJSONValue] = ["section": .string("skills"), "version": .number(1)]
        if let name { fields["name"] = .string(name) }
        return .object(fields)
    }
    public static func installRequest(_ skill: NativeSkill) throws -> RemoteJSONValue {
        let validated = try NativeSkill(name: skill.name, summary: skill.summary, origin: skill.origin, files: skill.files, modelInvocable: skill.modelInvocable)
        let row = try JSONDecoder().decode(RemoteJSONValue.self, from: JSONEncoder().encode(validated))
        return .object(["section": .string("skills"), "action": .string("install"), "skill": row])
    }
    public static func manifests(_ result: RemoteJSONValue) throws -> [NativeSkillManifest] {
        guard result.objectValue?["section"]?.stringValue == "skills", let rows = result.objectValue?["skills"] else { throw NativeSkillError.unavailable }
        return try JSONDecoder().decode([NativeSkillManifest].self, from: JSONEncoder().encode(rows))
    }
    public static func skill(_ result: RemoteJSONValue) throws -> NativeSkill {
        guard result.objectValue?["section"]?.stringValue == "skills", let row = result.objectValue?["skill"] else { throw NativeSkillError.unavailable }
        let decoded = try JSONDecoder().decode(NativeSkill.self, from: JSONEncoder().encode(row))
        // Codable decoding never bypasses validation at the import boundary.
        return try NativeSkill(name: decoded.name, summary: decoded.summary, origin: decoded.origin, files: decoded.files, modelInvocable: decoded.modelInvocable)
    }
}
