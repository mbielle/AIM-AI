import Foundation

/// Read-only discovery. A registry listing never proves that an action is safe.
public enum ConnectorRegistry {
    public struct Page: Sendable, Equatable {
        public var connectors: [PortableConnector]
        public var nextCursor: String?
        public init(connectors: [PortableConnector], nextCursor: String? = nil) {
            self.connectors = connectors; self.nextCursor = nextCursor
        }
    }

    public static func requestURL(query: String, cursor: String? = nil) -> URL {
        var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0/servers")!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        if !query.isEmpty { components.queryItems?.append(.init(name: "search", value: query)) }
        if let cursor { components.queryItems?.append(.init(name: "cursor", value: cursor)) }
        return components.url!
    }

    public static func decode(_ data: Data) throws -> Page {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["servers"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        let entries = servers.compactMap { entry -> PortableConnector? in
            guard let server = entry["server"] as? [String: Any], let name = server["name"] as? String,
                  let remotes = server["remotes"] as? [[String: Any]],
                  let remote = remotes.first(where: { $0["type"] as? String == "streamable-http" }) ?? remotes.first(where: { $0["type"] as? String == "sse" }), let rawURL = remote["url"] as? String, !rawURL.contains("{"),
                  let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            let requiredToken = (remote["headers"] as? [[String: Any]])?.contains { $0["isRequired"] as? Bool == true } == true
            let icon = (server["icons"] as? [[String: Any]])?.compactMap { $0["src"] as? String }.first { URL(string: $0)?.scheme == "https" }
            return PortableConnector(id: "registry:" + name,
                name: server["title"] as? String ?? String(name.split(separator: "/").last ?? Substring(name)),
                description: server["description"] as? String ?? "", url: rawURL, logo: icon,
                category: "MCP registry", publisher: String(name.split(separator: "/").first ?? ""),
                auth: requiredToken ? .token : .oauth, transport: remote["type"] as? String)
        }
        return Page(connectors: merged(curated: [], discovered: entries),
                    nextCursor: (json["metadata"] as? [String: Any])?["nextCursor"] as? String)
    }

    /// Keep curated identities/permission mappings when the registry repeats an endpoint.
    public static func merged(curated: [PortableConnector], discovered: [PortableConnector]) -> [PortableConnector] {
        var ids = Set<String>(), endpoints = Set<String>()
        return (curated + discovered).filter { item in
            guard ids.insert(item.id).inserted else { return false }
            guard let raw = item.url, var url = URLComponents(string: raw) else { return true }
            url.host = url.host?.lowercased(); url.fragment = nil
            let key = (url.string ?? raw).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return endpoints.insert(key).inserted
        }
    }
}
