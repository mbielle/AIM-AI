import AIMCore
import Foundation

/// Only the installed global skill directory is exported. No credentials, paths,
/// hidden files, symlinks or workspace files are exposed by this account-level read.
public enum RemoteSkillExport {
    public static func result(_ payload: RemoteJSONValue, global: URL? = SkillCatalog.globalDirectory) throws -> RemoteJSONValue {
        guard payload.objectValue?["section"]?.stringValue == "skills" else { throw NativeSkillError.invalidPath }
        let skills = SkillCatalog.discover(workspace: nil, global: global)
        let encoder = JSONEncoder()
        let value: RemoteJSONValue
        let key: String
        if let name = payload.objectValue?["name"]?.stringValue {
            guard NativeSkillRules.validName(name), let skill = skills.first(where: { $0.name == name }) else { throw NativeSkillError.unavailable }
            value = try JSONDecoder().decode(RemoteJSONValue.self, from: encoder.encode(bundle(skill)))
            key = "skill"
        } else {
            let rows = skills.map { skill -> NativeSkillManifest in
                let exported = try? bundle(skill)
                return .init(name: skill.name, summary: skill.description, version: exported?.version ?? "", origin: "mac:" + (skill.origin ?? "installed"), requiresMac: exported?.dependencyNotice != nil, availabilityNote: exported == nil ? "This skill cannot be copied safely to iPhone. It remains available on the Mac." : nil)
            }
            value = try JSONDecoder().decode(RemoteJSONValue.self, from: encoder.encode(rows))
            key = "skills"
        }
        return .object(["section": .string("skills"), "version": .number(1), key: value])
    }
    private static func bundle(_ skill: Skill) throws -> NativeSkill {
        guard (try skill.directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeSkillError.invalidPath }
        let root = skill.directory.resolvingSymlinksInPath().standardizedFileURL
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { throw NativeSkillError.invalidPath }
        var files: [String: String] = [:]; var size = 0
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, NativeSkillRules.safePath(relative) else { continue }
            guard let text = try? SkillCatalog.readFile(skill, relativePath: relative, maximumBytes: 10 * 1024 * 1024) else { continue }
            guard !text.hasSuffix("[truncated at 10485760 bytes]") else { throw NativeSkillError.tooLarge }
            size += text.utf8.count
            guard size <= 10 * 1024 * 1024, files.count < 200 else { throw NativeSkillError.tooLarge }
            files[relative] = text
        }
        return try NativeSkill(name: skill.name, summary: skill.description, origin: "mac:" + (skill.origin ?? "installed"), files: files, modelInvocable: skill.modelInvocable)
    }
}

extension RemoteSkillExport {
    /// Explicit, protected settings mutation. The phone supplies the reviewed
    /// bundle, never a filesystem destination or executable command.
    public static func install(_ payload: RemoteJSONValue, global: URL? = SkillCatalog.globalDirectory, disable: ((String) -> Void)? = nil) throws -> RemoteJSONValue {
        guard payload.objectValue?["section"]?.stringValue == "skills",
              payload.objectValue?["action"]?.stringValue == "install",
              let raw = payload.objectValue?["skill"], let global else { throw NativeSkillError.invalidSkill }
        let decoded = try JSONDecoder().decode(NativeSkill.self, from: JSONEncoder().encode(raw))
        let skill = try NativeSkill(name: decoded.name, summary: decoded.summary, origin: decoded.origin, files: decoded.files, modelInvocable: decoded.modelInvocable)
        guard let parsed = NativeSkillRules.parse(skill.files["SKILL.md"] ?? ""), parsed.name == skill.name else { throw NativeSkillError.invalidSkill }
        let manager = FileManager.default
        try manager.createDirectory(at: global, withIntermediateDirectories: true)
        guard (try global.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeSkillError.invalidPath }
        let staging = global.appendingPathComponent(".phone-import-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        for (path, text) in skill.files {
            guard NativeSkillRules.safePath(path), !NativeSkillRules.containsCredential(text) else { throw NativeSkillError.invalidPath }
            let file = staging.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = path == "SKILL.md" ? SkillHub.withProvenance(text, origin: "phone:" + skill.origin) : text
            try Data(contents.utf8).write(to: file, options: .atomic)
        }
        let destination = global.appendingPathComponent(skill.name, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeSkillError.invalidPath }
            let versionsRoot = global.appendingPathComponent(".versions", isDirectory: true)
            let versionsFolder = versionsRoot.appendingPathComponent(skill.name, isDirectory: true)
            for directory in [versionsRoot, versionsFolder] {
                if manager.fileExists(atPath: directory.path) {
                    guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true,
                          (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw NativeSkillError.invalidPath }
                } else { try manager.createDirectory(at: directory, withIntermediateDirectories: false) }
            }
            let version = versionsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.moveItem(at: destination, to: version)
            do { try manager.moveItem(at: staging, to: destination) }
            catch { try? manager.moveItem(at: version, to: destination); throw error }
        } else { try manager.moveItem(at: staging, to: destination) }
        if let disable { disable(skill.name) }
        else { var disabled = SkillPreferences.disabled; disabled.insert(skill.name); SkillPreferences.disabled = disabled }
        return .object(["section": .string("skills"), "installed": .string(skill.name), "enabled": .bool(false)])
    }
}
