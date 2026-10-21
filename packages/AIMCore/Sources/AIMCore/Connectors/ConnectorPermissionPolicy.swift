import Foundation

/// Evidence is AIM's versioned reviewed catalogue, never a remote annotation or a tool-name prefix.
/// Unknown endpoints, local processes and newly advertised tools always require an exact confirmation.
public enum ConnectorPermissionPolicy {
    public enum Decision: String, Codable, CaseIterable, Sendable { case ask, block }
    public enum Effect: String, Codable, Sendable { case verifiedRead, modification, send, unknown }
    public enum Authorization: String, Sendable { case allow, confirm, deny }
    public struct Assessment: Equatable, Sendable {
        public let effect: Effect
        public let authorization: Authorization
        public init(effect: Effect, authorization: Authorization) { self.effect = effect; self.authorization = authorization }
        public var label: String {
            switch authorization { case .deny: "Blocked"; case .confirm: "Confirm"; case .allow: "Read" }
        }
    }

    public static func assess(endpoint: String, action: String, arguments: RemoteJSONValue? = nil,
                              exception: Decision? = nil, serverClaimsReadOnly: Bool? = nil) -> Assessment {
        // serverClaimsReadOnly is descriptive data only, deliberately excluded from authorization.
        let effect = reviewedEffect(endpoint: endpoint, action: action, arguments: arguments)
        let authorization: Authorization = exception == .block ? .deny :
            (exception == .ask || effect != .verifiedRead ? .confirm : .allow)
        return Assessment(effect: effect, authorization: authorization)
    }
    public static func isVerifiedRead(endpoint: String, action: String, arguments: RemoteJSONValue? = nil) -> Bool {
        reviewedEffect(endpoint: endpoint, action: action, arguments: arguments) == .verifiedRead
    }
    public static func requiresConfirmation(endpoint: String, action: String, arguments: RemoteJSONValue? = nil,
                                            exception: Decision? = nil) -> Bool {
        assess(endpoint: endpoint, action: action, arguments: arguments, exception: exception).authorization != .allow
    }
    private static func reviewedEffect(endpoint: String, action: String, arguments: RemoteJSONValue?) -> Effect {
        guard let url = URLComponents(string: endpoint), url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil || url.port == 443 else { return .unknown }
        switch (url.host?.lowercased(), url.path) {
        case ("api.githubcopilot.com", "/mcp"), ("api.githubcopilot.com", "/mcp/"):
            if ["get_file_contents", "get_issue", "list_branches", "list_commits", "list_issues", "list_pull_requests",
                "search_code", "search_issues", "search_repositories"].contains(action) { return .verifiedRead }
            // These tools dispatch by method. An unrecognized/new method is not implicitly a read.
            let method = arguments?.objectValue?["method"]?.stringValue
            if action == "issue_read", let method,
               ["get", "get_comments", "get_labels", "get_sub_issues"].contains(method) { return .verifiedRead }
            if action == "pull_request_read", let method,
               ["get", "get_diff", "get_status", "get_files", "get_reviews", "get_review_comments", "get_comments"].contains(method) { return .verifiedRead }
            if ["create_or_update_file", "push_files", "delete_file", "create_branch", "issue_write", "create_pull_request",
                "update_pull_request", "merge_pull_request"].contains(action) { return .modification }
            if ["add_issue_comment", "add_comment_to_pending_review", "submit_pending_pull_request_review"].contains(action) { return .send }
            return .unknown
        case ("mcp.context7.com", "/mcp"), ("mcp.context7.com", "/mcp/"):
            return ["resolve-library-id", "query-docs", "get-library-docs"].contains(action) ? .verifiedRead : .unknown
        case ("mcp.deepwiki.com", "/mcp"), ("mcp.deepwiki.com", "/mcp/"):
            return ["read_wiki_structure", "read_wiki_contents", "ask_question"].contains(action) ? .verifiedRead : .unknown
        default: return .unknown
        }
    }
}

/// Multiple accounts at one URL get separate UUIDs, routing names and Keychain slots.
/// Reconnection must explicitly identify the existing connection; URL equality is never identity.
public enum MCPConnectionIdentity {
    public static func new(name: String, endpoint: URL, existing: [MCPServerConfiguration], connectorID: String? = nil) -> MCPServerConfiguration {
        let base = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }.prefix(30))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "connector" : base
        var routingName = stem, index = 1
        while existing.contains(where: { $0.name == routingName }) { index += 1; routingName = "\(stem)-\(index)" }
        return MCPServerConfiguration(name: routingName, transport: .http, url: endpoint.absoluteString,
            accountLabel: index == 1 ? name : "\(name) · \(index)", connectorID: connectorID)
    }
}

/// The execution boundary shared by iPhone and Mac, including account-specific exceptions.
public enum ConnectorPermissionService {
    public static func assess(server: MCPServerConfiguration, action: String, arguments: RemoteJSONValue? = nil,
                              serverClaimsReadOnly: Bool? = nil) -> ConnectorPermissionPolicy.Assessment {
        guard server.enabled, server.allows(tool: action) else {
            return .init(effect: .unknown, authorization: .deny)
        }
        return ConnectorPermissionPolicy.assess(endpoint: server.transport == .http ? (server.url ?? "") : "",
            action: action, arguments: arguments, exception: server.actionPermissions?[action],
            serverClaimsReadOnly: serverClaimsReadOnly)
    }
}
