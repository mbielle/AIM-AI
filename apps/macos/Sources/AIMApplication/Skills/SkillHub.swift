import AIMCore
import Foundation

/// Installs skills from a GitHub repository (the de-facto skill hub: Anthropic's,
/// OpenClaw's and community skill repos all use SKILL.md folders). Downloads
/// land as proposals with their provenance (`aim-origin: hub:…`) and stay
/// inactive until the person accepts them, since their text is third-party.
public enum SkillHub {
    public struct Source: Equatable, Sendable {
        public let owner: String
        public let repo: String
        public let path: String
        public let ref: String?

        public var provenance: String { "hub:github.com/\(owner)/\(repo)\(path.isEmpty ? "" : "/" + path)\(ref.map { "@" + $0 } ?? "")" }
    }

    public typealias Fetch = @Sendable (URL) async throws -> Data

    static let maximumSkills = 20
    static let maximumFiles = 40
    static let maximumBytes = 1_024 * 1_024

    /// `owner/repo[/path][@ref]`, `github:owner/repo/…` or a github.com tree/blob URL.
    public static func parse(_ text: String) -> Source? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("github:") { value = String(value.dropFirst(7)) }
        var ref: String?
        if let url = URL(string: value), url.host == "github.com" {
            var parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            let owner = parts.removeFirst(), repo = parts.removeFirst()
            if parts.count >= 2, ["tree", "blob"].contains(parts[0]) {
                ref = parts[1]
                parts.removeFirst(2)
            }
            if parts.last == "SKILL.md" { parts.removeLast() }
            return make(owner, repo, parts.joined(separator: "/"), ref)
        }
        if let at = value.lastIndex(of: "@") {
            ref = String(value[value.index(after: at)...])
            value = String(value[..<at])
        }
        var parts = value.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts.removeFirst(), repo = parts.removeFirst()
        if parts.last == "SKILL.md" { parts.removeLast() }
        return make(owner, repo, parts.joined(separator: "/"), ref)
    }

    private static func make(_ owner: String, _ repo: String, _ path: String, _ ref: String?) -> Source? {
        let safe = { (s: String) in !s.isEmpty && s.count <= 100 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && s != ".." }
        guard safe(owner), safe(repo), path.split(separator: "/").allSatisfy({ safe(String($0)) }),
              ref.map(safe) ?? true else { return nil }
        return Source(owner: owner, repo: repo, path: path, ref: ref)
    }

    struct Entry: Decodable { let type: String; let name: String; let path: String; let size: Int?; let download_url: String? }

    static func contentsURL(_ source: Source, path: String) -> URL? {
        var components = URLComponents(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)/contents/\(path)")
        if let ref = source.ref { components?.queryItems = [URLQueryItem(name: "ref", value: ref)] }
        return components?.url
    }

    /// Downloads every skill at the source (one folder, or its SKILL.md subfolders)
    /// into proposals. Returns the proposed names.
    public static func install(_ source: Source, fetch: @escaping Fetch = defaultFetch,
                               global: URL? = SkillCatalog.globalDirectory) async throws -> [String] {
        guard let proposals = global?.appendingPathComponent(".proposals", isDirectory: true) else { throw SkillError.invalidSkill }
        let top = try await list(source, path: source.path, fetch: fetch)
        var folders: [String] = []
        if top.contains(where: { $0.type == "file" && $0.name == "SKILL.md" }) {
            folders = [source.path]
        } else {
            for entry in top where entry.type == "dir" && folders.count < maximumSkills {
                if let inner = try? await list(source, path: entry.path, fetch: fetch),
                   inner.contains(where: { $0.type == "file" && $0.name == "SKILL.md" }) {
                    folders.append(entry.path)
                }
            }
        }
        guard !folders.isEmpty else { throw SkillHubError.noSkill }
        var installed: [String] = []
        var budget = maximumBytes
        for folder in folders {
            var files: [(relative: String, data: Data)] = []
            try await collect(source, folder: folder, relative: "", depth: 0, fetch: fetch, files: &files, budget: &budget)
            guard let skillFile = files.first(where: { $0.relative == "SKILL.md" }),
                  let text = String(data: skillFile.data, encoding: .utf8),
                  let parsed = SkillCatalog.parse(text) else { continue }
            let destination = proposals.appendingPathComponent(parsed.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            for file in files {
                let url = destination.appendingPathComponent(file.relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = file.relative == "SKILL.md" ? Data(withProvenance(text, origin: Source(owner: source.owner, repo: source.repo, path: folder, ref: source.ref).provenance).utf8) : file.data
                try data.write(to: url, options: .atomic)
            }
            installed.append(parsed.name)
        }
        guard !installed.isEmpty else { throw SkillHubError.noSkill }
        return installed
    }

    private static func list(_ source: Source, path: String, fetch: Fetch) async throws -> [Entry] {
        guard let url = contentsURL(source, path: path) else { throw SkillHubError.noSkill }
        let data = try await fetch(url)
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        if let entry = try? JSONDecoder().decode(Entry.self, from: data) { return [entry] }
        throw SkillHubError.noSkill
    }

    private static func collect(_ source: Source, folder: String, relative: String, depth: Int, fetch: Fetch,
                                files: inout [(relative: String, data: Data)], budget: inout Int) async throws {
        for entry in try await list(source, path: relative.isEmpty ? folder : folder + "/" + relative, fetch: fetch) {
            let child = relative.isEmpty ? entry.name : relative + "/" + entry.name
            guard !entry.name.hasPrefix("."), entry.name != "..", !entry.name.contains("/") else { continue }
            if entry.type == "dir", depth < 3 {
                try await collect(source, folder: folder, relative: child, depth: depth + 1, fetch: fetch, files: &files, budget: &budget)
            } else if entry.type == "file", files.count < maximumFiles, let raw = entry.download_url,
                      let url = URL(string: raw), url.scheme == "https", (entry.size ?? 0) <= budget {
                let data = try await fetch(url)
                guard data.count <= budget else { throw SkillHubError.tooLarge }
                budget -= data.count
                files.append((child, data))
            }
        }
    }

    /// Sets `aim-origin` in the frontmatter (replacing any value the author wrote).
    static func withProvenance(_ text: String, origin: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let end = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            return text
        }
        let header = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.lowercased().hasPrefix("aim-origin:") }
            .joined(separator: "\n")
        return "---\n" + header + "\naim-origin: " + origin + String(normalized[end.lowerBound...])
    }

    public static let defaultFetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIM-AI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await RuntimeManagedNetworkSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw SkillHubError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

public enum SkillHubError: LocalizedError, Equatable {
    case noSkill, tooLarge, http(Int)
    public var errorDescription: String? {
        switch self {
        case .noSkill: "No SKILL.md folder was found at that GitHub location."
        case .tooLarge: "The skill files exceed 1 MB."
        case .http(let status): "GitHub answered HTTP \(status)."
        }
    }
}
