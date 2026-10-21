import AIMCore
import AIMApplication
import Foundation

/// Classification is implemented by trusted host executors, never supplied by the model.
public protocol ToolRiskClassifying: ToolExecutor {
    func risk(for arguments: [String: String]) -> ToolRisk
    func risk(for name: String, arguments: [String: String]) -> ToolRisk
}

public extension ToolRiskClassifying {
    func risk(for name: String, arguments: [String: String]) -> ToolRisk {
        risk(for: arguments)
    }
}

/// Optional trusted resolution of an operation and its actual resource.
/// Unsupported tools cannot gain automatic approval from a mission scope.
/// Lets an executor refuse a request before any approval is shown (e.g. a
/// catastrophic shell command), so the person is never asked to approve it.
public protocol ToolPreflighting: ToolExecutor {
    func preflightRefusal(_ request: ToolRequest) -> String?
}

public protocol MissionIntentProviding: ToolExecutor {
    func missionIntent(for request: ToolRequest) async throws -> MissionToolIntent?
}

/// Services that retain work after a tool call returns must stop it when the
/// owning run closes. A returned process handle must not outlive its run.
public protocol ToolSessionClosing: ToolExecutor {
    func closeSession() async
}

/// Definitions are registered by the application, not accepted from model output or MCP replies.
public struct RegisteredTool: Sendable {
    public let name: String
    public let risk: ToolRisk
    public let requiredArguments: Set<String>
    public let optionalArguments: Set<String>
    public let argumentKinds: [String: ToolArgumentKind]
    public let allowsSessionDecision: Bool
    /// Reserved for trusted host control tools such as ask_user, not model-created tools.
    public let approvalExempt: Bool
    public let executor: any ToolExecutor
    public let sourcePluginID: String?

    public init(name: String, risk: ToolRisk, requiredArguments: Set<String> = [], optionalArguments: Set<String> = [],
                argumentKinds: [String: ToolArgumentKind] = [:], allowsSessionDecision: Bool = false,
                approvalExempt: Bool = false, sourcePluginID: String? = nil, executor: any ToolExecutor) {
        self.name = name; self.risk = risk; self.requiredArguments = requiredArguments
        self.optionalArguments = optionalArguments; self.argumentKinds = argumentKinds
        self.allowsSessionDecision = allowsSessionDecision
        self.approvalExempt = approvalExempt
        self.executor = executor; self.sourcePluginID = sourcePluginID
    }
}

public enum ToolRegistrationError: Error { case duplicateOrUnsupportedTool, invalidWorkspace }

/// Per-run dispatcher: optional caller budget, fixed policy/workspace, no model-supplied risk.
public actor ApprovedToolDispatcher {
    public nonisolated let sessionID: UUID
    private let tools: [String: RegisteredTool]
    private let broker: ToolApprovalBroker
    private let policy: ApprovalPolicy
    private let workspace: String?
    private let maximumCalls: Int?
    private let artifacts: ToolArtifactStore?
    private let missionRepository: (any AgentMissionRepository)?
    private let missionID: UUID?
    private var attempts = 0
    private var seenIDs: Set<String> = []
    private var active: [String: any ToolExecutor] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    public init(sessionID: UUID = UUID(), tools: [RegisteredTool], broker: ToolApprovalBroker,
                policy: ApprovalPolicy, workspacePath: String?, maximumCalls: Int? = nil,
                artifacts: ToolArtifactStore? = nil,
                missionRepository: (any AgentMissionRepository)? = nil, missionID: UUID? = nil) throws {
        var definitions: [String: RegisteredTool] = [:]
        for tool in tools {
            guard definitions[tool.name] == nil, tool.executor.supportedTools.contains(tool.name),
                  Set(tool.argumentKinds.keys).isSubset(of: tool.requiredArguments.union(tool.optionalArguments)) else {
                throw ToolRegistrationError.duplicateOrUnsupportedTool
            }
            definitions[tool.name] = tool
        }
        if let workspacePath {
            guard workspacePath.hasPrefix("/"), !workspacePath.contains("\0") else { throw ToolRegistrationError.invalidWorkspace }
            self.workspace = URL(fileURLWithPath: workspacePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        } else { self.workspace = nil }
        self.sessionID = sessionID; self.tools = definitions; self.broker = broker
        self.policy = policy; self.maximumCalls = maximumCalls.map { max(1, $0) }
        self.artifacts = artifacts
        self.missionRepository = missionRepository
        self.missionID = missionID
    }

    public func execute(id: String, name: String, arguments: [String: String],
                        willExecute: (@Sendable () async throws -> Void)? = nil) async -> ToolResult {
        guard ToolPayloadLimits.validArguments(arguments) else {
            return ToolResult(requestID: id, content: "Invalid or oversized tool arguments.", isError: true)
        }
        let kinds = tools[name]?.argumentKinds ?? [:]
        var values: [String: ToolJSONValue] = [:]
        for (key, value) in arguments {
            guard let parsed = (kinds[key] ?? .string).parseLegacy(value) else {
                return ToolResult(requestID: id, content: "Invalid tool argument type.", isError: true)
            }
            values[key] = parsed
        }
        return await executeJSON(id: id, name: name, arguments: values, willExecute: willExecute)
    }

    /// Unknown/dynamic-risk tools cannot be replayed merely because their name sounds safe.
    public func recoveryPolicy(for name: String) -> ToolRecoveryPolicy {
        if let service = tools[name]?.executor as? any DurableToolExecutor { return service.recoveryPolicy(for: name) }
        guard let definition = tools[name], definition.risk == .readOnly,
              !(definition.executor is any ToolRiskClassifying) else { return .neverReplay }
        return .readOnly
    }

    public func exportToolState() async throws -> [String: Data] {
        var result: [String: Data] = [:]; var seen: Set<ObjectIdentifier> = []
        for name in tools.keys.sorted() {
            guard let service = tools[name]?.executor as? any DurableToolExecutor,
                  seen.insert(ObjectIdentifier(service)).inserted else { continue }
            result[name] = try await service.exportToolState()
        }
        return result
    }
    public func restoreToolState(_ state: [String: Data]) async throws {
        for (name, bytes) in state {
            guard let service = tools[name]?.executor as? any DurableToolExecutor else { throw ExecutionStoreError.incompatibleCheckpoint }
            try await service.restoreToolState(bytes, workspacePath: workspace)
        }
    }

    /// Read-only tools with a fixed risk that never prompt under this policy may
    /// run concurrently with other such calls of the same model turn.
    public func isParallelSafe(_ name: String) -> Bool {
        guard let tool = tools[name], tool.risk == .readOnly, !(tool.executor is any ToolRiskClassifying),
              !(tool.executor is any ToolPreflighting), policy != .alwaysAsk || tool.approvalExempt else { return false }
        return true
    }

    /// Runs once, before the first file-changing tool of this dispatcher (one Agent turn)
    /// executes — e.g. a workspace checkpoint. A failure never blocks the action.
    private var beforeFirstMutation: (@Sendable () async -> Void)?
    public func setBeforeFirstMutation(_ hook: (@Sendable () async -> Void)?) { beforeFirstMutation = hook }

    private var hooks: (any ToolHookRunning)?
    /// Auto's safety agent for commands; without it Auto asks for every unverified command.
    private var safetyReviewer: AutoSafetyReviewer?
    public func setSafetyReviewer(_ reviewer: AutoSafetyReviewer?) { safetyReviewer = reviewer }
    public func setHooks(_ hooks: (any ToolHookRunning)?) { self.hooks = hooks }

    public func executeJSON(id: String, name: String, arguments: [String: ToolJSONValue],
                            willExecute: (@Sendable () async throws -> Void)? = nil) async -> ToolResult {
        func failure(_ message: String) -> ToolResult { ToolResult(requestID: id, content: message, isError: true) }
        guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
        if let maximumCalls {
            guard attempts < maximumCalls else { return failure("The configured tool-call budget was reached.") }
            attempts += 1
        }
        guard !id.isEmpty, id.utf8.count <= 256, seenIDs.insert(id).inserted else { return failure("Invalid or repeated tool call ID.") }
        guard let tool = tools[name] else {
            return failure(name == "run_tool_program" ? "run_tool_program must be the only call of its step. Nothing was run; call it again alone."
                                                      : "Unknown tool.")
        }
        func pluginEnabled() -> Bool {
            guard let plugin = tool.sourcePluginID else { return true }
            let defaults = AIMInstallationContext.sharedPreferences
            defaults.synchronize()
            return (defaults.stringArray(forKey: AgentPluginRegistry.enabledKey) ?? []).contains(plugin)
        }
        guard pluginEnabled() else { return failure("This extension was revoked. No action was executed.") }
        if RuntimePrivacyPolicy.isEnabled && (tool.risk == .externalEffect || tool.risk == .computerAction || name.hasPrefix("web_") || name.hasPrefix("mcp_") || name.hasPrefix("plugin_")) {
            return failure("Private Agent mode blocks external tools. Disable it explicitly before requesting this action.")
        }
        guard let normalized = try? ToolArgumentValidation.normalized(arguments,
            required: tool.requiredArguments, optional: tool.optionalArguments, kinds: tool.argumentKinds) else {
            // The model gets what it needs to call again correctly; nothing was executed.
            let required = tool.requiredArguments.sorted().joined(separator: ", ")
            let optional = tool.optionalArguments.sorted().joined(separator: ", ")
            let unknown = Set(arguments.keys).subtracting(tool.requiredArguments.union(tool.optionalArguments)).sorted()
            let missing = tool.requiredArguments.subtracting(arguments.keys).sorted()
            var text = "Invalid arguments for \(name); nothing was executed. Required: \(required.isEmpty ? "none" : required)."
            if !optional.isEmpty { text += " Optional: \(optional)." }
            if !missing.isEmpty { text += " Missing: \(missing.joined(separator: ", "))." }
            if !unknown.isEmpty { text += " Not accepted: \(unknown.joined(separator: ", "))." }
            return failure(text + " Call it again with valid arguments.")
        }
        let adapted = normalized.reduce(into: [String: String]()) { values, pair in
            if let text = pair.value.legacyString { values[pair.key] = text }
        }
        guard ToolPayloadLimits.validArguments(adapted) else {
            return failure("These arguments are too large (over 2 MB) or contain a null character. Nothing was run; split the content into several smaller calls.")
        }
        // Plan is an execution prohibition, not an approval prompt that could authorize writes.
        let risk = (tool.executor as? any ToolRiskClassifying)?.risk(for: name, arguments: adapted) ?? tool.risk
        if RuntimePrivacyPolicy.isEnabled && (risk == .externalEffect ||
            (["run_command", "start_command", "write_command"].contains(name) && risk != .readOnly)) {
            return failure("Private Agent mode cannot attest this action's network isolation. No action was executed.")
        }
        guard policy != .plan || (risk == .readOnly || risk == .computerRead) else { return failure("Plan mode forbids this action. No changes were made.") }
        let request = ToolRequest(id: id, name: name, arguments: adapted, risk: risk, workspacePath: workspace)
        if let refusal = (tool.executor as? any ToolPreflighting)?.preflightRefusal(request) { return failure(refusal) }
        if !RuntimePrivacyPolicy.isEnabled, let hooks, let reason = await hooks.beforeTool(name: name, arguments: adapted, workspace: workspace) {
            return failure("Blocked by the person's PreToolUse hook: \(reason). No action was executed.")
        }
        let authorization: MissionAuthorization?
        do {
            if let missionRepository, let missionID {
                guard let mission = try await missionRepository.load(id: missionID),
                      Self.missionAllowsActions(mission) else {
                    return failure("The mission is no longer active. No action was executed.")
                }
                authorization = try await missionRepository.authorization(missionID: missionID)
            } else { authorization = nil }
        } catch { return failure("Could not read the mission authorization. No action was executed.") }
        let intent: MissionToolIntent?
        do {
            intent = try await (tool.executor as? any MissionIntentProviding)?.missionIntent(for: request)
        } catch { return failure("Could not verify the tool target against the mission authorization. No action was executed.") }
        let covered = intent.map { authorization?.covers($0) == true } ?? false
        let exactApprovalRequired = intent?.needs.contains { $0.operation.requiresExactApproval } == true
        let priorUncertainAction: Bool
        do {
            if let missionRepository, let missionID {
                priorUncertainAction = try await missionRepository.wasUncertainAction(
                    missionID: missionID, name: name, arguments: normalized)
            } else { priorUncertainAction = false }
        } catch {
            return failure("Could not check the previous action history. No action was executed.")
        }
        let review: ToolReview?
        do { review = try await (tool.executor as? any ToolReviewProviding)?.review(request) }
        catch { return failure("The edit proposal is unavailable. Prepare a new proposal before retrying.") }
        guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
        // Auto skips ordinary local mutations, but an exact edit preview is a separate
        // sensitive review. Destructive tools, including unsandboxed shell, also ask.
        let sensitiveReview = review.map { review in
            review.path.split(separator: "/").contains { component in
                let value = component.lowercased()
                return value.hasPrefix(".") || ["package.json", "package-lock.json", "makefile", "dockerfile", "package.swift"].contains(value)
            } || !review.afterExists
        } ?? false
        let scopeRequiresApproval = exactApprovalRequired || (authorization != nil && !covered && risk != .readOnly)
        let scopeAllowsAuto = policy == .autoApprove && covered && !exactApprovalRequired &&
            risk != .destructive && risk != .sensitiveRead
        var safetyCheck: String?
        if !tool.approvalExempt && (priorUncertainAction || sensitiveReview || scopeRequiresApproval ||
                                    (!scopeAllowsAuto && policy.requiresApproval(for: risk))) {
            let category = await (tool.executor as? any ToolApprovalCategorizing)?.approvalCategory(for: request)
                ?? ToolApprovalCategory.of(request)
            let isCommand = name == "run_command" || name == "start_command"
            let command = isCommand ? request.arguments["command"] : nil
            let rule = command.map { AutoSafetyReviewer.rules(command: $0, workspace: workspace) }
            let risky: Bool = { if case .risky = rule { return true }; return false }()
            // A standing decision ("this conversation", "always") names a whole action type, so it
            // is never offered for actions that must be confirmed one by one.
            let standing = !exactApprovalRequired && !priorUncertainAction && review == nil && !risky &&
                risk != .sensitiveRead && risk != .missionDefinition && (risk != .destructive || isCommand) &&
                !["command", "computer", "mission", "mcp:"].contains(category.key)
            var note: String?
            var decided = false
            // Auto: the safety agent lets safe commands run and explains the ones it brings to the person.
            if policy == .autoApprove, let command, !priorUncertainAction, !scopeRequiresApproval, review == nil {
                let standingAllows = standing ? await broker.isAllowed(category: category, sessionID: sessionID) : false
                if !standingAllows {
                    switch await (safetyReviewer ?? AutoSafetyReviewer(judge: nil)).decide(command: command, workspace: workspace) {
                    case let .allow(reason): safetyCheck = reason; decided = true
                    case let .ask(reason): note = reason
                    }
                }
            } else if risky, case let .risky(reason)? = rule { note = reason }
            guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
            if !decided {
                let allowed = await broker.request(request, sessionID: sessionID,
                    allowsSessionDecision: !exactApprovalRequired && !priorUncertainAction && review == nil &&
                        tool.allowsSessionDecision && tool.risk < .externalEffect,
                    review: review, priorUncertainAction: priorUncertainAction,
                    category: category, standing: standing, safetyNote: note)
                guard allowed else { return failure("Tool action was denied or cancelled.") }
            }
        }
        guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
        if missionRepository != nil && missionID != nil {
            guard await authorizationStillValid(authorization, intent: intent, request: request,
                                                executor: tool.executor) else {
                return failure("Mission authorization or target changed before launch. No action was executed.")
            }
        }
        // Persist the launch boundary after approval, before any effect. An intent
        // with no launch marker can safely be distinguished from an uncertain effect.
        do { try await willExecute?() }
        catch { return ToolResult(requestID: id, content: "Could not persist the tool launch. No action was executed.",
                                  isError: true, metadata: ["journal_failure": "true"]) }
        guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
        if missionRepository != nil && missionID != nil {
            guard await authorizationStillValid(authorization, intent: intent, request: request,
                                                executor: tool.executor) else {
                return failure("Mission authorization or target changed before execution. No action was executed.")
            }
        }
        if (risk == .localMutation || risk == .destructive), let hook = beforeFirstMutation {
            beforeFirstMutation = nil
            await hook()
            guard !closed, !Task.isCancelled else { return failure("Tool session is closed or cancelled.") }
        }
        // Recheck after approval/hooks: enabling privacy while a request waits
        // must take effect before its launch, independently of model output.
        guard !RuntimePrivacyPolicy.isEnabled || (risk != .externalEffect && risk != .computerAction &&
            !name.hasPrefix("web_") && !name.hasPrefix("mcp_") && !name.hasPrefix("plugin_") &&
            !(["run_command", "start_command", "write_command"].contains(name) && risk != .readOnly)) else {
            return failure("Private Agent mode was enabled before execution. No action was executed.")
        }
        guard pluginEnabled() else { return failure("This extension was revoked before launch. No action was executed.") }
        active[id] = tool.executor
        defer { finish(id) }
        var result = await withTaskCancellationHandler {
            await tool.executor.execute(request)
        } onCancel: { Task { await tool.executor.cancel(requestID: id) } }
        guard !closed, !Task.isCancelled else { return failure("Tool execution was cancelled; inspect the workspace before retrying any mutation.") }
        guard result.requestID == id else { return failure("Tool returned an invalid result ID.") }
        guard result.metadata.count <= 32,
              result.metadata.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16 * 1_024 else {
            return failure("Tool returned oversized metadata.")
        }
        if let image = result.imagePNG {
            guard image.count <= 6_000_000,
                  image.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                return failure("Tool returned an invalid or oversized screenshot.")
            }
        }
        if let safetyCheck { result.metadata["safety_check"] = String(safetyCheck.prefix(500)) }
        // Credentials never reach the model, whatever tool surfaced them.
        let redacted = SecretRedactor.redact(result.content)
        if redacted.count > 0 {
            result.content = redacted.text + "\n[AIM replaced \(redacted.count) secret-looking value(s) with \(SecretRedactor.marker).]"
            result.metadata["secrets_redacted"] = String(redacted.count)
        }
        if !RuntimePrivacyPolicy.isEnabled, let hooks, let note = await hooks.afterTool(name: name, arguments: request.arguments, result: result, workspace: workspace) {
            result.content += "\n[PostToolUse hook]\n" + SecretRedactor.redact(String(note.prefix(4_000))).text
        }
        // Outputs are untrusted context, not instructions or new approval authority.
        let limit = ToolPayloadLimits.resultTextBytes
        if result.content.utf8.count > limit {
            var shortened = result
            // Keep the start and the end: errors and summaries usually come last.
            let bytes = result.content.utf8
            let head = limit * 3 / 4, tail = limit / 4
            shortened.content = String(decoding: bytes.prefix(head), as: UTF8.self)
                + "\n[… \(bytes.count - head - tail) bytes omitted …]\n"
                + String(decoding: bytes.suffix(tail), as: UTF8.self) + "\n[Tool output truncated]"
            shortened.metadata["truncated"] = "true"
            if let artifacts {
                do {
                    let reference = try await artifacts.save(result.content)
                    shortened.metadata["artifact_id"] = reference
                    shortened.content += "\nFull text saved as artifact \(reference). Read it with read_tool_artifact."
                } catch {
                    // The effect may already have happened. Preserve this fact and
                    // the visual result; never misreport a failed action or retry it.
                    shortened.isError = true
                    shortened.metadata["artifact_save_failed"] = "true"
                    shortened.metadata["original_is_error"] = String(result.isError)
                    shortened.content += "\nFull output could not be saved. The action may have executed; inspect before retrying."
                }
            }
            return shortened
        }
        return result
    }

    public func close() async {
        let running = closed ? [:] : active
        closed = true
        await broker.close(sessionID: sessionID)
        for (id, executor) in running { await executor.cancel(requestID: id) }
        for tool in tools.values {
            if let owner = tool.executor as? any ToolSessionClosing {
                await owner.closeSession()
            }
        }
        if !active.isEmpty { await withCheckedContinuation { closeWaiters.append($0) } }
    }

    private func finish(_ id: String) {
        active.removeValue(forKey: id)
        if active.isEmpty {
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func authorizationStillValid(_ expected: MissionAuthorization?, intent: MissionToolIntent?,
                                         request: ToolRequest, executor: any ToolExecutor) async -> Bool {
        guard let missionRepository, let missionID else { return expected == nil }
        do {
            guard let mission = try await missionRepository.load(id: missionID),
                  Self.missionAllowsActions(mission) else { return false }
            let current = try await missionRepository.authorization(missionID: missionID)
            guard current?.revision == expected?.revision,
                  (current?.revokedAt != nil) == (expected?.revokedAt != nil) else { return false }
            let currentIntent = try await (executor as? any MissionIntentProviding)?.missionIntent(for: request)
            return currentIntent == intent
        } catch { return false }
    }

    private nonisolated static func missionAllowsActions(_ mission: AgentMission) -> Bool {
        switch mission.state {
        case .preparing, .executing, .partial: true
        case .awaitingUser, .suspendedHuman, .suspendedFinancial, .blocked, .verified, .failed, .cancelled: false
        }
    }
}
