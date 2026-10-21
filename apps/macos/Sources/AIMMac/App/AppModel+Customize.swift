import AIMApplication
import AIMMacPlatform
import Foundation

/// Installing what the Customize store offers: connectors become MCP servers (signed in with
/// OAuth or a token), plugins bring their skills and connectors together.
extension AppModel {
    /// A connector name AIM accepts (letters, digits, - and _), unique among existing servers.
    func connectorName(_ title: String, existing: [MCPServerConfiguration]) -> String {
        var base = title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { result, character in if !(character == "-" && result.last == "-") { result.append(character) } }
        base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32))
        if base.isEmpty { base = "connector" }
        var name = base, index = 2
        while existing.contains(where: { $0.name == name }) { name = "\(base)-\(index)"; index += 1 }
        return name
    }

    /// Adds a store connector; OAuth ones open the provider's sign-in right away.
    @discardableResult
    func installConnector(_ connector: StoreConnector, token: String? = nil) async throws -> MCPServerConfiguration {
        guard let url = connector.url, !connector.soon else { throw StoreError.notFound }
        let existing = try await mcpServerRepository.list()
        if let already = existing.first(where: { $0.url == url }) { return already }
        let transport: MCPServerConfiguration.Transport = url.hasSuffix("/sse") ? .sse : .http
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = MCPServerConfiguration(name: connectorName(connector.name, existing: existing), transport: transport, url: url,
                                            secretNames: token?.isEmpty == false ? ["AUTHORIZATION"] : [])
        if let token, !token.isEmpty { try MCPSecretStore.save(token, name: "AUTHORIZATION", serverID: server.id) }
        try await mcpServerRepository.save(server)
        if connector.auth == .oauth, token?.isEmpty != false {
            try await MCPOAuth.signIn(server: server)
            await MCPServerManager.shared.disconnect(server.id)
        }
        return server
    }

    func removeConnector(_ server: MCPServerConfiguration) async {
        await MCPServerManager.shared.disconnect(server.id)
        for name in server.secretNames { try? MCPSecretStore.remove(name: name, serverID: server.id) }
        MCPOAuth.signOut(serverID: server.id)
        try? await mcpServerRepository.delete(id: server.id)
    }

    /// Installs a plugin's skills and remote connectors; returns what was skipped.
    func installPlugin(_ plugin: StorePlugin) async throws -> [String] {
        let store = CustomizeStore.shared
        let contents = try await store.contents(plugin)
        let skills = try await store.installSkills(of: plugin, contents: contents)
        var connectorIDs: [UUID] = []
        for server in contents.servers {
            let connector = StoreConnector(id: "plugin:\(server.name)", name: server.name, description: "", url: server.url,
                                           category: "Plugin", publisher: plugin.author ?? plugin.marketplace)
            // Plugin connectors are added signed out; sign in from Customize › Connectors.
            let existing = try await mcpServerRepository.list()
            if let already = existing.first(where: { $0.url == server.url }) { connectorIDs.append(already.id); continue }
            let configuration = MCPServerConfiguration(name: connectorName(connector.name, existing: existing),
                                                       transport: server.transport == "sse" ? .sse : .http, url: server.url)
            try await mcpServerRepository.save(configuration)
            connectorIDs.append(configuration.id)
        }
        guard !skills.isEmpty || !connectorIDs.isEmpty else { throw StoreError.notFound }
        var installed = InstalledPlugins.all().filter { $0.id != plugin.id }
        installed.append(InstalledPlugin(id: plugin.id, title: plugin.title, skills: skills, connectorIDs: connectorIDs))
        InstalledPlugins.save(installed)
        return contents.ignored
    }

    func uninstallPlugin(_ plugin: InstalledPlugin) async {
        if let global = SkillCatalog.globalDirectory {
            for skill in plugin.skills where SkillCatalog.isValidName(skill) {
                try? FileManager.default.trashItem(at: global.appendingPathComponent(skill, isDirectory: true), resultingItemURL: nil)
            }
        }
        let servers = (try? await mcpServerRepository.list()) ?? []
        for server in servers where plugin.connectorIDs.contains(server.id) { await removeConnector(server) }
        InstalledPlugins.save(InstalledPlugins.all().filter { $0.id != plugin.id })
    }

    /// Customize replaces the conversation (which is closed, its draft kept for when it is reopened).
    func openCustomize() async {
        if selectedConversationID != nil || projectPageVisible { await selectConversation(nil) }
        projectPageVisible = false
        settingsSection = nil
        showCustomize = true
    }

    /// "Create with AIM": an Agent conversation that writes a new skill with the person.
    func createSkillWithAIM() async {
        await newGeneralConversation()
        selectNewConversationMode(.agent)
        composerText = "Help me create a new skill for AIM. Ask me what task it should handle, how I do it step by step, "
            + "and what a good result looks like. Then write the SKILL.md (name, description, instructions) and propose it to me."
    }
}
