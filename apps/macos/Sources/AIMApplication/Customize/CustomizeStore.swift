import AIMCore
import Foundation

// The Customize store: skills, connectors and plugins from public sources, read without any
// key. Skills: skills.sh's public leaderboard and search (install counts), files from GitHub.
// Plugins: the official Claude plugin marketplaces. Connectors: AIM's selection + the official
// MCP registry (remote servers only). Nothing here runs code: installing copies files.

public struct StoreSkill: Codable, Equatable, Sendable, Identifiable, Hashable {
    /// "owner/repo/skill".
    public var id: String { source + "/" + skillId }
    public let source: String
    public let skillId: String
    public let name: String
    public let installs: Int?
    public var description: String?
    /// Installs per week, oldest first (skills.sh), for the trend chart.
    public var weeklyInstalls: [Int]?

    public init(source: String, skillId: String, name: String, installs: Int? = nil, description: String? = nil, weeklyInstalls: [Int]? = nil) {
        self.source = source; self.skillId = skillId; self.name = name; self.installs = installs; self.description = description
        self.weeklyInstalls = weeklyInstalls
    }

    public var owner: String { String(source.split(separator: "/").first ?? Substring(source)) }
    public var isOfficial: Bool { ["anthropics", "openai", "vercel-labs", "github", "google", "microsoft"].contains(owner.lowercased()) }
}

public struct StorePlugin: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String { marketplace + ":" + name }
    public let name: String
    public let displayName: String?
    public let description: String
    public let category: String?
    public let author: String?
    public let marketplace: String
    /// Where its files are: a GitHub repository and a folder inside it.
    public let repository: String
    public let path: String
    public let ref: String?
    public let homepage: String?

    public var title: String { displayName ?? name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
}

public typealias StoreConnector = PortableConnector

public enum StoreError: LocalizedError, Equatable {
    case unreachable, notFound, tooLarge, invalidSkill, rateLimited
    public var errorDescription: String? {
        switch self {
        case .unreachable: "The store could not be reached. Check the connection and try again."
        case .notFound: "This item's files could not be found in its repository."
        case .tooLarge: "This item is larger than AIM accepts from the store (10 MB, 200 files)."
        case .invalidSkill: "The downloaded folder is not a valid skill (SKILL.md with a name and a description)."
        case .rateLimited: "GitHub limits anonymous downloads for a while. Try again in a few minutes."
        }
    }
}

/// Network reads with a one-day disk cache, so the store opens instantly and works offline.
public actor CustomizeStore {
    public static let shared = CustomizeStore()

    public enum Ranking: String, Sendable { case allTime = "all-time", trending, hot }

    private let session: URLSession
    private let cache: URL
    private var descriptions: [String: String] = [:]
    private var markdowns: [String: (text: String, folder: String)] = [:]

    public init(session: URLSession = RuntimeManagedNetworkSession.shared,
                cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: AIMInstallationContext.legacyDirectoryName + "/Store")) {
        self.session = session
        self.cache = cache
    }

    // MARK: Skills

    struct SkillsPage: Decodable {
        struct Item: Decodable { let source: String; let skillId: String; let name: String; let installs: Int?; let weeklyInstalls: [Int]? }
        let skills: [Item]
    }

    /// The most installed skills (skills.sh), page by page (50 each).
    public func skills(_ ranking: Ranking = .allTime, page: Int = 0) async throws -> [StoreSkill] {
        let data = try await get("https://skills.sh/api/skills/\(ranking.rawValue)/\(page)", cacheKey: "skills-\(ranking.rawValue)-\(page)")
        return try Self.decodeSkills(data)
    }

    public func searchSkills(_ query: String) async throws -> [StoreSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let data = try await get("https://skills.sh/api/search?q=\(encoded)&limit=60", cacheKey: nil)
        return try Self.decodeSkills(data)
    }

    public static func decodeSkills(_ data: Data) throws -> [StoreSkill] {
        let page = try JSONDecoder().decode(SkillsPage.self, from: data)
        var seen = Set<String>()
        return page.skills.compactMap { item in
            // skills.sh lists the newest week first.
            let skill = StoreSkill(source: item.source, skillId: item.skillId, name: item.name, installs: item.installs,
                                   weeklyInstalls: item.weeklyInstalls.map { Array($0.reversed()) })
            // A source must be a GitHub "owner/repo" to be installable.
            guard item.source.split(separator: "/").count == 2, SkillCatalog.isValidName(item.skillId) || !item.skillId.isEmpty,
                  seen.insert(skill.id).inserted else { return nil }
            return skill
        }
    }

    /// The skill's SKILL.md from GitHub (found where repositories usually keep it).
    public func skillMarkdown(_ skill: StoreSkill) async throws -> (text: String, folder: String) {
        if let known = markdowns[skill.id] { return known }
        let found = try await findSkillMarkdown(skill)
        markdowns[skill.id] = found
        return found
    }

    /// Loads a skill page's data in advance (on hover), so it opens complete.
    public func prefetch(_ skill: StoreSkill) async {
        guard markdowns[skill.id] == nil else { return }
        _ = try? await skillMarkdown(skill)
        _ = await repositoryFacts(skill.source)
        _ = await skillFiles(skill)
    }

    private func findSkillMarkdown(_ skill: StoreSkill) async throws -> (text: String, folder: String) {
        for folder in ["skills/\(skill.skillId)", skill.skillId, ".claude/skills/\(skill.skillId)", "skills/.curated/\(skill.skillId)",
                       "plugins/\(skill.skillId)/skills/\(skill.skillId)"] {
            if let data = try? await get("https://raw.githubusercontent.com/\(skill.source)/HEAD/\(folder)/SKILL.md", cacheKey: nil, quiet: true),
               let text = String(data: data, encoding: .utf8), SkillCatalog.parse(text) != nil {
                return (text, folder)
            }
        }
        // Elsewhere in the repository: one tree listing to find it.
        let tree = try await tree(skill.source)
        let candidates = tree.filter { $0.hasSuffix("/\(skill.skillId)/SKILL.md") || $0 == "\(skill.skillId)/SKILL.md" }
        guard let path = candidates.min(by: { $0.count < $1.count }),
              let data = try? await get("https://raw.githubusercontent.com/\(skill.source)/HEAD/\(path)", cacheKey: nil),
              let text = String(data: data, encoding: .utf8) else { throw StoreError.notFound }
        return (text, String(path.dropLast("/SKILL.md".count)))
    }

    /// A one-line description for cards (from SKILL.md's front matter), cached.
    public func description(_ skill: StoreSkill) async -> String? {
        if let known = descriptions[skill.id] { return known }
        let key = "desc-" + skill.id.replacingOccurrences(of: "/", with: "_")
        if let data = cached(key, maxAge: 7 * 86_400), let text = String(data: data, encoding: .utf8) {
            descriptions[skill.id] = text
            return text
        }
        guard let markdown = try? await skillMarkdown(skill), let parsed = SkillCatalog.parse(markdown.text) else { return nil }
        descriptions[skill.id] = parsed.description
        store(Data(parsed.description.utf8), key: key)
        return parsed.description
    }

    /// Copies a skill's whole folder (SKILL.md, scripts, references) into AIM's skills folder.
    @discardableResult
    public func install(_ skill: StoreSkill, into global: URL? = SkillCatalog.globalDirectory) async throws -> URL {
        let markdown = try await skillMarkdown(skill)
        guard let parsed = SkillCatalog.parse(markdown.text) else { throw StoreError.invalidSkill }
        return try await installFolder(repository: skill.source, folder: markdown.folder, name: parsed.name,
                                       origin: "store:\(skill.id)", into: global)
    }

    func installFolder(repository: String, folder: String, name: String, origin: String, ref: String = "HEAD",
                       into global: URL?) async throws -> URL {
        guard let global, SkillCatalog.isValidName(name) else { throw StoreError.invalidSkill }
        let files = try await tree(repository, ref: ref).filter { $0.hasPrefix(folder + "/") }
        guard files.count <= 200 else { throw StoreError.tooLarge }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("aim-skill-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var total = 0
        for path in files {
            let relative = String(path.dropFirst(folder.count + 1))
            guard !relative.contains(".."), !relative.hasPrefix("/") else { continue }
            let data = try await get("https://raw.githubusercontent.com/\(repository)/\(ref)/\(path)", cacheKey: nil)
            total += data.count
            guard total <= 10 * 1_024 * 1_024 else { throw StoreError.tooLarge }
            let target = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        // Mark where it came from (shown in Customize › Yours).
        let skillFile = staging.appendingPathComponent("SKILL.md")
        guard var text = try? String(contentsOf: skillFile, encoding: .utf8), SkillCatalog.parse(text) != nil else { throw StoreError.invalidSkill }
        if !text.contains("aim-origin:"), text.hasPrefix("---") {
            text = "---\naim-origin: \(origin)" + text.dropFirst(3)
            try text.write(to: skillFile, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        let destination = global.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    /// A GitHub repository's public facts (stars, licence, last update), cached a day.
    public struct RepositoryFacts: Sendable, Equatable {
        public let stars: Int
        public let forks: Int
        public let license: String?
        public let pushedAt: Date?
        public let description: String?
        public let topics: [String]
    }

    public func repositoryFacts(_ repository: String) async -> RepositoryFacts? {
        guard let data = try? await get("https://api.github.com/repos/\(repository)", cacheKey: "repo-" + repository.replacingOccurrences(of: "/", with: "_")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let license = (json["license"] as? [String: Any])?["spdx_id"] as? String
        return RepositoryFacts(stars: json["stargazers_count"] as? Int ?? 0, forks: json["forks_count"] as? Int ?? 0,
                               license: license == "NOASSERTION" ? nil : license,
                               pushedAt: (json["pushed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                               description: json["description"] as? String, topics: json["topics"] as? [String] ?? [])
    }

    /// The files of a skill's folder (relative paths), from the repository listing.
    public func skillFiles(_ skill: StoreSkill) async -> [String] {
        guard let folder = try? await skillMarkdown(skill).folder, let tree = try? await tree(skill.source) else { return [] }
        return tree.filter { $0.hasPrefix(folder + "/") }.map { String($0.dropFirst(folder.count + 1)) }
    }

    // MARK: Plugins

    /// Knowledge-work plugins (productivity, design, marketing…) first, then the developer directory.
    public static let marketplaces = ["anthropics/knowledge-work-plugins", "anthropics/claude-plugins-official"]

    public func plugins() async throws -> [StorePlugin] {
        var all: [StorePlugin] = []
        for repository in Self.marketplaces {
            guard let data = try? await get("https://raw.githubusercontent.com/\(repository)/HEAD/.claude-plugin/marketplace.json",
                                             cacheKey: "marketplace-" + repository.replacingOccurrences(of: "/", with: "_")) else { continue }
            all += Self.decodeMarketplace(data, repository: repository)
        }
        guard !all.isEmpty else { throw StoreError.unreachable }
        return all
    }

    public static func decodeMarketplace(_ data: Data, repository: String) -> [StorePlugin] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [[String: Any]] else { return [] }
        let marketplace = json["name"] as? String ?? repository
        return plugins.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            var sourceRepository = repository, path = "", ref: String?
            if let local = item["source"] as? String {
                path = local.hasPrefix("./") ? String(local.dropFirst(2)) : local
            } else if let source = item["source"] as? [String: Any], let url = source["url"] as? String,
                      let parsed = githubRepository(url) {
                sourceRepository = parsed
                path = source["path"] as? String ?? ""
                ref = source["sha"] as? String ?? source["ref"] as? String
            } else { return nil }
            let author = (item["author"] as? [String: Any])?["name"] as? String
            return StorePlugin(name: name, displayName: item["displayName"] as? String,
                               description: item["description"] as? String ?? "", category: item["category"] as? String,
                               author: author, marketplace: marketplace, repository: sourceRepository, path: path,
                               ref: ref, homepage: item["homepage"] as? String)
        }
    }

    static func githubRepository(_ url: String) -> String? {
        guard let parsed = URL(string: url), parsed.host?.contains("github.com") == true else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
    }

    /// What a plugin brings: its skills (folder paths) and its remote MCP servers.
    public struct PluginContents: Sendable {
        public var skillFolders: [String]
        public var servers: [(name: String, url: String, transport: String)]
        public var ignored: [String]
    }

    public func contents(_ plugin: StorePlugin) async throws -> PluginContents {
        let ref = plugin.ref ?? "HEAD"
        let root = plugin.path.isEmpty ? "" : plugin.path + "/"
        let files = try await tree(plugin.repository, ref: ref).filter { root.isEmpty || $0.hasPrefix(root) }
        let skillFolders = files.filter { $0.hasSuffix("/SKILL.md") && $0.hasPrefix(root + "skills/") }
            .map { String($0.dropLast("/SKILL.md".count)) }
        var servers: [(String, String, String)] = []
        if files.contains(root + ".mcp.json"),
           let data = try? await get("https://raw.githubusercontent.com/\(plugin.repository)/\(ref)/\(root).mcp.json", cacheKey: nil),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = json["mcpServers"] as? [String: Any] { json = nested }
            for (name, value) in json {
                guard let server = value as? [String: Any], let url = server["url"] as? String else { continue }
                servers.append((name, url, server["type"] as? String ?? "http"))
            }
        }
        var ignored: [String] = []
        if files.contains(where: { $0.hasPrefix(root + "commands/") }) { ignored.append("slash commands") }
        if files.contains(where: { $0.hasPrefix(root + "agents/") }) { ignored.append("sub-agents") }
        if files.contains(where: { $0.hasPrefix(root + "hooks/") }) { ignored.append("hooks") }
        return PluginContents(skillFolders: skillFolders, servers: servers, ignored: ignored)
    }

    /// Installs a plugin's skills (named `plugin-skill` when needed to stay unique).
    public func installSkills(of plugin: StorePlugin, contents: PluginContents, into global: URL? = SkillCatalog.globalDirectory) async throws -> [String] {
        var installed: [String] = []
        for folder in contents.skillFolders.prefix(30) {
            let base = String(folder.split(separator: "/").last ?? "")
            guard let data = try? await get("https://raw.githubusercontent.com/\(plugin.repository)/\(plugin.ref ?? "HEAD")/\(folder)/SKILL.md", cacheKey: nil),
                  let text = String(data: data, encoding: .utf8), let parsed = SkillCatalog.parse(text) else { continue }
            let name = SkillCatalog.isValidName(parsed.name) ? parsed.name : base
            _ = try await installFolder(repository: plugin.repository, folder: folder, name: name,
                                        origin: "plugin:\(plugin.id)", ref: plugin.ref ?? "HEAD", into: global)
            installed.append(name)
        }
        return installed
    }

    // MARK: Connectors (official MCP registry)

    public func searchRegistry(_ query: String, cursor: String? = nil) async throws -> (connectors: [StoreConnector], next: String?) {
        var url = "https://registry.modelcontextprotocol.io/v0/servers?limit=50"
        if !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { url += "&search=\(encoded)" }
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { url += "&cursor=\(encoded)" }
        let data = try await get(url, cacheKey: nil)
        return Self.decodeRegistry(data)
    }

    public static func decodeRegistry(_ data: Data) -> (connectors: [StoreConnector], next: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let servers = json["servers"] as? [[String: Any]] ?? []
        let connectors: [StoreConnector] = servers.compactMap { entry in
            guard let server = entry["server"] as? [String: Any], let name = server["name"] as? String,
                  let remote = (server["remotes"] as? [[String: Any]])?.first(where: { ($0["type"] as? String) != "stdio" }),
                  let url = remote["url"] as? String, !url.contains("{") else { return nil }
            let needsToken = (remote["headers"] as? [[String: Any]])?.contains { $0["isRequired"] as? Bool == true } == true
            let title = server["title"] as? String ?? String(name.split(separator: "/").last ?? Substring(name))
            return StoreConnector(id: "registry:" + name, name: title, description: server["description"] as? String ?? "",
                                  url: url, category: "Registry", publisher: String(name.split(separator: "/").first ?? ""),
                                  auth: needsToken ? .token : .oauth)
        }
        let next = (json["metadata"] as? [String: Any])?["nextCursor"] as? String
        return (connectors, next)
    }

    // MARK: Network

    /// Paths of a GitHub repository (one API call, cached a day).
    private func tree(_ repository: String, ref: String = "HEAD") async throws -> [String] {
        let key = "tree-" + repository.replacingOccurrences(of: "/", with: "_") + "-" + ref
        let data: Data
        do { data = try await get("https://api.github.com/repos/\(repository)/git/trees/\(ref)?recursive=1", cacheKey: key) }
        catch StoreError.rateLimited { throw StoreError.rateLimited }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["tree"] as? [[String: Any]] else { throw StoreError.notFound }
        return items.compactMap { $0["type"] as? String == "blob" ? $0["path"] as? String : nil }
    }

    private func get(_ address: String, cacheKey: String?, quiet: Bool = false) async throws -> Data {
        if let cacheKey, let data = cached(cacheKey, maxAge: 86_400) { return data }
        guard let url = URL(string: address) else { throw StoreError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("AIM-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch {
            if let cacheKey, let stale = cached(cacheKey, maxAge: .infinity) { return stale }
            throw StoreError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 429 { throw StoreError.rateLimited }
        guard status == 200 else { throw status == 404 ? StoreError.notFound : StoreError.unreachable }
        if let cacheKey { store(data, key: cacheKey) }
        return data
    }

    private func cached(_ key: String, maxAge: TimeInterval) -> Data? {
        let file = cache.appendingPathComponent(key)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date.now.timeIntervalSince(date) < maxAge else { return nil }
        return try? Data(contentsOf: file)
    }

    private func store(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: cache.appendingPathComponent(key), options: .atomic)
    }
}
