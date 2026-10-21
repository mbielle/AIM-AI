import Foundation

public enum RemoteConnectionState: Equatable, Sendable {
    case unpaired
    case paired
    case needsRepair
}

public struct RemoteMachine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String?
    public let appVersion: String?
    public let lastSeenAt: Date
    public let keyVersion: Int?
    public let capabilities: RemoteCapabilities?
    public let readState: RemoteReadState
    public let keyRequestFailure: RemoteCommandFailure?

    public init(id: String, name: String, platform: String?, appVersion: String?, lastSeenAt: Date, keyVersion: Int?, capabilities: RemoteCapabilities? = nil, readState: RemoteReadState = .unknown, keyRequestFailure: RemoteCommandFailure? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.keyVersion = keyVersion
        self.capabilities = capabilities
        self.readState = readState
        self.keyRequestFailure = keyRequestFailure
    }

    public func isOnline(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(lastSeenAt) < 75
    }
}

public struct RemotePendingApproval: Equatable, Sendable {
    public let executionID: String?
    public let sessionID: String?
    public let messageID: String
    public let toolName: String
    public let summary: String
    public let kind: String?
    public let questions: [RemoteJSONValue]?

    public init(messageID: String, toolName: String, summary: String, kind: String? = nil, questions: [RemoteJSONValue]? = nil, executionID: String? = nil, sessionID: String? = nil) {
        self.executionID = executionID; self.sessionID = sessionID
        self.messageID = messageID
        self.toolName = toolName
        self.summary = summary
        self.kind = kind
        self.questions = questions
    }

    public init?(json: RemoteJSONValue?) {
        guard let object = json?.objectValue else { return nil }
        executionID = object["executionId"]?.stringValue
        sessionID = object["sessionId"]?.stringValue
        messageID = object["messageId"]?.stringValue ?? ""
        toolName = object["toolName"]?.stringValue ?? ""
        summary = object["summary"]?.stringValue ?? ""
        kind = object["kind"]?.stringValue
        questions = object["questions"]?.arrayValue
    }
}

public struct RemoteSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let machineID: String
    public let mode: RemoteMode
    public let title: String
    public let workspace: String?
    public let modelID: String?
    public let modelProvider: String?
    public let approvalMode: String?
    public let status: String
    public let messageCount: Int
    public let updatedAt: Date
    public let agentSystem: String?
    public let phase: String?
    public let isSilent: Bool
    public let isInterrupted: Bool
    public let pendingApproval: RemotePendingApproval?
    public let runStartedAt: Date?
    public let isPinned: Bool
    public let archivedAt: Date?
    public let projectID: String?
    public let readState: RemoteReadState
    public let executionDeviceIDs: [String]?
    public let latestResponseVersion: ConversationResponseVersion?

    public init(
        id: String,
        machineID: String,
        mode: RemoteMode,
        title: String,
        workspace: String?,
        modelID: String?,
        approvalMode: String?,
        status: String,
        messageCount: Int,
        updatedAt: Date,
        agentSystem: String?,
        phase: String?,
        isSilent: Bool,
        isInterrupted: Bool,
        pendingApproval: RemotePendingApproval? = nil,
        runStartedAt: Date? = nil,
        isPinned: Bool = false,
        archivedAt: Date? = nil,
        projectID: String? = nil,
        readState: RemoteReadState = .unknown,
        modelProvider: String? = nil,
        executionDeviceIDs: [String]? = nil,
        latestResponseVersion: ConversationResponseVersion? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.mode = mode
        self.title = title
        self.workspace = workspace
        self.modelID = modelID
        self.modelProvider = modelProvider
        self.approvalMode = approvalMode
        self.status = status
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.agentSystem = agentSystem
        self.phase = phase
        self.isSilent = isSilent
        self.isInterrupted = isInterrupted
        self.pendingApproval = pendingApproval
        self.runStartedAt = runStartedAt
        self.isPinned = isPinned
        self.archivedAt = archivedAt
        self.projectID = projectID
        self.readState = readState
        self.executionDeviceIDs = executionDeviceIDs
        self.latestResponseVersion = latestResponseVersion
    }
}

public extension RemoteSession {
    func replacing(
        title: String? = nil,
        isPinned: Bool? = nil,
        archivedAt: Date?? = nil,
        projectID: String?? = nil,
        pendingApproval: RemotePendingApproval?? = nil
    ) -> RemoteSession {
        RemoteSession(
            id: id,
            machineID: machineID,
            mode: mode,
            title: title ?? self.title,
            workspace: workspace,
            modelID: modelID,
            approvalMode: approvalMode,
            status: status,
            messageCount: messageCount,
            updatedAt: updatedAt,
            agentSystem: agentSystem,
            phase: phase,
            isSilent: isSilent,
            isInterrupted: isInterrupted,
            pendingApproval: pendingApproval ?? self.pendingApproval,
            runStartedAt: runStartedAt,
            isPinned: isPinned ?? self.isPinned,
            archivedAt: archivedAt ?? self.archivedAt,
            projectID: projectID ?? self.projectID,
            readState: readState,
            modelProvider: modelProvider,
            executionDeviceIDs: executionDeviceIDs, latestResponseVersion: latestResponseVersion
        )
    }
}

public struct RemoteToolCall: Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let parameters: RemoteJSONValue?
    public let status: String?
    public let result: RemoteJSONValue?
    public let warning: String?
    public let error: String?

    public init(id: String? = nil, name: String? = nil, parameters: RemoteJSONValue? = nil, status: String? = nil, result: RemoteJSONValue? = nil, warning: String? = nil, error: String? = nil) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.status = status
        self.result = result
        self.warning = warning
        self.error = error
    }

    public init?(json: RemoteJSONValue) {
        guard let object = json.objectValue else { return nil }
        id = object["id"]?.stringValue
        name = object["name"]?.stringValue
        parameters = object["params"]
        status = object["status"]?.stringValue
        result = object["result"]
        warning = object["warning"]?.stringValue
        error = object["error"]?.stringValue
    }

    public var legacy: RemoteLegacyToolCall {
        .init(id: id, name: name, status: status, result: result?.displayText, warning: warning, error: error, parameters: parameters)
    }
}

public struct RemoteRunStats: Equatable, Sendable {
    public let milliseconds: Int
    public let tokens: Int
    public let estimated: Bool
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let cachedWriteTokens: Int?
    public let model: String?
    public let directCost: Double?
    public let finishedAt: Double?

    public init(milliseconds: Int, tokens: Int, estimated: Bool, inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, cachedWriteTokens: Int? = nil, model: String? = nil, directCost: Double? = nil, finishedAt: Double? = nil) {
        self.milliseconds = milliseconds
        self.tokens = tokens
        self.estimated = estimated
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.model = model
        self.directCost = directCost
        self.finishedAt = finishedAt
    }

    public init?(json: RemoteJSONValue?) {
        guard let value = json?.objectValue else { return nil }
        milliseconds = Int(value["ms"]?.numberValue ?? 0)
        tokens = Int(value["tokens"]?.numberValue ?? 0)
        estimated = value["estimated"]?.boolValue ?? false
        inputTokens = value["entree"]?.numberValue.map(Int.init)
        outputTokens = value["sortie"]?.numberValue.map(Int.init)
        cachedInputTokens = value["cacheLu"]?.numberValue.map(Int.init)
        cachedWriteTokens = value["cacheEcrit"]?.numberValue.map(Int.init)
        model = value["modele"]?.stringValue
        directCost = value["coutDirect"]?.numberValue
        finishedAt = value["finiA"]?.numberValue
    }

    public var duration: Double { Double(milliseconds) / 1_000 }
}

public struct RemoteMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let sequence: Int
    public let role: RemoteMessageRole
    public let content: String
    public let reasoning: String?
    public let timeline: [RemoteJSONValue]?
    public let toolCalls: [RemoteToolCall]
    public let model: String?
    public let runStats: RemoteRunStats?
    public let readState: RemoteReadState

    public init(id: String, sessionID: String, sequence: Int, role: RemoteMessageRole, content: String, reasoning: String?, timeline: [RemoteJSONValue]?, toolCalls: [RemoteToolCall] = [], model: String? = nil, runStats: RemoteRunStats? = nil, readState: RemoteReadState = .unknown) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.timeline = timeline
        self.toolCalls = toolCalls
        self.model = model
        self.runStats = runStats
        self.readState = readState
    }

    public var timelineMessage: RemoteTimelineMessage {
        .init(id: id, role: role, content: content, reasoning: reasoning, toolCalls: toolCalls.map(\.legacy), timeline: timeline)
    }
}

public struct RemoteOverview: Equatable, Sendable {
    public let connectionState: RemoteConnectionState
    public let machines: [RemoteMachine]
    public let sessions: [RemoteSession]

    public init(connectionState: RemoteConnectionState, machines: [RemoteMachine], sessions: [RemoteSession]) {
        self.connectionState = connectionState
        self.machines = machines
        self.sessions = sessions
    }
}

public struct RemotePairingResult: Equatable, Sendable {
    public let succeeded: Bool
    public let errorCode: String?

    public init(succeeded: Bool, errorCode: String? = nil) {
        self.succeeded = succeeded
        self.errorCode = errorCode
    }
}

public struct RemotePairingFailure: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case authentication = "AUTH"
        case identity = "IDENTITY"
        case request = "RPC"
        case response = "RESPONSE"
        case persistence = "KEYCHAIN"
    }

    public let stage: Stage
    public let code: String

    public init(stage: Stage, code: String) {
        self.stage = stage
        let safeCode = code
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        self.code = String((safeCode.isEmpty ? "UNKNOWN" : safeCode).prefix(32))
    }

    /// Safe to display and log: this reference never contains a pairing code,
    /// token, device secret, key, email address, or server response body.
    public var reference: String {
        "PAIR-\(stage.rawValue)-\(code)"
    }
}

public enum RemoteServiceError: Error, Equatable, Sendable {
    case unavailable
    case invalidPairingCode
    case pairingFailed(RemotePairingFailure)
    case sessionUnavailable
    case deviceNotPaired
    case encryptionKeyUnavailable
    case commandFailure(RemoteCommandFailure)
    case commandRejected(String)
    case unexpected
}

public enum RemoteCommandType: String, Sendable {
    case getMacSettings = "get_mac_settings"
    case setMacSettings = "set_mac_settings"
    case startContinuousGoal = "goal_start"
    case continuousGoalStatus = "goal_status"
    case pauseContinuousGoal = "goal_pause"
    case resumeContinuousGoal = "goal_resume"
    case cancelContinuousGoal = "goal_cancel"
    case correctContinuousGoal = "goal_correct"
    case acceptContinuousGoal = "goal_accept"
    case continuousGoalApproval = "goal_approval_response"
    case continuousGoalQuestion = "goal_question_response"
    case userMessage = "user_message"
    case approvalResponse = "approval_response"
    case setModel = "set_model"
    case setModelAdded = "set_model_added"
    case setApprovalMode = "set_approval_mode"
    case stopGeneration = "stop_generation"
    case resumeTurn = "resume_turn"
    case requestDiff = "request_diff"
    case startPreview = "start_preview"
    case stopPreview = "stop_preview"
    case runCommand = "run_command"
    case stopCommand = "stop_command"
    case requestDetail = "request_detail"
    case requestHistory = "request_history"
    case renameSession = "rename_session"
    case archiveSession = "archive_session"
    case deleteSession = "delete_session"
}

public struct RemoteCommandResult: Equatable, Sendable {
    public let succeeded: Bool
    public let errorCode: String?
    public let result: RemoteJSONValue?
    public let commandID: String?

    public init(succeeded: Bool, errorCode: String? = nil, result: RemoteJSONValue? = nil, commandID: String? = nil) {
        self.succeeded = succeeded
        self.errorCode = errorCode
        self.result = result
        self.commandID = commandID
    }
}

public struct RemoteGoalConfiguration: Equatable, Sendable {
    public let maximumTurns: Int
    public let continuous: Bool

    public init(maximumTurns: Int) {
        self.maximumTurns = min(50, max(1, maximumTurns))
        continuous = false
    }
    public init(continuous: Bool, maximumTurns: Int? = nil) {
        self.continuous = continuous
        self.maximumTurns = continuous ? max(0, maximumTurns ?? 0) : min(50, max(1, maximumTurns ?? 10))
    }
    public var json: RemoteJSONValue {
        continuous ? RemoteContinuousGoalConfiguration(maximumTurns: maximumTurns == 0 ? nil : maximumTurns).json
            : .object(["max_turns": .number(Double(maximumTurns))])
    }
}

public struct RemoteSessionCreationRequest: Equatable, Sendable {
    public let machineID: String
    public let mode: RemoteMode
    public let modelID: String
    public let provider: String?
    public let workspace: String?
    public let approvalMode: String?
    public let text: String
    public let agentSystem: String?
    public let effort: String?
    public let attachments: [RemoteAttachmentReference]
    public let goal: RemoteGoalConfiguration?
    public let defersInitialMessage: Bool
    public let maximumSpendUSD: String?
    public let delegationID: UUID?

    public init(machineID: String, mode: RemoteMode, modelID: String, workspace: String? = nil, approvalMode: String? = nil, text: String, agentSystem: String? = nil, effort: String? = nil, attachments: [RemoteAttachmentReference] = [], goal: RemoteGoalConfiguration? = nil, defersInitialMessage: Bool = false, maximumSpendUSD: String? = nil, delegationID: UUID? = nil, provider: String? = nil) {
        self.machineID = machineID
        self.mode = mode
        self.modelID = modelID
        self.provider = provider
        self.workspace = workspace
        self.approvalMode = approvalMode
        self.text = text
        self.agentSystem = agentSystem
        self.effort = effort
        self.attachments = attachments
        self.goal = goal
        self.defersInitialMessage = defersInitialMessage
        self.maximumSpendUSD = maximumSpendUSD; self.delegationID = delegationID
    }
}

public struct RemoteFolder: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isProjectsDirectory: Bool

    public init(path: String, name: String, isProjectsDirectory: Bool = false) {
        self.path = path
        self.name = name
        self.isProjectsDirectory = isProjectsDirectory
    }

    public init?(json: RemoteJSONValue) {
        guard let object = json.objectValue, let path = object["path"]?.stringValue, !path.isEmpty else { return nil }
        self.path = path
        name = object["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent
        isProjectsDirectory = object["isProjects"]?.boolValue ?? false
    }
}

public struct RemoteFolderListing: Equatable, Sendable {
    public let folders: [RemoteFolder]
    public let currentPath: String?
    public let projectsDirectory: String?

    public init(folders: [RemoteFolder], currentPath: String? = nil, projectsDirectory: String? = nil) {
        self.folders = folders
        self.currentPath = currentPath
        self.projectsDirectory = projectsDirectory
    }
}

public struct RemoteFolderSnapshot: Equatable, Sendable {
    public let machineID: String
    public let path: String?
    public let folders: [RemoteFolder]
    public let loadedAt: Date
    public let isFromCache: Bool
    public let errorCode: RemoteCommandErrorCode?

    public init(
        machineID: String,
        path: String?,
        folders: [RemoteFolder],
        loadedAt: Date = Date(),
        isFromCache: Bool = false,
        errorCode: RemoteCommandErrorCode? = nil
    ) {
        self.machineID = machineID
        self.path = path
        self.folders = folders
        self.loadedAt = loadedAt
        self.isFromCache = isFromCache
        self.errorCode = errorCode
    }

    public func isStale(at date: Date = Date(), maximumAge: TimeInterval = 5 * 60) -> Bool {
        date.timeIntervalSince(loadedAt) > maximumAge
    }
}

public struct RemoteChangedFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String?
    public let additions: Int
    public let deletions: Int

    public init(path: String, status: String? = nil, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.status = status
        self.additions = max(0, additions)
        self.deletions = max(0, deletions)
    }
}

public struct RemoteDiffResult: Equatable, Sendable {
    public let diff: String
    public let base: String?
    public let directory: String?
    public let files: [RemoteChangedFile]

    public init(diff: String, base: String? = nil, directory: String? = nil, files: [RemoteChangedFile] = []) {
        self.diff = diff
        self.base = base
        self.directory = directory
        self.files = files.isEmpty ? RemoteUnifiedDiffParser.files(in: diff) : files
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public enum RemoteUnifiedDiffParser {
    public static func files(in diff: String) -> [RemoteChangedFile] {
        var order: [String] = []
        var counts: [String: (status: String?, additions: Int, deletions: Int)] = [:]
        var currentPath: String?

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                let pieces = line.split(separator: " ")
                if pieces.count >= 4 {
                    let raw = String(pieces[3])
                    currentPath = raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : raw
                    if let currentPath, counts[currentPath] == nil {
                        order.append(currentPath)
                        counts[currentPath] = (nil, 0, 0)
                    }
                }
                continue
            }
            if line.hasPrefix("+++ "), currentPath == nil {
                let raw = String(line.dropFirst(4))
                guard raw != "/dev/null" else { continue }
                currentPath = raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : raw
                if let currentPath, counts[currentPath] == nil {
                    order.append(currentPath)
                    counts[currentPath] = (nil, 0, 0)
                }
                continue
            }
            guard let path = currentPath, var count = counts[path] else { continue }
            if line.hasPrefix("new file mode") { count.status = "added" }
            else if line.hasPrefix("deleted file mode") { count.status = "deleted" }
            else if line.hasPrefix("rename from") { count.status = "renamed" }
            else if line.hasPrefix("+") && !line.hasPrefix("+++") { count.additions += 1 }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { count.deletions += 1 }
            counts[path] = count
        }

        return order.compactMap { path in
            counts[path].map { RemoteChangedFile(path: path, status: $0.status, additions: $0.additions, deletions: $0.deletions) }
        }
    }
}

public struct RemoteHistoryPage: Equatable, Sendable {
    public let messages: [RemoteMessage]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(messages: [RemoteMessage], nextCursor: String? = nil, hasMore: Bool = false) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteSessionAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let machineID: String
    public let name: String
    public let mimeType: String
    public let size: Int
    public let source: String
    public let createdAt: Date
    public let expiresAt: Date?

    public init(id: String, sessionID: String, machineID: String, name: String, mimeType: String, size: Int, source: String, createdAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.machineID = machineID
        self.name = name
        self.mimeType = mimeType
        self.size = max(0, size)
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public struct RemoteTerminalResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int?
    public let truncated: Bool
    public let stopped: Bool

    public init(output: String, exitCode: Int? = nil, truncated: Bool = false, stopped: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.truncated = truncated
        self.stopped = stopped
    }
}

public struct RemotePreviewResult: Equatable, Sendable {
    public let url: URL?
    public let needsServer: Bool
    public let scripts: [String]
    public let browserSnapshot: String?
    public let observationID: String?
    public let browserError: String?
    public let isBrowserSnapshot: Bool

    public init(url: URL? = nil, needsServer: Bool = false, scripts: [String] = [], browserSnapshot: String? = nil,
                observationID: String? = nil, browserError: String? = nil, isBrowserSnapshot: Bool = false) {
        self.url = url; self.needsServer = needsServer; self.scripts = scripts
        self.browserSnapshot = browserSnapshot; self.observationID = observationID
        self.browserError = browserError; self.isBrowserSnapshot = isBrowserSnapshot
    }
    public init(json: RemoteJSONValue) {
        let object = json.objectValue ?? [:]
        let native = object["preview_kind"]?.stringValue == "browser_snapshot_v1"
        self.init(url: object["url"]?.stringValue.flatMap(URL.init(string:)),
            needsServer: object["needsServer"]?.boolValue ?? false,
            scripts: object["scripts"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            browserSnapshot: native ? object["browser_snapshot"]?.stringValue : nil,
            observationID: native ? object["observation_id"]?.stringValue : nil,
            browserError: native ? object["browser_error"]?.stringValue : nil, isBrowserSnapshot: native)
    }
}

public enum RemoteEvent: Equatable, Sendable {
    case overviewChanged
    case messagesChanged(sessionID: String)
}

public protocol RemoteReading: Sendable {
    func loadOverview() async throws -> RemoteOverview
    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage]
    func events(for sessionID: String?) async -> AsyncStream<RemoteEvent>
    func diagnosticReport() async -> RemoteDiagnosticReport
}

public protocol RemotePairing: Sendable {
    func pairDevice(code: String, name: String) async throws -> RemotePairingResult
}

public protocol RemoteCommanding: Sendable {
    /// Confirms a terminal host reply and an opened current key; never lists folders.
    func checkBridge(machineID: String) async throws
    func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult
    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String
    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing
    func createFolder(machineID: String, parent: String, name: String) async throws -> RemoteFolder
    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult
    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult
    func stopTerminalCommand(machineID: String, sessionID: String) async throws
    func requestDetail(machineID: String, sessionID: String, detailID: String) async throws -> RemoteJSONValue
    func requestDetail(machineID: String, sessionID: String, detailID: String, offset: Int) async throws -> RemoteJSONValue
    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult
    func stopPreview(machineID: String, sessionID: String) async throws
    func uploadAttachment(data: Data, name: String, mimeType: String, machineID: String, sessionID: String) async throws -> RemoteAttachmentReference
    func deleteSessions(ids: [String]) async throws
    func setSessionPinned(_ pinned: Bool, sessionID: String) async throws
    func setSessionProject(_ projectID: String?, sessionID: String) async throws
    func renameSession(_ title: String, machineID: String, sessionID: String) async throws
    func setSessionArchived(_ archived: Bool, machineID: String, sessionID: String) async throws
    func loadHistory(machineID: String, sessionID: String, cursor: String?, limit: Int) async throws -> RemoteHistoryPage
    func loadAttachmentMetadata(machineID: String, sessionID: String) async throws -> [RemoteSessionAttachment]
}

public protocol RemoteServicing: RemoteReading, RemotePairing, RemoteCommanding, RemoteSecurityServicing {}

public extension RemoteReading {
    func diagnosticReport() async -> RemoteDiagnosticReport {
        .init(appVersion: "unknown", entries: [])
    }

    func events(for sessionID: String?) async -> AsyncStream<RemoteEvent> {
        AsyncStream { continuation in
            continuation.onTermination = { _ in }
        }
    }
}

public extension RemoteCommanding {
    func checkBridge(machineID: String) async throws {
        // A missing local implementation is not a reply from the computer.
        throw RemoteServiceError.commandFailure(.init(code: .unsupportedCommand, stage: .rpc,
            serverCode: "bridge_probe_unavailable", diagnosticReference: "REMOTE-BRIDGE-PROBE-UNAVAILABLE"))
    }

    private func unsupportedCommand() -> RemoteServiceError {
        .commandFailure(
            .init(
                code: .unsupportedCommand,
                stage: .failed,
                serverCode: "unsupported_command",
                diagnosticReference: "REMOTE-UNAVAILABLE-UNSUPPORTED-COMMAND"
            )
        )
    }

    func deleteSessions(ids: [String]) async throws {
        throw RemoteServiceError.commandFailure(
            .init(
                code: .unsupportedCommand,
                stage: .failed,
                serverCode: "unsupported_command",
                diagnosticReference: "REMOTE-UNAVAILABLE-UNSUPPORTED-COMMAND"
            )
        )
    }

    func createFolder(machineID: String, parent: String, name: String) async throws -> RemoteFolder {
        throw RemoteServiceError.commandFailure(
            .init(
                code: .unsupportedCommand,
                stage: .failed,
                serverCode: "unsupported_command",
                diagnosticReference: "REMOTE-UNAVAILABLE-UNSUPPORTED-COMMAND"
            )
        )
    }

    func stopTerminalCommand(machineID: String, sessionID: String) async throws {
        throw RemoteServiceError.commandFailure(
            .init(
                code: .unsupportedCommand,
                stage: .failed,
                serverCode: "unsupported_command",
                diagnosticReference: "REMOTE-UNAVAILABLE-UNSUPPORTED-COMMAND"
            )
        )
    }

    func requestDetail(machineID: String, sessionID: String, detailID: String, offset: Int) async throws -> RemoteJSONValue {
        guard offset == 0 else { throw URLError(.unsupportedURL) }
        return try await requestDetail(machineID: machineID, sessionID: sessionID, detailID: detailID)
    }
    func requestDetail(machineID: String, sessionID: String, detailID: String) async throws -> RemoteJSONValue {
        throw RemoteServiceError.commandFailure(
            .init(
                code: .unsupportedCommand,
                stage: .failed,
                serverCode: "unsupported_command",
                diagnosticReference: "REMOTE-UNAVAILABLE-UNSUPPORTED-COMMAND"
            )
        )
    }

    func uploadAttachment(data: Data, name: String, mimeType: String, machineID: String, sessionID: String) async throws -> RemoteAttachmentReference {
        throw URLError(.unsupportedURL)
    }

    func setSessionPinned(_ pinned: Bool, sessionID: String) async throws { throw unsupportedCommand() }
    func setSessionProject(_ projectID: String?, sessionID: String) async throws { throw unsupportedCommand() }
    func renameSession(_ title: String, machineID: String, sessionID: String) async throws { throw unsupportedCommand() }
    func setSessionArchived(_ archived: Bool, machineID: String, sessionID: String) async throws { throw unsupportedCommand() }
    func loadHistory(machineID: String, sessionID: String, cursor: String?, limit: Int) async throws -> RemoteHistoryPage { throw unsupportedCommand() }
    func loadAttachmentMetadata(machineID: String, sessionID: String) async throws -> [RemoteSessionAttachment] { throw unsupportedCommand() }
}
