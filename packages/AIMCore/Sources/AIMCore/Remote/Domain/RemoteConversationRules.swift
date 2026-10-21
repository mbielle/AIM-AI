import Foundation

public enum RemoteMessageRole: String, Codable, Sendable { case user, assistant }

public struct RemoteLegacyToolCall: Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let status: String?
    public let result: String?
    public let warning: String?
    public let error: String?
    public let parameters: RemoteJSONValue?

    public init(id: String? = nil, name: String? = nil, status: String? = nil, result: String? = nil, warning: String? = nil, error: String? = nil, parameters: RemoteJSONValue? = nil) {
        self.id = id; self.name = name; self.status = status; self.result = result; self.warning = warning; self.error = error
        self.parameters = parameters
    }
}

public struct RemoteTimelineMessage: Equatable, Sendable {
    public let id: String
    public let role: RemoteMessageRole
    public let content: String
    public let reasoning: String?
    public let toolCalls: [RemoteLegacyToolCall]
    public let timeline: [RemoteJSONValue]?

    public init(id: String, role: RemoteMessageRole, content: String, reasoning: String? = nil, toolCalls: [RemoteLegacyToolCall] = [], timeline: [RemoteJSONValue]? = nil) {
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning; self.toolCalls = toolCalls; self.timeline = timeline
    }
}

public struct RemoteTimelineTool: Equatable, Sendable {
    public let id: String; public let name: String; public let status: String
    public let resultPreview: String?; public let localResult: String?; public let hasFullResult: Bool
    public let warning: String?; public let error: String?
    public let parameters: RemoteJSONValue?
    public let presentation: RemoteToolPresentation
    public let previewJPEG: Data?
    public let timestamp: Double?
    public let duration: Double?
    public let input: String?
    public let output: String?
    public let actionState: ConversationAction.State?
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(
        id: String,
        name: String,
        status: String,
        resultPreview: String? = nil,
        localResult: String? = nil,
        hasFullResult: Bool = false,
        warning: String? = nil,
        error: String? = nil,
        parameters: RemoteJSONValue? = nil,
        presentation: RemoteToolPresentation? = nil,
        previewJPEG: Data? = nil, timestamp: Double? = nil, duration: Double? = nil, input: String? = nil, output: String? = nil,
        actionState: ConversationAction.State? = nil, startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.id = id
        self.actionState = actionState; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.input = input.map { ConversationAction.redact($0) }; self.output = output.map { ConversationAction.redact($0) }
        self.previewJPEG = previewJPEG.flatMap { InputMediaPreview.validatedJPEG($0) ?? InputMediaPreview.jpeg($0) }; self.timestamp = timestamp; self.duration = duration
        self.name = name
        self.status = status
        self.resultPreview = resultPreview
        self.localResult = localResult
        self.hasFullResult = hasFullResult
        self.warning = warning
        self.error = error
        self.parameters = parameters
        self.presentation = presentation ?? RemoteToolPresentationRules.presentation(
            name: name,
            parameters: parameters,
            resultPreview: resultPreview,
            localResult: localResult
        )
    }

    /// Project wire snapshots without replacing missing dates by a new clock value
    /// or erasing terminal cancellations. The order belongs to the received timeline.
    public func observedAction(conversationID: UUID, turnID: UUID, ordinal: Int) -> ConversationAction {
        let state = actionState ?? (["running", "pending"].contains(status) ? .running
            : ["error", "failed"].contains(status) ? .failed
            : ["cancelled", "canceled"].contains(status) ? .cancelled
            : warning?.isEmpty == false ? .needsReview : .completed)
        let start = startedAt ?? Date(timeIntervalSince1970: 0)
        return ConversationAction(id: id, conversationID: conversationID, turnID: turnID, ordinal: ordinal,
            name: name, state: state, startedAt: start, finishedAt: finishedAt,
            detail: localResult ?? resultPreview, previewJPEG: previewJPEG, input: input, output: output ?? resultPreview)
    }
}

public enum RemoteToolPresentationKind: String, Codable, Equatable, Sendable {
    case command
    case createFile = "create_file"
    case editFile = "edit_file"
    case readFile = "read_file"
    case search
    case browser
    case generic
}

public struct RemoteToolPresentation: Equatable, Sendable {
    public let kind: RemoteToolPresentationKind
    public let title: String?
    public let subtitle: String?
    public let path: String?
    public let command: String?
    public let outputPreview: String?
    public let diff: String?
    public let additions: Int?
    public let deletions: Int?
    public let exitCode: Int?

    public init(kind: RemoteToolPresentationKind, title: String? = nil, subtitle: String? = nil, path: String? = nil, command: String? = nil, outputPreview: String? = nil, diff: String? = nil, additions: Int? = nil, deletions: Int? = nil, exitCode: Int? = nil) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.path = path
        self.command = command; self.outputPreview = outputPreview; self.diff = diff
        self.additions = additions; self.deletions = deletions; self.exitCode = exitCode
    }
}

public struct RemoteToolActivityGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let segments: [RemoteTimelineSegment]

    public init(id: String, segments: [RemoteTimelineSegment]) {
        self.id = id
        self.segments = segments
    }

    public var tools: [RemoteTimelineTool] {
        segments.compactMap { segment in
            guard case let .tool(_, tool) = segment else { return nil }
            return tool
        }
    }

    public var additions: Int? {
        let values = tools.compactMap(\.presentation.additions)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var deletions: Int? {
        let values = tools.compactMap(\.presentation.deletions)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

public enum RemoteTimelineSegment: Equatable, Sendable {
    case reasoning(id: String, text: String, running: Bool)
    case text(id: String, text: String, running: Bool)
    case tool(id: String, tool: RemoteTimelineTool)
    case approval(id: String, toolID: String, state: String, summary: String?)
    case status(id: String, state: String)

    public var id: String {
        switch self {
        case let .reasoning(id, _, _), let .text(id, _, _), let .tool(id, _), let .approval(id, _, _, _), let .status(id, _): id
        }
    }
    public var typeName: String {
        switch self { case .reasoning: "reasoning"; case .text: "text"; case .tool: "tool"; case .approval: "approval"; case .status: "status" }
    }
}

public enum RemoteTimelineDisplayItem: Equatable, Sendable {
    case segment(RemoteTimelineSegment)
    case toolGroup(RemoteToolActivityGroup)
}

public enum RemoteTimelineRules {
    public static func keepsLatestTurnExpanded(role: RemoteMessageRole, isLatest: Bool, sessionStatus: String) -> Bool {
        role == .assistant && isLatest && ["running", "waiting_approval"].contains(sessionStatus)
    }

    public static func displayTimeline(for message: RemoteTimelineMessage) -> [RemoteTimelineSegment] {
        if let timeline = message.timeline {
            let known = timeline.compactMap(decodeSegment)
            if !known.isEmpty {
                // A sparse action/status snapshot must not suppress separately stored assistant text.
                if !message.content.isEmpty, !known.contains(where: { if case .text = $0 { return true }; return false }) {
                    return [.text(id: "\(message.id):saved-text", text: message.content, running: false)] + known
                }
                return known
            }
        }
        var result: [RemoteTimelineSegment] = []
        if let reasoning = message.reasoning, !reasoning.isEmpty { result.append(.reasoning(id: "\(message.id):reasoning", text: reasoning, running: false)) }
        if !message.content.isEmpty || message.role == .user { result.append(.text(id: "\(message.id):text", text: message.content, running: false)) }
        for (index, call) in message.toolCalls.enumerated() {
            let toolID = call.id ?? "\(message.id):tool:\(index)"
            let preview = call.result.map { String($0.prefix(240)) }
            result.append(.tool(id: "\(message.id):tool:\(toolID)", tool: .init(id: toolID, name: call.name ?? "tool", status: call.status ?? "done", resultPreview: preview, localResult: call.result, hasFullResult: false, warning: call.warning, error: call.error, parameters: call.parameters)))
        }
        if message.role == .assistant {
            let state = message.toolCalls.contains(where: { $0.status == "pending" }) ? "waiting_approval" : message.toolCalls.contains(where: { $0.status == "error" }) ? "error" : "complete"
            result.append(.status(id: "\(message.id):status", state: state))
        }
        return result
    }

    public static func group(_ segments: [RemoteTimelineSegment]) -> [RemoteTimelineDisplayItem] {
        var result: [RemoteTimelineDisplayItem] = []
        var pendingTools: [RemoteTimelineSegment] = []

        func flushTools() {
            guard let first = pendingTools.first else { return }
            result.append(.toolGroup(.init(id: "group:\(first.id)", segments: pendingTools)))
            pendingTools.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            if case .tool = segment {
                pendingTools.append(segment)
            } else {
                flushTools()
                result.append(.segment(segment))
            }
        }
        flushTools()
        return result
    }

    private static func decodeSegment(_ value: RemoteJSONValue) -> RemoteTimelineSegment? {
        guard let object = value.objectValue, let id = object["id"]?.stringValue, let type = object["type"]?.stringValue else { return nil }
        if type == "reasoning" || type == "text", let text = object["text"]?.stringValue {
            return type == "reasoning" ? .reasoning(id: id, text: text, running: object["state"]?.stringValue == "running") : .text(id: id, text: text, running: object["state"]?.stringValue == "running")
        }
        if type == "tool", let tool = object["tool"]?.objectValue, let toolID = tool["id"]?.stringValue, let name = tool["name"]?.stringValue {
            let parameters = tool["params"]
            let resultPreview = tool["resultPreview"]?.stringValue
            let localResult = tool["localResult"]?.stringValue
            let presentation = RemoteToolPresentationRules.presentation(
                name: name,
                parameters: parameters,
                resultPreview: resultPreview,
                localResult: localResult,
                explicit: tool["presentation"]?.objectValue
            )
            return .tool(id: id, tool: .init(id: toolID, name: name, status: tool["status"]?.stringValue ?? "done", resultPreview: resultPreview, localResult: localResult, hasFullResult: tool["hasFullResult"]?.boolValue == true, warning: tool["warning"]?.stringValue, error: tool["error"]?.stringValue, parameters: parameters, presentation: presentation, previewJPEG: tool["previewJPEG"]?.stringValue.flatMap { Data(base64Encoded: $0) }, timestamp: tool["timestamp"]?.numberValue, duration: tool["duration"]?.numberValue, input: tool["input"]?.stringValue, output: tool["output"]?.stringValue, actionState: tool["actionState"]?.stringValue.flatMap(ConversationAction.State.init(rawValue:)), startedAt: tool["startedAt"]?.numberValue.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }, finishedAt: tool["finishedAt"]?.numberValue.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }))
        }
        if type == "approval", let toolID = object["toolId"]?.stringValue, let state = object["state"]?.stringValue, ["pending", "approved", "rejected"].contains(state) {
            return .approval(id: id, toolID: toolID, state: state, summary: object["summary"]?.stringValue)
        }
        if type == "status", let state = object["state"]?.stringValue, ["running", "complete", "waiting_approval", "interrupted", "error"].contains(state) {
            return .status(id: id, state: state)
        }
        return nil
    }
}

public enum RemoteToolPresentationRules {
    public static func presentation(
        name: String,
        parameters: RemoteJSONValue?,
        resultPreview: String?,
        localResult: String?,
        explicit: [String: RemoteJSONValue]? = nil
    ) -> RemoteToolPresentation {
        let params = parameters?.objectValue ?? [:]
        let lowered = name.lowercased()
        let explicitKind = explicit?["kind"]?.stringValue.flatMap(RemoteToolPresentationKind.init(rawValue:))
        let kind = explicitKind ?? inferredKind(lowered)
        let command = string(explicit, ["command"]) ?? string(params, ["command", "cmd", "script"])
        let path = string(explicit, ["path"]) ?? string(params, ["path", "file", "filePath", "filename"])
        let output = string(explicit, ["outputPreview", "output_preview"]) ?? localResult ?? resultPreview
        let candidateDiff = string(explicit, ["diff"]) ?? string(params, ["diff", "patch"])
            ?? ([localResult, resultPreview].compactMap { $0 }.first(where: { $0.contains("@@") || $0.hasPrefix("diff --git") }))
        let counts = candidateDiff.map(diffCounts)
        return .init(
            kind: kind,
            title: string(explicit, ["title"]),
            subtitle: string(explicit, ["subtitle"]),
            path: path,
            command: command,
            outputPreview: output,
            diff: candidateDiff,
            additions: integer(explicit, ["additions"]) ?? counts?.additions,
            deletions: integer(explicit, ["deletions"]) ?? counts?.deletions,
            exitCode: integer(explicit, ["exitCode", "exit_code"])
        )
    }

    public static func diffCounts(_ diff: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    private static func inferredKind(_ name: String) -> RemoteToolPresentationKind {
        if name.contains("command") || name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("exec") { return .command }
        if name.contains("create") || name.contains("write") { return .createFile }
        if name.contains("edit") || name.contains("patch") || name.contains("apply") { return .editFile }
        if name.contains("read") && name.contains("file") { return .readFile }
        if name.contains("search") || name.contains("find") || name.contains("grep") { return .search }
        if name.contains("browser") || name.contains("web") || name.contains("url") { return .browser }
        return .generic
    }

    private static func string(_ object: [String: RemoteJSONValue]?, _ keys: [String]) -> String? {
        guard let object else { return nil }
        return keys.lazy.compactMap { object[$0]?.stringValue }.first
    }

    private static func integer(_ object: [String: RemoteJSONValue]?, _ keys: [String]) -> Int? {
        guard let object else { return nil }
        return keys.lazy.compactMap { object[$0]?.numberValue.map(Int.init) }.first
    }
}

public struct RemoteTurnMessage: Equatable, Sendable {
    public let role: RemoteMessageRole
    public let content: String?
    public let timeline: [RemoteJSONValue]?

    public init(role: RemoteMessageRole, content: String? = nil, timeline: [RemoteJSONValue]? = nil) {
        self.role = role; self.content = content; self.timeline = timeline
    }
}

public struct RemoteEndOfTurn: Equatable, Sendable {
    public let actions: Bool; public let disclaimer: Bool; public let text: String
    public init(actions: Bool, disclaimer: Bool, text: String) { self.actions = actions; self.disclaimer = disclaimer; self.text = text }
}

public struct RemoteStreamState: Equatable, Sendable {
    public let isComplete: Bool; public let conversationID: String?
    public init(isComplete: Bool, conversationID: String? = nil) { self.isComplete = isComplete; self.conversationID = conversationID }
}

public enum RemoteResponseRules {
    public static func endOfTurn(messages: [RemoteTurnMessage], index: Int, status: String?) -> RemoteEndOfTurn {
        let turn = assistantTurnAction(messages: messages, index: index)
        let inProgress = ["running", "waiting_approval"].contains(status ?? "")
        let last = index == messages.count - 1
        return .init(actions: turn.visible && !(last && inProgress), disclaimer: turn.visible && disclaimer(messages: messages, index: index, generationInProgress: inProgress), text: turn.text)
    }

    public static func disclaimer(messages: [RemoteTurnMessage], index: Int, generationInProgress: Bool) -> Bool {
        !generationInProgress && index == messages.count - 1 && messages.indices.contains(index) && messages[index].role == .assistant
    }

    public static func chatGenerationInProgress(isLoading: Bool, stream: RemoteStreamState?, conversationID: String?) -> Bool {
        if isLoading { return true }
        guard let stream, !stream.isComplete else { return false }
        return stream.conversationID == nil || stream.conversationID == conversationID
    }

    private static func assistantTurnAction(messages: [RemoteTurnMessage], index: Int) -> (visible: Bool, text: String) {
        guard messages.indices.contains(index), messages[index].role == .assistant else { return (false, "") }
        if messages.indices.contains(index + 1), messages[index + 1].role == .assistant { return (false, "") }
        var first = index
        while first > 0, messages[first - 1].role == .assistant { first -= 1 }
        let text = messages[first...index].compactMap(messageText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (!text.isEmpty, text)
    }

    private static func messageText(_ message: RemoteTurnMessage) -> String? {
        if let timeline = message.timeline {
            let text = timeline.compactMap { item -> String? in
                guard let object = item.objectValue, object["type"]?.stringValue == "text", let value = object["text"]?.stringValue else { return nil }
                return clean(value)
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !text.isEmpty { return text }
        }
        return clean(message.content ?? "")
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<tool_call>[\\s\\S]*?</tool_call>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<tool_call>[\\s\\S]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RemoteConversationSearch {
    public static func normalize(_ value: String, locale: Locale = .current) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }

    public static func matchingMessageIDs(
        query: String,
        messages: [RemoteMessage],
        locale: Locale = .current
    ) -> [String] {
        let needle = normalize(query, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return messages.filter { message in
            normalize(message.content, locale: locale).contains(needle)
                || message.reasoning.map { normalize($0, locale: locale).contains(needle) } == true
        }.map(\.id)
    }
}
