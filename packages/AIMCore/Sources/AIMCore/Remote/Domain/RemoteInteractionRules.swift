import Foundation

public struct RemoteModelAnnouncement: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let isAdded: Bool?
    public let isPinned: Bool?
    public let isFeatured: Bool?
    public let detail: ChatModel?
    public let isReferencePricing: Bool?
    /// False retains a saved reference without authorizing execution on this Mac.
    public let isAvailable: Bool?
    public let via: String?
    public let capabilities: [String]
    public let effortLevels: [String]?
    public let currentEffort: String?

    public init(id: String, name: String, provider: String, via: String? = nil, capabilities: [String] = [], effortLevels: [String]? = nil, currentEffort: String? = nil, isAdded: Bool? = nil, isPinned: Bool? = nil, detail: ChatModel? = nil, isReferencePricing: Bool? = nil, isAvailable: Bool? = nil, isFeatured: Bool? = nil) {
        self.isFeatured = isFeatured; self.isAvailable = isAvailable; self.isAdded = isAdded; self.isPinned = isPinned; self.detail = detail; self.isReferencePricing = isReferencePricing
        self.id = id
        self.name = name
        self.provider = provider
        self.via = via
        self.capabilities = capabilities
        self.effortLevels = effortLevels
        self.currentEffort = currentEffort
    }

    private enum CodingKeys: String, CodingKey { case id, name, provider, via, capabilities, effort, isAdded, isPinned, detail, isReferencePricing, isAvailable, isFeatured }
    private struct Effort: Codable { let levels: [String]; let current: String? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable)
        isReferencePricing = try container.decodeIfPresent(Bool.self, forKey: .isReferencePricing)
        detail = try container.decodeIfPresent(ChatModel.self, forKey: .detail)
        isAdded = try container.decodeIfPresent(Bool.self, forKey: .isAdded)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
        isFeatured = try container.decodeIfPresent(Bool.self, forKey: .isFeatured)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(String.self, forKey: .provider)
        via = try container.decodeIfPresent(String.self, forKey: .via)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        let effort = try container.decodeIfPresent(Effort.self, forKey: .effort)
        effortLevels = effort?.levels
        currentEffort = effort?.current
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isAvailable, forKey: .isAvailable)
        try container.encodeIfPresent(isReferencePricing, forKey: .isReferencePricing)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(isAdded, forKey: .isAdded)
        try container.encodeIfPresent(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(isFeatured, forKey: .isFeatured)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(via, forKey: .via)
        try container.encode(capabilities, forKey: .capabilities)
        if let effortLevels {
            try container.encode(Effort(levels: effortLevels, current: currentEffort), forKey: .effort)
        }
    }
}

public struct RemoteEngineAnnouncement: Codable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let version: String?
    public let providers: [String]?
    public let features: [String: Bool]?

    public init(id: String, state: String, version: String? = nil, providers: [String]? = nil, features: [String: Bool]? = nil) {
        self.id = id
        self.state = state
        self.version = version; self.providers = providers; self.features = features
    }
}

public struct RemoteCapabilities: Codable, Equatable, Sendable {
    public let version: Int?
    public let models: [RemoteModelAnnouncement]
    public let engines: [RemoteEngineAnnouncement]
    public let features: [String: Bool]
    public let worker: RemoteWorkerAnnouncement?

    public init(version: Int? = nil, models: [RemoteModelAnnouncement] = [], engines: [RemoteEngineAnnouncement] = [], features: [String: Bool] = [:], worker: RemoteWorkerAnnouncement? = nil) {
        self.version = version
        self.models = models
        self.engines = engines
        self.features = features; self.worker = worker
    }
}

public extension RemoteCapabilities {
    enum Feature {
        public static let sessionManagement = "session_management"
        public static let history = "history"
        public static let structuredDiff = "structured_diff"
        public static let agentTerminal = "agent_terminal"
        public static let agentDiff = "agent_diff"
        public static let agentBrowser = "agent_browser"
    }

    func supports(_ feature: String) -> Bool {
        features[feature] == true
    }
}

public enum RemoteSessionSort: String, CaseIterable, Sendable {
    case priority
    case chronological
}

public enum RemoteSessionOrdering {
    public static func sorted(_ sessions: [RemoteSession], by sort: RemoteSessionSort) -> [RemoteSession] {
        switch sort {
        case .chronological:
            return sessions.sorted { $0.updatedAt > $1.updatedAt }
        case .priority:
            return sessions.sorted { lhs, rhs in
                let left = priority(for: lhs)
                let right = priority(for: rhs)
                if left != right { return left < right }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private static func priority(for session: RemoteSession) -> Int {
        if session.pendingApproval != nil || session.status == "running" || session.status == "waiting" { return 0 }
        if session.isPinned { return 1 }
        return 2
    }
}

public enum RemoteMenuEntryID: String, CaseIterable, Sendable {
    case plan, goal, files, camera, photos, connectors, context
}

public struct RemoteMenuEntry: Equatable, Sendable {
    public let id: RemoteMenuEntryID
    public let labelKey: String

    public init(id: RemoteMenuEntryID, labelKey: String) {
        self.id = id
        self.labelKey = labelKey
    }
}

public enum RemoteMenuRules {
    private static let all = [
        RemoteMenuEntry(id: .plan, labelKey: "remotePlusPlan"),
        RemoteMenuEntry(id: .goal, labelKey: "remotePlusGoal"),
        RemoteMenuEntry(id: .files, labelKey: "remotePlusFiles"),
        RemoteMenuEntry(id: .camera, labelKey: "remotePlusCamera"),
        RemoteMenuEntry(id: .photos, labelKey: "remotePlusPhotos"),
        RemoteMenuEntry(id: .connectors, labelKey: "remotePlusConnectors"),
        RemoteMenuEntry(id: .context, labelKey: "remotePlusContext"),
    ]

    public static func entries(attachments: Bool, mode: RemoteMode, goal: Bool = false) -> [RemoteMenuEntry] {
        all.filter { entry in
            if [.files, .camera, .photos].contains(entry.id), !attachments { return false }
            if entry.id == .goal, !goal { return false }
            if mode == .chat, entry.id == .plan || entry.id == .goal { return false }
            return true
        }
    }
}

public struct RemotePermissionOption: Equatable, Sendable {
    public let id: String
    public let labelKey: String
    public let descriptionKey: String
}

public enum RemotePermissionRules {
    private static let code = [
        RemotePermissionOption(id: "review", labelKey: "remotePermissionManual", descriptionKey: "remotePermissionCodeManualHint"),
        RemotePermissionOption(id: "accept", labelKey: "remotePermissionAcceptEdits", descriptionKey: "remotePermissionAcceptEditsHint"),
    ]
    private static let agent = [
        RemotePermissionOption(id: "always_ask", labelKey: "remotePermissionManual", descriptionKey: "remotePermissionAgentManualHint"),
        RemotePermissionOption(id: "smart", labelKey: "remotePermissionSmart", descriptionKey: "remotePermissionSmartHint"),
        RemotePermissionOption(id: "auto", labelKey: "remotePermissionAuto", descriptionKey: "remotePermissionAutoHint"),
    ]

    public static func options(for mode: RemoteMode) -> [RemotePermissionOption] {
        mode == .agent ? agent : code
    }

    public static func current(mode: RemoteMode, approvalMode: String?) -> (option: RemotePermissionOption?, labelKey: String) {
        let option = options(for: mode).first { $0.id == approvalMode }
        if option == nil, approvalMode == "plan" { return (nil, "remotePlanTitle") }
        return (option, option?.labelKey ?? "remotePermissionPrevious")
    }

    public static func modeAfterPlan(mode: RemoteMode, remembered: String?) -> String {
        if let remembered, options(for: mode).contains(where: { $0.id == remembered }) { return remembered }
        return mode == .agent ? "smart" : "review"
    }
}

public enum RemotePrimaryAction: Equatable, Sendable { case send, stop, resume }

public enum RemoteSessionRules {
    public static func primaryAction(status: String, interrupted: Bool, mode: RemoteMode) -> RemotePrimaryAction {
        if status == "running" { return .stop }
        if mode == .agent, interrupted { return .resume }
        return .send
    }

    public static func filter<T>(_ sessions: [T], machineID: String?, machineIDOf: (T) -> String) -> [T] {
        guard let machineID else { return sessions }
        return sessions.filter { machineIDOf($0) == machineID }
    }
}

public enum RemoteDiffLineKind: Equatable, Sendable {
    case fileHeader
    case hunkHeader
    case addition
    case deletion
    case context
    case metadata
}

public struct RemoteDiffLine: Equatable, Sendable {
    public let text: String
    public let kind: RemoteDiffLineKind

    public init(text: String, kind: RemoteDiffLineKind) {
        self.text = text
        self.kind = kind
    }
}

public enum RemoteDiffRules {
    public static func lines(in diff: String) -> [RemoteDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map { substring in
            let line = String(substring)
            let kind: RemoteDiffLineKind
            if line.hasPrefix("diff --git ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                kind = .fileHeader
            } else if line.hasPrefix("@@") {
                kind = .hunkHeader
            } else if line.hasPrefix("+") {
                kind = .addition
            } else if line.hasPrefix("-") {
                kind = .deletion
            } else if line.hasPrefix("\\ No newline") {
                kind = .metadata
            } else {
                kind = .context
            }
            return .init(text: line, kind: kind)
        }
    }
}

public struct RemoteAttachmentCandidate: Equatable, Sendable {
    public let name: String
    public let size: Int
    public let mimeType: String?

    public init(name: String, size: Int, mimeType: String? = nil) {
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

public enum RemoteAttachmentRejectionReason: Sendable { case empty, tooLarge, tooMany }
public struct RemoteAttachmentRejection: Equatable, Sendable { public let file: RemoteAttachmentCandidate; public let reason: RemoteAttachmentRejectionReason }
public struct RemoteAttachmentSort: Equatable, Sendable { public let accepted: [RemoteAttachmentCandidate]; public let rejected: [RemoteAttachmentRejection] }

public struct RemoteAttachmentReference: Codable, Equatable, Sendable {
    public let transferID: String
    public let name: String
    public let mimeType: String
    public let size: Int

    public init(transferID: String, name: String, mimeType: String, size: Int) {
        self.transferID = transferID
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }
}

public enum RemoteAttachmentRules {
    public static let maximumSize = 20 * 1_024 * 1_024
    public static let maximumCount = 4

    public static func sort(existingCount: Int, candidates: [RemoteAttachmentCandidate]) -> RemoteAttachmentSort {
        var accepted: [RemoteAttachmentCandidate] = []
        var rejected: [RemoteAttachmentRejection] = []
        var remaining = max(0, maximumCount - existingCount)
        for file in candidates {
            let reason: RemoteAttachmentRejectionReason?
            if file.size <= 0 { reason = .empty }
            else if file.size > maximumSize { reason = .tooLarge }
            else if remaining == 0 { reason = .tooMany }
            else { reason = nil }
            if let reason { rejected.append(.init(file: file, reason: reason)) }
            else { accepted.append(file); remaining -= 1 }
        }
        return .init(accepted: accepted, rejected: rejected)
    }

    public static func reference(transferID: String, file: RemoteAttachmentCandidate) -> RemoteAttachmentReference {
        .init(
            transferID: transferID,
            name: file.name.isEmpty ? "fichier" : file.name,
            mimeType: file.mimeType?.isEmpty == false ? file.mimeType ?? "application/octet-stream" : "application/octet-stream",
            size: file.size
        )
    }

    public static func messagePayload(text: String, attachments: [RemoteAttachmentReference]) -> RemoteJSONValue {
        var object: [String: RemoteJSONValue] = ["text": .string(text)]
        if !attachments.isEmpty {
            object["attachments"] = .array(attachments.map { item in
                .object([
                    "transfer_id": .string(item.transferID),
                    "name": .string(item.name),
                    "mime": .string(item.mimeType),
                    "size": .number(Double(item.size)),
                ])
            })
        }
        return .object(object)
    }

    public static func availableAtCreation(capabilities: RemoteCapabilities?, mode: RemoteMode) -> Bool {
        // Creation first reserves an empty remote session, then uploads the
        // selected files before publishing the initial message. The bridge's
        // ordinary attachment capability is therefore sufficient; requiring a
        // second optional flag hid Camera/Photos/Files from Chat on otherwise
        // compatible desktop versions.
        capabilities?.features["attachments"] == true
    }
}

public struct RemoteQuestionOption: Equatable, Sendable { public let label: String; public let description: String? }
public struct RemoteQuestion: Equatable, Sendable { public let question: String; public let options: [RemoteQuestionOption]; public let multi: Bool }

public enum RemoteQuestionRules {
    public static func pendingQuestions(from value: RemoteJSONValue) -> [RemoteQuestion]? {
        guard let object = value.objectValue, object["kind"]?.stringValue == "question", let rawQuestions = object["questions"]?.arrayValue else { return nil }
        return rawQuestions.prefix(6).compactMap { raw in
            guard let item = raw.objectValue else { return nil }
            let text = clean(item["question"]?.stringValue)
            guard !text.isEmpty else { return nil }
            let options = (item["options"]?.arrayValue ?? []).prefix(8).compactMap { rawOption -> RemoteQuestionOption? in
                guard let option = rawOption.objectValue else { return nil }
                let label = clean(option["label"]?.stringValue)
                guard !label.isEmpty else { return nil }
                let description = clean(option["description"]?.stringValue)
                return .init(label: label, description: description.isEmpty ? nil : description)
            }
            return .init(question: text, options: options, multi: item["multi"]?.boolValue == true)
        }
    }

    public static func composeAnswers(questions: [RemoteQuestion], choices: [[String]], texts: [String], skipped: [Bool]) -> String {
        func answer(at index: Int) -> String {
            if skipped.indices.contains(index), skipped[index] { return "(passée)" }
            let selected = choices.indices.contains(index) ? choices[index].joined(separator: ", ") : ""
            let free = texts.indices.contains(index) ? texts[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let values = [selected, free].filter { !$0.isEmpty }
            return values.isEmpty ? "(sans réponse)" : values.joined(separator: " — ")
        }
        if questions.count == 1 { return answer(at: 0) }
        return questions.enumerated().map { "\($0.offset + 1). \($0.element.question) → \(answer(at: $0.offset))" }.joined(separator: "\n")
    }

    private static func clean(_ value: String?) -> String {
        String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
    }
}

public struct RemoteEffortOption: Equatable, Sendable {
    public let value: String
    public let label: String
    public let isDefault: Bool
}

public struct RemoteEffortPresentation: Equatable, Sendable {
    public enum Kind: Sendable { case automatic, preview, real }
    public let kind: Kind
    public let options: [RemoteEffortOption]
    public let currentValue: String?
    public var isAutomatic: Bool { kind == .automatic }
}

public enum RemoteEffortRules {
    private static let openAI = options(["none", "low", "medium", "high", "xhigh", "max"], defaultValue: "medium")
    private static let claude = options(["low", "medium", "high", "xhigh", "max"], defaultValue: "medium")
    private static let grok = options(["low", "medium", "high"], defaultValue: "high")
    private static let labels = ["none": "Aucun", "low": "Faible", "medium": "Moyen", "high": "Élevé", "xhigh": "Extra", "max": "Max"]

    public static func preview(modelID: String?) -> RemoteEffortPresentation {
        let values: [RemoteEffortOption]
        switch modelID {
        case let id? where id.hasPrefix("gpt-5.6-"): values = openAI
        case "grok-4.5": values = grok
        case let id? where id.hasPrefix("claude-sonnet-5") || id.hasPrefix("claude-fable-5") || id.hasPrefix("claude-opus-"): values = claude
        default: return .init(kind: .automatic, options: [], currentValue: nil)
        }
        return .init(kind: .preview, options: values, currentValue: values.first(where: \.isDefault)?.value)
    }

    public static func effort(capabilities: RemoteCapabilities?, modelID: String?, provider: String? = nil) -> RemoteEffortPresentation {
        guard capabilities?.features["effort"] == true else { return preview(modelID: modelID) }
        let matches = capabilities?.models.filter { $0.id == modelID && (provider == nil || $0.provider == provider) } ?? []
        guard matches.count == 1, let model = matches.first, let levels = model.effortLevels else {
            return .init(kind: .automatic, options: [], currentValue: nil)
        }
        let catalog = (claude + openAI).reduce(into: [String: RemoteEffortOption]()) { result, option in
            result[option.value] = option
        }
        let filtered = levels.compactMap { value -> RemoteEffortOption? in
            guard var option = catalog[value] else { return nil }
            option = .init(value: option.value, label: option.label, isDefault: value == model.currentEffort)
            return option
        }
        guard !filtered.isEmpty else { return .init(kind: .automatic, options: [], currentValue: nil) }
        let current = filtered.contains(where: { $0.value == model.currentEffort }) ? model.currentEffort : filtered[0].value
        return .init(kind: .real, options: filtered, currentValue: current)
    }

    private static func options(_ values: [String], defaultValue: String) -> [RemoteEffortOption] {
        values.map { .init(value: $0, label: labels[$0] ?? $0, isDefault: $0 == defaultValue) }
    }
}

public struct RemoteModelDescriptor: Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let capabilities: [String]

    public init(id: String, name: String, provider: String, capabilities: [String] = []) {
        self.id = id; self.name = name; self.provider = provider; self.capabilities = capabilities
    }
}

public struct RemoteModelRow: Equatable, Sendable {
    public let id: String; public let name: String; public let provider: String; public let capabilities: [String]
    public let selectable: Bool; public let current: Bool; public let announced: Bool
}
public struct RemoteModelRows: Equatable, Sendable { public let rows: [RemoteModelRow]; public let capabilitiesKnown: Bool; public let currentAvailable: Bool? }

public enum RemoteModelRules {
    public static func rows(capabilities: RemoteCapabilities?, catalog: [RemoteModelDescriptor], current: RemoteModelDescriptor) -> RemoteModelRows {
        func row(_ model: RemoteModelDescriptor, selectable: Bool, isCurrent: Bool, announced: Bool) -> RemoteModelRow {
            .init(id: model.id, name: model.name, provider: model.provider, capabilities: model.capabilities, selectable: selectable, current: isCurrent, announced: announced)
        }
        guard let capabilities else { return .init(rows: [row(current, selectable: false, isCurrent: true, announced: false)], capabilitiesKnown: false, currentAvailable: nil) }
        var seen = Set<String>()
        let announced = capabilities.models.compactMap { item -> RemoteModelRow? in
            guard seen.insert(item.id).inserted else { return nil }
            let model = catalog.first(where: { $0.id == item.id }) ?? .init(id: item.id, name: item.name, provider: item.provider, capabilities: item.capabilities)
            return row(model, selectable: true, isCurrent: item.id == current.id, announced: true)
        }
        let available = announced.contains(where: \.current)
        return .init(rows: available ? announced : [row(current, selectable: false, isCurrent: true, announced: false)] + announced, capabilitiesKnown: true, currentAvailable: available)
    }
}

public enum RemoteEngineID: String, CaseIterable, Sendable { case aim, openclaw, hermes }
public struct RemoteEngine: Equatable, Sendable { public let id: RemoteEngineID; public let name: String; public let selectable: Bool; public let stateLabelKey: String? }

public enum RemoteEngineRules {
    /// Legacy AIM supports images; external bridges must explicitly advertise them.
    public static func supportsImageAttachments(agentID: String?, capabilities: RemoteCapabilities?) -> Bool {
        guard let agentID, agentID != "aim" else { return true }
        return capabilities?.engines.first(where: { $0.id == agentID })?.features?["imageAttachments"] == true
    }

    public static func engines(capabilities: RemoteCapabilities?) -> [RemoteEngine] {
        RemoteEngineID.allCases.map { id in
            let item = capabilities?.engines.first { $0.id == id.rawValue }
            let selectable = item.map { ["ready", "stopped"].contains($0.state) } ?? false
            let name = switch id { case .aim: "AIM Agent"; case .openclaw: "OpenClaw"; case .hermes: "Hermes Agent" }
            return .init(id: id, name: name, selectable: selectable, stateLabelKey: item?.state ?? "unknown")
        }
    }
}
