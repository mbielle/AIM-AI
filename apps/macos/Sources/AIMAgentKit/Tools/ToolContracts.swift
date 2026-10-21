import Foundation

public enum ToolRisk: Int, Codable, Comparable, Sendable {
    case readOnly = 0
    case localMutation = 1
    case externalEffect = 2
    case destructive = 3
    /// Private local data outside the current turn; approval is required even in Auto.
    case sensitiveRead = 4
    /// Starts another billable model run: never asked except in Plan (which forbids it).
    case delegation = 5
    /// A computer action can submit, purchase or change another app's state.
    case computerAction = 6
    /// An observation of the user's desktop. In Auto, macOS permission is enough;
    /// other chat modes still request an approval before sharing it with a model.
    case computerRead = 7
    /// Defines which host-observed facts may count toward mission success.
    /// The user must review the exact predicate even in Auto mode.
    case missionDefinition = 8

    public static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An executor reports what it knows about the effect, independently from
/// transport success and from the eventual success of the whole mission.
public enum ActionOutcome: String, Codable, Sendable {
    case confirmed
    case partial
    case unverified
    case suspectedAbsent = "suspected_absent"
    case unknown
}

public enum ApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case alwaysAsk
    case smart
    case autoApprove
    case plan

    public func requiresApproval(for risk: ToolRisk) -> Bool {
        switch self {
        // Sub-agents start without asking in every mode but Plan: delegating is how the agent
        // works autonomously. Their own actions follow the same mode as the parent's.
        case .alwaysAsk: risk != .delegation
        case .smart: risk >= .localMutation && risk != .delegation
        case .autoApprove: risk == .destructive || risk == .sensitiveRead || risk == .computerAction || risk == .missionDefinition
        case .plan: risk != .readOnly && risk != .computerRead
        }
    }
}

public struct ToolRequest: Codable, Sendable {
    public var id: String
    public var name: String
    public var arguments: [String: String]
    public var risk: ToolRisk
    public var workspacePath: String?

    public init(id: String = UUID().uuidString, name: String, arguments: [String: String], risk: ToolRisk, workspacePath: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.risk = risk
        self.workspacePath = workspacePath
    }
}

public struct ToolResult: Codable, Sendable {
    public var requestID: String
    public var content: String
    public var isError: Bool
    public var metadata: [String: String]
    /// Ephemeral visual output. Never put screenshot bytes in the workspace journal.
    public var imagePNG: Data?

    public var actionOutcome: ActionOutcome? {
        get { metadata["action_outcome"].flatMap(ActionOutcome.init(rawValue:)) }
        set { metadata["action_outcome"] = newValue?.rawValue }
    }

    public init(requestID: String, content: String, isError: Bool = false, metadata: [String: String] = [:], imagePNG: Data? = nil) {
        self.requestID = requestID
        self.content = content
        self.isError = isError
        self.metadata = metadata
        self.imagePNG = imagePNG
    }

    private enum CodingKeys: String, CodingKey { case requestID, content, isError, metadata }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        content = try container.decode(String.self, forKey: .content)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        imagePNG = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(content, forKey: .content)
        try container.encode(isError, forKey: .isError)
        try container.encode(metadata, forKey: .metadata)
    }
}

public protocol ToolExecutor: Sendable {
    var supportedTools: Set<String> { get }
    func execute(_ request: ToolRequest) async -> ToolResult
    func cancel(requestID: String) async
}

public struct ProcessCommand: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var timeout: Duration?
    public var inheritsEnvironment: Bool
    public var acceptsStandardInput: Bool

    public init(executable: URL, arguments: [String] = [], workingDirectory: URL? = nil, environment: [String: String] = [:], timeout: Duration? = nil, inheritsEnvironment: Bool = true, acceptsStandardInput: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.inheritsEnvironment = inheritsEnvironment
        self.acceptsStandardInput = acceptsStandardInput
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var wasTruncated: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, wasTruncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wasTruncated = wasTruncated
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> ProcessOutput
    func terminateAll() async
}

public protocol FileToolServing: ToolExecutor {}
public protocol GitToolServing: ToolExecutor {}
public protocol BrowserToolServing: ToolExecutor {}
public protocol DesktopToolServing: ToolExecutor {}
public protocol MCPToolServing: ToolExecutor {}
