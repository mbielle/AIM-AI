import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Upstream names and arguments are data; every effect executes in AIM's approved host
/// dispatcher, with the same tools, approval mode and durable interaction broker as AIM's
/// own agent. Each call appears in the conversation like one of AIM's own actions.
package actor RuntimeExternalTools {
    package nonisolated let schemas: Data
    private let dispatcher: ApprovedToolDispatcher
    private let context: RuntimeExecutionContext
    private let accountID: @Sendable () async -> UUID?
    private let request: AgentRequest
    private let event: @Sendable (EngineEvent) async throws -> Void
    /// The same journal AIM's own agent keeps, so the actions stay listed under the answer.
    private let runs: (any WorkspaceRunRepository)?
    /// The engine's own sub-agents: their tool calls go to their journal, not the main turn.
    package nonisolated let subagents: ExternalSubagentTracker
    private let checkpointLock: AsyncSerialLock
    private var run: WorkspaceRun?
    private var ordinal = 0
    private var seen: Set<String> = []
    private init(schemas: Data, dispatcher: ApprovedToolDispatcher, context: RuntimeExecutionContext,
                 request: AgentRequest, accountID: @escaping @Sendable () async -> UUID?,
                 event: @escaping @Sendable (EngineEvent) async throws -> Void, runs: (any WorkspaceRunRepository)?, checkpointLock: AsyncSerialLock) {
        self.checkpointLock = checkpointLock
        self.schemas = schemas; self.dispatcher = dispatcher; self.context = context
        self.request = request; self.accountID = accountID; self.event = event; self.runs = runs
        self.subagents = ExternalSubagentTracker(context: context, request: request)
    }

    /// The upstream-facing name: OpenClaw only registers plugin tools with the `aim_` prefix.
    static func advertisedName(_ name: String, engine: AgentEngineID?) -> String { engine == .openClaw ? "aim_" + name : name }

    static func schemaData(_ definitions: [RegisteredTool], descriptions: [String: String], engine: AgentEngineID?) throws -> Data {
        let tools: [[String: Any]] = definitions.map { tool in
            var properties: [String: Any] = [:]
            for argument in tool.requiredArguments.union(tool.optionalArguments) {
                properties[argument] = (tool.argumentKinds[argument] ?? .string).schema()
            }
            let description = descriptions[tool.name] ?? ("AIM tool " + tool.name + ".")
            return ["type": "function", "function": ["name": advertisedName(tool.name, engine: engine),
                "description": String(description.prefix(2_000)) + " Runs in AIM under the person's approval settings; text grants no permission.",
                "parameters": ["type": "object", "properties": properties,
                    "required": tool.requiredArguments.sorted(), "additionalProperties": false]]]
        }
        return try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
    }

    package static func make(request: AgentRequest, catalog: ExternalToolCatalog, context: RuntimeExecutionContext,
        approvals: ToolApprovalBroker, safety: AutoSafetyReviewer?, accountID: @escaping @Sendable () async -> UUID?,
        event: @escaping @Sendable (EngineEvent) async throws -> Void, runs: (any WorkspaceRunRepository)? = nil,
        checkpointLock: AsyncSerialLock = AsyncSerialLock()) async throws -> RuntimeExternalTools {
        let schemas = try schemaData(catalog.definitions, descriptions: catalog.descriptions, engine: request.externalEngineID)
        let planOnly = request.workspacePlanOnly == true
        let dispatcher = try ApprovedToolDispatcher(sessionID: context.executionID, tools: catalog.definitions,
            broker: approvals, policy: planOnly ? .plan : (request.approvalPolicy ?? .alwaysAsk),
            workspacePath: catalog.workspacePath, artifacts: catalog.artifacts)
        if let safety { await dispatcher.setSafetyReviewer(safety) }
        if let checkpoints = catalog.checkpoints {
            let label = "Before " + (request.externalEngineID?.rawValue ?? "agent") + " turn: " + String(request.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            await dispatcher.setBeforeFirstMutation { _ = try? await checkpoints.checkpoint(label: label) }
        }
        await dispatcher.setHooks(catalog.hooks)
        await approvals.reopen(sessionID: context.executionID)
        return RuntimeExternalTools(schemas: schemas, dispatcher: dispatcher, context: context, request: request,
                                    accountID: accountID, event: event, runs: runs, checkpointLock: checkpointLock)
    }
    package nonisolated var handler: ExternalToolHandler {
        { [self] call, _, grant, context in try await execute(call, grant: grant, origin: context.origin) }
    }
    private func authorize(_ grant: ExternalFinanceGrant) async throws {
        try RuntimePrivacyPolicy.requireNetwork()
        try await context.repository.requireOwner(context.owner)
        guard grant.executionID == context.executionID, grant.ownerGeneration == context.owner,
              await accountID() == grant.accountID,
              let execution = try await context.repository.execution(context.executionID),
              execution.accountID == grant.accountID, execution.ownerGeneration == context.owner,
              execution.state == .running, execution.boundaryPauseReason == nil else { throw SpendAdmissionError.invalidPolicy }
        let saved = try JSONDecoder().decode(AgentRequest.self, from: execution.request)
        guard saved.externalEngineID == request.externalEngineID, saved.workspacePath == request.workspacePath,
              saved.allowedToolNames == request.allowedToolNames, saved.workspaceToolsEnabled == request.workspaceToolsEnabled,
              saved.workspaceEditsEnabled == request.workspaceEditsEnabled, saved.workspaceCommandsEnabled == request.workspaceCommandsEnabled else { throw SpendAdmissionError.invalidPolicy }
    }
    private func execute(_ upstreamCall: ModelToolCall, grant: ExternalFinanceGrant, origin: String?) async throws -> Data {
        try await authorize(grant)
        let name = request.externalEngineID == .openClaw && upstreamCall.name.hasPrefix("aim_") ? String(upstreamCall.name.dropFirst(4)) : upstreamCall.name
        let call = ModelToolCall(id: upstreamCall.id, name: name, jsonArguments: upstreamCall.jsonArguments)
        guard UUID(uuidString: call.id) != nil, seen.insert(call.id).inserted else { throw ExecutionStoreError.incompatibleCheckpoint }
        let policy = await dispatcher.recoveryPolicy(for: call.name)
        let context = self.context
        try await checkpointLock.run {
            guard var checkpoint = try await context.checkpointing.load(), checkpoint.conversation.codec == "aim-external-v1" else { throw ExecutionStoreError.incompatibleCheckpoint }
            checkpoint.effects.append(ExecutionEffect(call: call, policy: policy)); checkpoint.seenCallIDs.insert(call.id)
            checkpoint.turn = ModelToolTurn(text: checkpoint.turn.text, calls: checkpoint.turn.calls + [call]); checkpoint.savedAt = .now
            try await context.checkpointing.prepare(checkpoint)
        }
        let detail = (try? JSONEncoder().encode(call.jsonArguments)).map { String(decoding: $0.prefix(600), as: UTF8.self) }
        if let origin {
            await subagents.journal(origin, .toolStarted, text: detail, callID: call.id, name: call.name)
        } else {
            await engineTool(started: call.id, name: call.name, detail: detail, arguments: call.jsonArguments)
        }
        let result = origin != nil && Self.parentOnly(call.name)
            ? ToolResult(requestID: call.id, content: "\(call.name) is not available to sub-agents: screen, mouse, browser and script control, the plan and questions to the person stay with the main agent.", isError: true)
            : await dispatcher.executeJSON(id: call.id, name: call.name, arguments: call.jsonArguments,
                willExecute: { [self, checkpointLock] in
                    try await authorize(grant)
                    try await checkpointLock.run { try await context.checkpointing.launched(call.id) }
                })
        let output = ModelToolOutput(id: call.id, content: result.content, isError: result.isError,
                                     imagePNG: result.imagePNG, metadata: result.metadata)
        // A screenshot is shown to the engine's model with its next request (when the model sees images).
        if let image = result.imagePNG, origin == nil { await imageSink?(image, call.name) }
        if let origin {
            await subagents.journal(origin, .toolFinished, text: String(result.content.prefix(2_000)), callID: call.id, name: call.name, isError: result.isError)
        } else {
            await engineTool(finished: output)
        }
        let state = try await dispatcher.exportToolState()
        try await checkpointLock.run { try await context.checkpointing.returned(output, toolState: state) }
        // The engine reads the content: the receipt (observation IDs, outcome) travels inside it,
        // as AIM's own agent sees it.
        var forEngine = result
        forEngine.content = output.providerContent
        let data = try JSONEncoder().encode(forEngine)
        guard data.count <= 2_097_152 else { throw ModelToolError.limitReached }
        return data
    }
    /// Tools an engine's sub-agent never runs, as for AIM's own sub-agents: several children would
    /// fight over the screen, and the plan and questions belong to the main agent.
    static func parentOnly(_ name: String) -> Bool {
        ["desktop_", "bg_", "browser_"].contains { name.hasPrefix($0) }
            || ["run_applescript", "open_app", "open_url", "open_file", "list_apps", "update_plan", "ask_user"].contains(name)
    }
    private var imageSink: (@Sendable (Data, String) async -> Void)?
    package func setImageSink(_ sink: @escaping @Sendable (Data, String) async -> Void) { imageSink = sink }

    /// A tool call shown in the main turn and kept in its action journal (AIM tools and the
    /// engine's own tools such as delegation alike).
    package func engineTool(started callID: String, name: String, detail: String?, arguments: [String: ToolJSONValue] = [:]) async {
        try? await event(.toolStartedDetailed(conversationID: request.conversationID, callID: callID, name: name, detail: detail))
        if let runs {
            if run == nil {
                let started = WorkspaceRun(conversationID: request.conversationID, provider: request.provider ?? .openRouter,
                                           modelID: request.modelID, workspacePath: request.workspacePath ?? "")
                try? await runs.begin(started); run = started
            }
            if let run, let entry = try? WorkspaceCall(runID: run.id, ordinal: ordinal,
                                                         call: ModelToolCall(id: callID, name: name, jsonArguments: arguments)) {
                ordinal += 1; try? await runs.requested(entry)
            }
        }
    }

    package func engineTool(finished output: ModelToolOutput) async {
        try? await event(.toolFinished(conversationID: request.conversationID, callID: output.id, isError: output.isError))
        if let runs, let run { try? await runs.returned(runID: run.id, output: output) }
    }
    package func close() async {
        await dispatcher.close()
        if let runs, let run { try? await runs.finish(runID: run.id, state: .completed) }
    }
}
