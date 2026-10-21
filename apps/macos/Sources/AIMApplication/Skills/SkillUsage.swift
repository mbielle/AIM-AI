import Foundation

/// How often each skill is actually used (`skill_view`), kept beside the
/// skills as `.usage.json`. It orders the catalog, shows provenance and
/// usage in Settings and lets unused learned skills retire to `.archive`.
public enum SkillUsage {
    public struct Record: Codable, Equatable, Sendable {
        public var uses: Int
        public var lastUsed: Date?
        public var firstSeen: Date
    }

    private static let lock = NSLock()

    static func file(_ global: URL?) -> URL? { global?.appendingPathComponent(".usage.json") }
    static func archiveDirectory(_ global: URL?) -> URL? { global?.appendingPathComponent(".archive", isDirectory: true) }

    public static func records(global: URL? = SkillCatalog.globalDirectory) -> [String: Record] {
        guard let url = file(global), let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private static func write(_ records: [String: Record], global: URL?) {
        guard let url = file(global) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: url, options: .atomic)
    }

    public static func recordUse(_ name: String, at date: Date = .now, global: URL? = SkillCatalog.globalDirectory) {
        lock.withLock {
            var all = records(global: global)
            var record = all[name] ?? Record(uses: 0, lastUsed: nil, firstSeen: date)
            record.uses += 1
            record.lastUsed = date
            all[name] = record
            write(all, global: global)
        }
    }

    /// Notes first sight of skills so a never-used skill ages from install, not forever.
    public static func noteSeen(_ names: [String], at date: Date = .now, global: URL? = SkillCatalog.globalDirectory) {
        lock.withLock {
            var all = records(global: global)
            var changed = false
            for name in names where all[name] == nil {
                all[name] = Record(uses: 0, lastUsed: nil, firstSeen: date)
                changed = true
            }
            if changed { write(all, global: global) }
        }
    }

    /// Most used first, then by name; keeps the bounded catalog useful.
    public static func ordered(_ skills: [Skill], global: URL? = SkillCatalog.globalDirectory) -> [Skill] {
        let usage = records(global: global)
        return skills.sorted {
            let (a, b) = (usage[$0.name]?.uses ?? 0, usage[$1.name]?.uses ?? 0)
            return a != b ? a > b : $0.name < $1.name
        }
    }

    /// Moves global skills the learning loop wrote (`aim-origin: learned`) that went
    /// unused for `days` into `.archive` (restorable). Person-written skills stay.
    @discardableResult
    public static func archiveStale(olderThan days: Int = 60, now: Date = .now,
                                    global: URL? = SkillCatalog.globalDirectory) throws -> [String] {
        guard let global, let archive = archiveDirectory(global) else { return [] }
        let usage = records(global: global)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var archived: [String] = []
        for skill in SkillCatalog.scan(global, source: .global) where skill.origin == "learned" {
            guard let record = usage[skill.name], (record.lastUsed ?? record.firstSeen) < cutoff else { continue }
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let destination = archive.appendingPathComponent("\(skill.name)-\(SkillCatalog.versionStamp())", isDirectory: true)
            try FileManager.default.moveItem(at: skill.directory, to: destination)
            archived.append(skill.name)
        }
        return archived
    }

    /// Archived skills, newest first, as (folder name, skill name).
    public static func archived(global: URL? = SkillCatalog.globalDirectory) -> [(folder: String, name: String)] {
        guard let archive = archiveDirectory(global) else { return [] }
        return SkillCatalog.scan(archive, source: .global).map { ($0.directory.lastPathComponent, $0.name) }
            .sorted { $0.folder > $1.folder }
    }

    public static func restore(folder: String, global: URL? = SkillCatalog.globalDirectory) throws {
        guard let global, let archive = archiveDirectory(global), !folder.contains("/"), !folder.hasPrefix("."),
              let skill = SkillCatalog.load(archive.appendingPathComponent(folder, isDirectory: true), source: .global) else {
            throw SkillError.invalidSkill
        }
        let destination = global.appendingPathComponent(skill.name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SkillError.invalidSkill }
        try FileManager.default.moveItem(at: skill.directory, to: destination)
        noteSeen([skill.name], global: global)
        lock.withLock {
            var all = records(global: global)
            all[skill.name]?.firstSeen = .now
            all[skill.name]?.lastUsed = nil
            write(all, global: global)
        }
    }
}
