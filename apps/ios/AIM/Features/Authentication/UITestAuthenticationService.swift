#if DEBUG
import AIMCore
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if targetEnvironment(simulator)
final class UITestLockStore: SecureStoring, @unchecked Sendable {
    private let mutex = NSLock()
    private var values: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { mutex.withLock { values[key] } }
    func store(_ data: Data, forKey key: String) throws { mutex.withLock { values[key] = data } }
    func removeData(forKey key: String) throws { mutex.withLock { values[key] = nil } }
}
@MainActor final class UITestLockAuthenticator: AppLockAuthenticating {
    func authenticate(reason: String) async throws {
        if ProcessInfo.processInfo.environment["AIM_UI_TEST_CANCEL_SYSTEM_AUTH"] == "1" { throw AppLockError.cancelled }
    }
}
#endif

final class UITestAuthenticationService: AuthenticationServicing, @unchecked Sendable {
    private let scenario: AppEnvironment.UITestScenario
    private let user = AuthenticatedUser(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
        email: "person@example.com",
        fullName: "Ada Lovelace"
    )

    init(scenario: AppEnvironment.UITestScenario) {
        self.scenario = scenario
    }

    func restoreSession() async throws -> AuthenticationState {
        switch scenario {
        case .signedOut:
            return .signedOut
        case .authenticated, .authenticatedOffline, .authenticatedUnpaired, .authenticatedRemoteFailure:
            return .authenticated(user)
        case .loading:
            try await Task.sleep(for: .seconds(30))
            return .signedOut
        case .recovery:
            return .passwordRecovery(user)
        }
    }

    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        throw AuthenticationError.invalidCredentials
    }

    func signUp(
        email: String,
        password: String,
        fullName: String
    ) async throws -> AuthenticationSignUpResult {
        .confirmationRequired(email: email)
    }

    func requestPasswordReset(email: String) async throws {}

    func handleCallback(_ url: URL) async throws -> AuthenticationState {
        .authenticated(user)
    }

    func updatePassword(_ password: String) async throws -> AuthenticationState {
        .authenticated(user)
    }

    func signInWithApple(
        identityToken: String,
        rawNonce: String,
        fullName: String?
    ) async throws -> AuthenticatedUser {
        user
    }

    func googleAuthorizationURL() throws -> URL {
        guard let url = URL(string: "https://example.supabase.co/auth/v1/authorize?provider=google") else {
            throw AuthenticationError.unexpected
        }
        return url
    }

    func signOut() async {}

    func events() -> AsyncStream<AuthenticationEvent> {
        AsyncStream { continuation in continuation.finish() }
    }
}

actor UITestRemoteService: RemoteServicing {
    private let scenario: AppEnvironment.UITestScenario
    private var pairedDuringTest = false
    private var testProtectionPolicy = RemoteProtectionPolicy(revision: 1, protectedModes: [.code, .agent], unlockAuthorized: true)
    private var assignedProjects: [String: String] = [:]

    func setSessionProject(_ projectID: String?, sessionID: String) async throws {
        assignedProjects[sessionID] = projectID
    }

    init(scenario: AppEnvironment.UITestScenario) {
        self.scenario = scenario
    }

    func loadOverview() async throws -> RemoteOverview {
        if scenario == .authenticatedRemoteFailure {
            throw RemoteServiceError.unavailable
        }
        if scenario == .authenticatedUnpaired, !pairedDuringTest {
            return .init(connectionState: .unpaired, machines: [], sessions: [])
        }
        guard scenario == .authenticated || scenario == .authenticatedOffline else {
            if scenario != .authenticatedUnpaired {
                return .init(connectionState: .unpaired, machines: [], sessions: [])
            }
            return pairedOverview(offline: false)
        }
        return pairedOverview(offline: scenario == .authenticatedOffline)
    }

    private var interactionFixture: RemotePendingApproval? {
        guard let kind = ProcessInfo.processInfo.environment["AIM_UI_TEST_PENDING_INTERACTION"] else { return nil }
        if kind == "question" {
            return .init(messageID: "fixture-question", toolName: "ask_user", summary: "Quelle application souhaitez-vous utiliser pour préparer le document ?", kind: "question", questions: [
                .object(["question": .string("Quelle application souhaitez-vous utiliser ?"), "options": .array([.object(["label": .string("TextEdit")]), .object(["label": .string("Pages")])])])
            ])
        }
        return .init(messageID: "fixture-approval", toolName: "open_app", summary: "Ouvrir TextEdit sur le Mac de test pour préparer votre document. Aucun document ne sera envoyé ni supprimé.")
    }

    private func pairedOverview(offline: Bool) -> RemoteOverview {
        let machine = RemoteMachine(
            id: "ui-test-machine",
            name: "Mac de Mathieu",
            platform: "darwin",
            appVersion: "2.0",
            lastSeenAt: offline ? .distantPast : Date(),
            keyVersion: nil,
            capabilities: .init(
                version: 4,
                models: [.init(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", provider: "openai", effortLevels: ["low", "high"], currentEffort: "high")],
                engines: [.init(id: "aim", state: "ready")],
                features: ["attachments": true, "goal": true, "continuity_experimental_v1": true]
            )
        )
        let additionalChats = (1...14).map { index in
            RemoteSession(
                id: "ui-test-chat-\(index)",
                machineID: machine.id,
                mode: .chat,
                title: "Conversation de test \(index)",
                workspace: nil,
                modelID: "gpt-5.6-sol",
                approvalMode: nil,
                status: "idle",
                messageCount: 1,
                updatedAt: Date().addingTimeInterval(Double(-40 - index)),
                agentSystem: nil,
                phase: nil,
                isSilent: false,
                isInterrupted: false
            )
        }
        let sessions = [
            RemoteSession(
                id: "ui-test-session",
                machineID: machine.id,
                mode: interactionFixture == nil ? .chat : .agent,
                title: "Préparer le lancement AIM.AI",
                workspace: nil,
                modelID: "gpt-5.6-sol",
                approvalMode: nil,
                status: interactionFixture == nil ? (ProcessInfo.processInfo.environment["AIM_UI_TEST_REMOTE_RUNNING"] == "1" ? "running" : "idle") : "waiting_approval",
                messageCount: 2,
                updatedAt: Date(),
                agentSystem: "aim",
                phase: nil,
                isSilent: false,
                isInterrupted: false,
                pendingApproval: interactionFixture
            ),
            RemoteSession(
                id: "ui-test-code-session",
                machineID: machine.id,
                mode: .code,
                title: "Application iOS",
                workspace: "/Projects/AIM",
                modelID: "gpt-5.6-sol",
                approvalMode: "review",
                status: "idle",
                messageCount: 1,
                updatedAt: Date().addingTimeInterval(-20),
                agentSystem: nil,
                phase: nil,
                isSilent: false,
                isInterrupted: false
            ),
        ] + additionalChats

        return .init(
            connectionState: .paired,
            machines: ProcessInfo.processInfo.environment["AIM_UI_TEST_MULTIPLE_COMPUTERS"] == "1" ? [machine, RemoteMachine(id: "ui-test-second-machine", name: "Second Mac", platform: "darwin", appVersion: "2.0", lastSeenAt: offline ? .distantPast : .now, keyVersion: nil, capabilities: machine.capabilities)] : [machine],
            sessions: sessions.map { $0.replacing(projectID: .some(assignedProjects[$0.id])) }
        )
    }

    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] {
        if interactionFixture != nil {
            return (1...24).map { index in
                .init(id: "dock-fixture-\(index)", sessionID: sessionID, sequence: index, role: .assistant,
                    content: "Paragraphe de test \(index). Le document contient des exemples fictifs pour vérifier le défilement de la conversation sous la carte de confirmation.", reasoning: nil, timeline: nil)
            }
        }
        if ProcessInfo.processInfo.environment["AIM_UI_TEST_MARKDOWN"] == "1" {
            return [.init(id: "ui-markdown", sessionID: sessionID, sequence: 1, role: .assistant,
                content: """
                ```bash
                echo 'A deliberately long unwrapped command that reaches the far edge of the horizontal viewport END_OF_CODE'
                ```

                | Element | Details | Final column |
                | --- | --- | --- |
                | License | Complete text with **Markdown** and enough words to wrap across several lines without truncation. | END_OF_TABLE |
                """, reasoning: nil, timeline: nil)]
        }
        return [
            .init(id: "ui-message-1", sessionID: sessionID, sequence: 1, role: .user, content: "Où en est le projet ?", reasoning: nil, timeline: nil),
            .init(id: "ui-message-2", sessionID: sessionID, sequence: 2, role: .assistant, content: "Le socle natif est prêt.", reasoning: nil, timeline: nil),
        ]
    }

    func pairDevice(code: String, name: String) async throws -> RemotePairingResult {
        let succeeded = code.count == 6
        if succeeded {
            pairedDuringTest = true
        }
        return .init(succeeded: succeeded, errorCode: succeeded ? nil : "invalid_or_expired_code")
    }

    func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult {
        if interactionFixture != nil, type == .approvalResponse {
            try await Task.sleep(for: .milliseconds(900))
            return .init(succeeded: false)
        }
        return .init(succeeded: true)
    }

    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String {
        "ui-test-session"
    }

    func remoteUnlockState() async throws -> RemoteUnlockState {
        .init(succeeded: true, hasPIN: ProcessInfo.processInfo.environment["AIM_UI_TEST_SECURITY_POLICY"] != nil, isEnabled: ProcessInfo.processInfo.environment["AIM_UI_TEST_SECURITY_POLICY"] != nil)
    }
    func remoteProtectionPolicy() async throws -> RemoteProtectionPolicy? {
        if ProcessInfo.processInfo.environment["AIM_UI_TEST_SECURITY_POLICY"] == "lockedAll" {
            return .init(revision: 1, protectedModes: RemoteMode.allCases)
        }
        return ProcessInfo.processInfo.environment["AIM_UI_TEST_SECURITY_POLICY"] == "1" ? testProtectionPolicy : nil
    }
    func setRemoteProtectionPolicy(_ modes: [RemoteMode], expectedRevision: Int) async throws -> RemoteProtectionPolicy {
        guard expectedRevision == testProtectionPolicy.revision else { throw RemoteSecurityServiceError.server(code: "policy_conflict") }
        testProtectionPolicy = .init(revision: expectedRevision+1, protectedModes: modes, unlockAuthorized: true)
        return testProtectionPolicy
    }
    func checkBridge(machineID: String) async throws {
        if scenario == .authenticatedOffline { throw RemoteServiceError.commandRejected("computer_offline") }
    }

    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing {
        .init(folders: [.init(path: "/Projects/AIM", name: "AIM", isProjectsDirectory: true)])
    }

    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult {
        .init(diff: "diff --git a/App.swift b/App.swift")
    }

    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult {
        .init(output: "Tests passed", exitCode: 0)
    }

    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult {
        .init(url: URL(string: "https://preview.example.com"))
    }

    func stopPreview(machineID: String, sessionID: String) async throws {}

    func uploadAttachment(
        data: Data,
        name: String,
        mimeType: String,
        machineID: String,
        sessionID: String
    ) async throws -> RemoteAttachmentReference {
        .init(
            transferID: "ui-test-attachment-\(name)",
            name: name,
            mimeType: mimeType,
            size: data.count
        )
    }
}

actor UITestCloudContentService: CloudContentServicing {
    private var profile = AIMUserProfile(fullName: "Ada Lovelace", preferredName: "Ada", personalPreferences: "Use concise explanations.")
    private var preferences = AIMUserPreferences.defaults
    private var memory = AIMMemoryDocument(content: "## Preferences\n- Native experience", version: 1, updatedAt: Date())
    private var projects: [AIMProject] = [
        .init(
            id: "ui-project",
            name: "AIM iOS",
            description: "Native application",
            customContext: "Keep the interface faithful.",
            createdAt: Date(),
            updatedAt: Date(),
            lastActiveAt: Date(),
            isStarred: true
        ),
    ]
    private var connectors: [AIMConnector] = [
        .init(
            id: "ui-connector",
            type: "oauth_notion",
            displayName: "Notion",
            serverURL: "https://mcp.notion.com/mcp",
            isActive: true,
            lastConnectedAt: Date(),
            tools: [.init(name: "search_pages", description: "Search workspace pages")],
            toolPermissions: ["search_pages": .ask],
            defaultParentID: nil,
            defaultParentName: nil,
            createdAt: Date()
        )
    ]

    func loadProfile() async throws -> AIMUserProfile { profile }
    func saveProfile(_ profile: AIMUserProfile) async throws { self.profile = profile }

    func loadProjects() async throws -> [AIMProject] { projects }
    func createProject(name: String, description: String?, customContext: String?) async throws -> AIMProject {
        let project = AIMProject(id: UUID().uuidString, name: name, description: description, customContext: customContext, createdAt: Date(), updatedAt: Date(), lastActiveAt: Date())
        projects.insert(project, at: 0)
        return project
    }
    func renameProject(id: String, name: String) async throws -> AIMProject {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw CloudContentError.unavailable }
        let current = projects[index]
        let updated = AIMProject(id: current.id, name: name, description: current.description, customContext: current.customContext, createdAt: current.createdAt, updatedAt: Date(), lastActiveAt: current.lastActiveAt, isStarred: current.isStarred)
        projects[index] = updated
        return updated
    }
    func setProjectFavorite(id: String, isFavorite: Bool) async throws -> AIMProject {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw CloudContentError.unavailable }
        let current = projects[index]
        let updated = AIMProject(id: current.id, name: current.name, description: current.description, customContext: current.customContext, createdAt: current.createdAt, updatedAt: Date(), lastActiveAt: current.lastActiveAt, isStarred: isFavorite)
        projects[index] = updated
        return updated
    }
    func archiveProject(id: String) async throws { projects.removeAll { $0.id == id } }
    func deleteProject(id: String) async throws { projects.removeAll { $0.id == id } }
    func loadProjectConversations(projectID: String) async throws -> [AIMProjectConversation] {
        [.init(id: "ui-project-conversation", title: "Design review", model: "gpt-5.6-sol", isPinned: false, updatedAt: Date())]
    }
    func loadProjectFiles(projectID: String) async throws -> [AIMProjectFile] {
        [.init(id: "ui-project-file", name: "specification.pdf", mimeType: "application/pdf", sizeBytes: 12_000, status: "completed", errorMessage: nil, createdAt: Date())]
    }
    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String) async throws -> AIMProjectFile {
        .init(id: UUID().uuidString, name: name, mimeType: mimeType, sizeBytes: data.count, status: "completed", errorMessage: nil, createdAt: Date())
    }
    func deleteProjectFile(projectID: String, fileID: String) async throws {}
    func loadLegacyMessages(conversationID: String) async throws -> [AIMLegacyMessage] {
        [.init(id: "ui-legacy-message", role: "assistant", content: "The native design is ready.", reasoning: nil, model: "gpt-5.6-sol", createdAt: Date())]
    }
    func loadMedia(kind: AIMMediaKind) async throws -> [AIMMediaItem] {
        guard ProcessInfo.processInfo.environment["AIM_UI_TEST_LIBRARY_MEDIA"] == "1", kind == .image else { return [] }
        return try [(640, 360), (360, 640), (640, 360), (360, 640)].enumerated().map { index, size in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-library-fixture-\(index).png")
            guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CloudContentError.unavailable }
            context.setFillColor(CGColor(red: index.isMultiple(of: 2) ? 0.25 : 0.7, green: 0.45, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: size.0 / 4, y: size.1 / 4, width: size.0 / 2, height: size.1 / 2))
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CloudContentError.unavailable }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CloudContentError.unavailable }
            return AIMMediaItem(id: "fixture-\(index)", kind: .image, url: url, prompt: index.isMultiple(of: 2) ? "Wide image" : "Portrait image", model: "fixture", createdAt: Date(timeIntervalSince1970: Double(100 - index)), expiresAt: .distantFuture, storagePath: "fixture-\(index)")
        }
    }
    func deleteMedia(_ item: AIMMediaItem) async throws {}
    func loadConnectors() async throws -> [AIMConnector] { connectors }
    func setConnectorActive(id: String, isActive: Bool) async throws {
        guard let connector = connectors.first else { return }
        connectors[0] = .init(id: connector.id, type: connector.type, displayName: connector.displayName, serverURL: connector.serverURL, isActive: isActive, lastConnectedAt: connector.lastConnectedAt, tools: connector.tools, toolPermissions: connector.toolPermissions, defaultParentID: connector.defaultParentID, defaultParentName: connector.defaultParentName, createdAt: connector.createdAt)
    }
    func setConnectorToolPermission(id: String, toolName: String, permission: ConnectorToolPermission) async throws {}
    func deleteConnector(id: String) async throws { connectors.removeAll { $0.id == id } }
    func connectorAuthorizationURL(provider: AIMConnectorOAuthProvider, redirectURL: URL) async throws -> URL {
        URL(string: "https://example.com/oauth/authorize?provider=\(provider.rawValue)")!
    }
    func loadPreferences() async throws -> AIMUserPreferences { preferences }
    func savePreferences(_ preferences: AIMUserPreferences) async throws { self.preferences = preferences }
    func loadMemoryDocument() async throws -> AIMMemoryDocument { memory }
    func saveMemoryDocument(content: String, expectedVersion: Int) async throws -> AIMMemoryDocument {
        memory = .init(content: content, version: expectedVersion + 1, updatedAt: Date())
        return memory
    }
    func exportUserData() async throws -> Data { Data("{\"source\":\"ui-test\"}".utf8) }
    func deleteAccount(confirmEmail: String, confirmation: String) async throws {}
}
#endif
