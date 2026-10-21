import Foundation

public struct NativeStoreSkill: Codable, Equatable, Sendable, Identifiable {
    public var source: String
    public var skillId: String
    public var name: String
    public var installs: Int?
    public var id: String { source + "/" + skillId }
    public init(source: String, skillId: String, name: String, installs: Int? = nil) { self.source = source; self.skillId = skillId; self.name = name; self.installs = installs }
}

/// Same public sources and folder lookup as Mac CustomizeStore; no Mac dependencies.
public actor NativeSkillCatalogService {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private let cache: URL
    public init(cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SkillCatalog"), fetch: @escaping Fetch = defaultFetch) { self.cache = cache; self.fetch = fetch }
    public static let defaultFetch: Fetch = { url in
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard url.scheme == "https", ["skills.sh", "api.github.com", "raw.githubusercontent.com"].contains(url.host) else { throw NativeSkillError.invalidPath }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AIM-AI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await NativeChatTransport.secretSession().data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw NativeSkillError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard data.count <= 10 * 1024 * 1024 else { throw NativeSkillError.tooLarge }
        return data
    }
    public func cached(page: Int = 0) -> [NativeStoreSkill] {
        guard let data = try? Data(contentsOf: cache.appendingPathComponent("page-\(page).json")) else { return [] }
        return (try? Self.decode(data)) ?? []
    }
    public static func decode(_ data: Data) throws -> [NativeStoreSkill] {
        struct Page: Decodable { let skills: [NativeStoreSkill] }
        var seen = Set<String>()
        return try JSONDecoder().decode(Page.self, from: data).skills.filter {
            validRepository($0.source) && NativeSkillRules.validName($0.skillId) && seen.insert($0.id).inserted
        }
    }
    public func catalog(page: Int = 0, query: String = "") async throws -> [NativeStoreSkill] {
        var url = URLComponents(string: query.isEmpty ? "https://skills.sh/api/skills/all-time/\(max(0, page))" : "https://skills.sh/api/search")!
        if !query.isEmpty { url.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: "60")] }
        let data = try await fetch(url.url!)
        let rows = try Self.decode(data)
        if query.isEmpty {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try data.write(to: cache.appendingPathComponent("page-\(page).json"), options: .atomic)
        }
        return rows
    }
    public func preview(_ skill: NativeStoreSkill) async throws -> NativeSkill {
        guard Self.validRepository(skill.source), NativeSkillRules.validName(skill.skillId) else { throw NativeSkillError.invalidSkill }
        var folder: String?
        var markdown: String?
        for candidate in ["skills/\(skill.skillId)", skill.skillId, ".claude/skills/\(skill.skillId)", "skills/.curated/\(skill.skillId)", "plugins/\(skill.skillId)/skills/\(skill.skillId)"] {
            if let data = try? await fetch(URL(string: "https://raw.githubusercontent.com/\(skill.source)/HEAD/\(candidate)/SKILL.md")!), let text = String(data: data, encoding: .utf8), NativeSkillRules.parse(text) != nil {
                folder = candidate; markdown = text; break
            }
        }
        struct Tree: Decodable { struct Entry: Decodable { var path: String; var type: String; var mode: String? }; var tree: [Entry]; var truncated: Bool? }
        let tree = try JSONDecoder().decode(Tree.self, from: await fetch(URL(string: "https://api.github.com/repos/\(skill.source)/git/trees/HEAD?recursive=1")!))
        guard tree.truncated != true else { throw NativeSkillError.tooLarge }
        if folder == nil, let path = tree.tree.filter({ $0.type == "blob" && $0.path.hasSuffix("/\(skill.skillId)/SKILL.md") }).map(\.path).min(by: { $0.count < $1.count }) {
            folder = String(path.dropLast("/SKILL.md".count))
            let data = try await fetch(URL(string: "https://raw.githubusercontent.com/\(skill.source)/HEAD/\(path)")!)
            markdown = String(data: data, encoding: .utf8)
        }
        guard let folder, let markdown, let parsed = NativeSkillRules.parse(markdown) else { throw NativeSkillError.invalidSkill }
        let entries = tree.tree.filter { $0.type == "blob" && $0.mode != "120000" && $0.path.hasPrefix(folder + "/") }
        guard entries.count <= 200 else { throw NativeSkillError.tooLarge }
        var files: [String: String] = ["SKILL.md": markdown]
        var bytes = markdown.utf8.count
        for entry in entries {
            let relative = String(entry.path.dropFirst(folder.count + 1))
            guard relative != "SKILL.md", NativeSkillRules.safePath(relative) else { continue }
            let data = try await fetch(URL(string: "https://raw.githubusercontent.com/\(skill.source)/HEAD/\(entry.path)")!)
            bytes += data.count; guard bytes <= 10 * 1024 * 1024 else { throw NativeSkillError.tooLarge }
            if let text = String(data: data, encoding: .utf8) { files[relative] = text }
        }
        return try NativeSkill(name: parsed.name, summary: parsed.summary, origin: "store:\(skill.id)", files: files, modelInvocable: parsed.modelInvocable)
    }
    private static func validRepository(_ source: String) -> Bool {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }
}
