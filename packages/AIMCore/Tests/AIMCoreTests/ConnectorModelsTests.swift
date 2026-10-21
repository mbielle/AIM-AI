import Testing
@testable import AIMCore

@Suite("Connector models")
struct ConnectorModelsTests {
    @Test("Known connector types use the product name")
    func knownDisplayName() {
        let connector = AIMConnector.fixture(type: "oauth_notion", displayName: "Workspace")
        #expect(connector.productName == "Notion")
    }

    @Test("Unknown connector types preserve their configured name")
    func unknownDisplayName() {
        let connector = AIMConnector.fixture(type: "custom_mcp", displayName: "Internal tools")
        #expect(connector.productName == "Internal tools")
    }

    @Test("Tool permissions default to ask")
    func defaultToolPermission() {
        let connector = AIMConnector.fixture(type: "custom_mcp", displayName: "Internal tools")
        #expect(connector.permission(for: "create_issue") == .ask)
    }

    @Test("Explicit tool permissions are retained")
    func explicitToolPermission() {
        let connector = AIMConnector.fixture(
            type: "custom_mcp",
            displayName: "Internal tools",
            permissions: ["list_projects": .alwaysAllow, "delete_project": .block]
        )
        #expect(connector.permission(for: "list_projects") == .alwaysAllow)
        #expect(connector.permission(for: "delete_project") == .block)
    }
}

@Suite("Personalization models")
struct PersonalizationModelsTests {
    @Test("Default preferences match the safe product behavior")
    func safeDefaults() {
        let preferences = AIMUserPreferences.defaults
        #expect(preferences.hapticFeedback)
        #expect(preferences.memoryEnabled)
        #expect(preferences.smartContext)
        #expect(preferences.maxEmojis == 6)
        #expect(preferences.libraryRetentionDays == 60)
        #expect(preferences.shareProfileWithAI == false)
    }

    @Test("Preference choices remain bounded to supported values")
    func supportedChoices() {
        #expect(AIMTone.allCases.map(\.rawValue).contains("professional"))
        #expect(AIMResponseStyle.allCases.map(\.rawValue).contains("technical"))
        #expect(AIMExpertise.allCases.map(\.rawValue).contains("expert"))
        #expect(AIMResponseLength.allCases.map(\.rawValue).contains("concise"))
    }
}

@Suite("Profile models")
struct ProfileModelsTests {
    @Test("Profile values are trimmed and preference length is bounded")
    func normalizedProfile() {
        let profile = AIMUserProfile(
            fullName: "  Ada Lovelace  ",
            preferredName: "  Ada  ",
            personalPreferences: String(repeating: "a", count: 2_100)
        )

        #expect(profile.fullName == "Ada Lovelace")
        #expect(profile.preferredName == "Ada")
        #expect(profile.personalPreferences.count == 2_000)
    }
}

private extension AIMConnector {
    static func fixture(
        type: String,
        displayName: String,
        permissions: [String: ConnectorToolPermission] = [:]
    ) -> Self {
        .init(
            id: "connector-1",
            type: type,
            displayName: displayName,
            serverURL: "https://example.com/mcp",
            isActive: true,
            lastConnectedAt: nil,
            tools: [.init(name: "list_projects", description: "Lists projects")],
            toolPermissions: permissions,
            defaultParentID: nil,
            defaultParentName: nil,
            createdAt: .distantPast
        )
    }
}
