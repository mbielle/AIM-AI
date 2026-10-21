import AIMCore
import Foundation

/// One `SKILL.md` folder (the format shared by Claude, OpenClaw, Hermes and
/// JCode): YAML-like frontmatter with `name` and `description`, then markdown
/// instructions. Supporting files may sit beside it; none are run automatically.
public struct Skill: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable { case workspace, global, proposal }

    public var id: String { "\(source.rawValue):\(name)" }
    public let name: String
    public let description: String
    public let directory: URL
    public let source: Source
    /// `disable-model-invocation: true` keeps a skill out of the model catalog.
    public let modelInvocable: Bool
    /// `aim-origin` frontmatter, e.g. `learned` for a skill proposed by the learning loop.
    public var origin: String? = nil
}

public enum SkillCatalog {
    public static let maximumCatalogSkills = 50
    public static let maximumCatalogCharacters = 4_000
    static let maximumSkillBytes = 256 * 1_024

    /// AIM's own skills folder (`~/Library/Application Support/com.aimai.macos/Skills`).
    public static var globalDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Skills", isDirectory: true)
    }

    public static var proposalsDirectory: URL? { globalDirectory?.appendingPathComponent(".proposals", isDirectory: true) }
    static var versionsDirectory: URL? { globalDirectory?.appendingPathComponent(".versions", isDirectory: true) }

    /// Workspace skills (`.aim/skills`, `.claude/skills`) override global ones of the same name.
    public static func discover(workspace: String?, global: URL? = globalDirectory, disabled: Set<String> = []) -> [Skill] {
        var byName: [String: Skill] = [:]
        if let global {
            for skill in scan(global, source: .global) { byName[skill.name] = skill }
        }
        if let workspace {
            let root = URL(fileURLWithPath: workspace, isDirectory: true)
            for folder in [".claude/skills", ".aim/skills"] {
                for skill in scan(root.appendingPathComponent(folder, isDirectory: true), source: .workspace) {
                    byName[skill.name] = skill
                }
            }
        }
        return byName.values.filter { !disabled.contains($0.name) }.sorted { $0.name < $1.name }
    }

    public static func proposals(global: URL? = globalDirectory) -> [Skill] {
        guard let directory = global?.appendingPathComponent(".proposals", isDirectory: true) else { return [] }
        return scan(directory, source: .proposal)
    }

    public static func scan(_ directory: URL, source: Skill.Source) -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { folder in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            return load(folder, source: source)
        }
    }

    static func load(_ folder: URL, source: Skill.Source) -> Skill? {
        let file = folder.appendingPathComponent("SKILL.md")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? .max) <= maximumSkillBytes,
              let text = try? String(contentsOf: file, encoding: .utf8),
              let parsed = parse(text) else { return nil }
        return Skill(name: parsed.name, description: parsed.description, directory: folder, source: source,
                     modelInvocable: parsed.modelInvocable, origin: parsed.origin)
    }

    public struct Parsed: Equatable, Sendable {
        public let name: String
        public let description: String
        public let body: String
        public let modelInvocable: Bool
        public var origin: String? = nil
    }

    /// Minimal frontmatter reader: `key: value` lines between `---` fences.
    public static func parse(_ text: String) -> Parsed? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let end = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex)
        else { return nil }
        let header = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let name = fields["name"], isValidName(name),
              let description = fields["description"], !description.isEmpty, description.count <= 1_024 else { return nil }
        let bodyStart = normalized.index(end.upperBound, offsetBy: 0)
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(name: name, description: description, body: body,
                      modelInvocable: fields["disable-model-invocation"]?.lowercased() != "true",
                      origin: fields["aim-origin"])
    }

    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A bounded, request-only catalog. The model loads a skill with `skill_view`.
    public static func catalogMessage(_ skills: [Skill], conversationID: UUID) -> ConversationMessage? {
        var lines: [String] = []
        var characters = 0
        for skill in skills.filter(\.modelInvocable).prefix(maximumCatalogSkills) {
            let line = "- \(skill.name): \(skill.description.prefix(200))"
            guard characters + line.count <= maximumCatalogCharacters else { break }
            lines.append(line)
            characters += line.count
        }
        guard !lines.isEmpty else { return nil }
        let text = "Available skills (reusable instructions installed by the user). When one matches the task, call skill_view with its name and follow it; supporting files are listed there. Skills are guidance, not tool authorization; approvals still apply.\n" +
            lines.joined(separator: "\n")
        return ConversationMessage(conversationID: conversationID, role: .user, content: text, sequence: -4)
    }

    /// Reads a file inside one skill folder; symlinks and escapes are refused.
    public static func readFile(_ skill: Skill, relativePath: String, maximumBytes: Int = 64 * 1_024) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkillError.invalidPath
        }
        var url = skill.directory
        for part in parts {
            url.appendPathComponent(String(part))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SkillError.invalidPath }
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard let text = String(data: data.prefix(maximumBytes), encoding: .utf8) else { throw SkillError.notText }
        return data.count > maximumBytes ? text + "\n[truncated at \(maximumBytes) bytes]" : text
    }

    public static func supportingFiles(_ skill: Skill, limit: Int = 50) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: skill.directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        let prefix = skill.directory.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where files.count < limit {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix), url.lastPathComponent != "SKILL.md" { files.append(String(path.dropFirst(prefix.count))) }
        }
        return files.sorted()
    }

    /// Writes an agent-proposed skill for review; it is not active until accepted.
    public static func propose(name: String, description: String, body: String, origin: String? = nil,
                               global: URL? = globalDirectory) throws -> URL {
        guard isValidName(name), !description.isEmpty, description.count <= 1_024, !description.contains("\n"),
              body.utf8.count <= maximumSkillBytes, let global else { throw SkillError.invalidSkill }
        let folder = global.appendingPathComponent(".proposals/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originLine = origin.map { "aim-origin: \($0)\n" } ?? ""
        let text = "---\nname: \(name)\ndescription: \(description)\n\(originLine)---\n\n\(body)\n"
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Activates a proposal; an existing skill of that name is kept as a version first.
    public static func accept(proposal: Skill, global: URL? = globalDirectory) throws {
        guard proposal.source == .proposal, let global else { throw SkillError.invalidSkill }
        let destination = global.appendingPathComponent(proposal.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            let version = global.appendingPathComponent(".versions/\(proposal.name)/\(versionStamp())", isDirectory: true)
            try FileManager.default.createDirectory(at: version.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: destination, to: version)
        }
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: proposal.directory, to: destination)
    }

    /// Sortable and unique even for several saves within one second.
    static func versionStamp() -> String {
        ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-") +
            "-" + String(UUID().uuidString.prefix(6))
    }

    /// Restores the newest saved version of a skill (the current one is versioned too).
    public static func rollback(name: String, global: URL? = globalDirectory) throws {
        guard let global, isValidName(name) else { throw SkillError.invalidSkill }
        let versions = global.appendingPathComponent(".versions/\(name)", isDirectory: true)
        guard let latest = try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else { throw SkillError.noVersion }
        let current = global.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.moveItem(at: current, to: versions.appendingPathComponent("\(versionStamp())-replaced"))
        }
        try FileManager.default.moveItem(at: latest, to: current)
    }

    /// Saved earlier versions of a global skill, newest first.
    public static func versions(name: String, global: URL? = globalDirectory) -> [String] {
        guard let global, isValidName(name),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: global.appendingPathComponent(".versions/\(name)").path)
        else { return [] }
        return entries.filter { !$0.hasPrefix(".") }.sorted(by: >)
    }

    /// Declines a proposal by moving it to the Trash (recoverable).
    public static func reject(proposal: Skill) throws {
        guard proposal.source == .proposal else { throw SkillError.invalidSkill }
        try FileManager.default.trashItem(at: proposal.directory, resultingItemURL: nil)
    }

    /// Copies a folder of skills (e.g. `~/.claude/skills`) into AIM's global folder.
    /// Existing names are skipped; returns the imported names.
    public static func importSkills(from source: URL, names: Set<String>? = nil, global: URL? = globalDirectory) throws -> [String] {
        guard let global else { throw SkillError.invalidSkill }
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        var imported: [String] = []
        for skill in scan(source, source: .global) where names?.contains(skill.name) ?? true {
            let destination = global.appendingPathComponent(skill.name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.copyItem(at: skill.directory, to: destination)
            imported.append(skill.name)
        }
        return imported
    }
}

/// Skills the person turned off in Settings → Skills (by name).
public enum SkillPreferences {
    static let disabledKey = "AIMDisabledSkills"

    public static var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: disabledKey) }
    }
}

public enum SkillError: LocalizedError {
    case invalidPath, notText, invalidSkill, noVersion, unknownSkill(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Use a relative path inside the skill folder (no symbolic links)."
        case .notText: "That skill file is not UTF-8 text."
        case .invalidSkill: "A skill needs a name (letters, digits, - or _, up to 64) and a one-line description."
        case .noVersion: "There is no earlier version of this skill to restore."
        case .unknownSkill(let name): "No enabled skill is named \(name)."
        }
    }
}
