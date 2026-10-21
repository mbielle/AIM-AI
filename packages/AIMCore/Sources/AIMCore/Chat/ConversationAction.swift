import Foundation

/// Public, observed execution events. This is not a model reasoning transcript.
public struct ConversationAction: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case running, waiting, completed, failed, cancelled, needsReview }
    public var id: String
    public var conversationID: UUID
    public var turnID: UUID
    public var ordinal: Int
    public var name: String
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?
    public var detail: String?
    public var input: String?
    public var output: String?
    public var mediaID: UUID?
    public var timestamp: Double?
    public var detailReference: String?
    public var previewJPEG: Data?
    public var duration: Double? { finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    public init(id: String, conversationID: UUID, turnID: UUID, ordinal: Int, name: String, state: State,
                startedAt: Date = .now, finishedAt: Date? = nil, detail: String? = nil,
                mediaID: UUID? = nil, timestamp: Double? = nil, detailReference: String? = nil, previewJPEG: Data? = nil, input: String? = nil, output: String? = nil) {
        self.input = input.map { Self.redact($0) }; self.output = output.map { Self.redact($0) }
        self.id = id; self.conversationID = conversationID; self.turnID = turnID; self.ordinal = ordinal
        self.name = name; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.detail = detail.map { Self.redact($0) }; self.mediaID = mediaID; self.timestamp = timestamp; self.detailReference = detailReference
        self.previewJPEG = previewJPEG.flatMap { InputMediaPreview.validatedJPEG($0) ?? InputMediaPreview.jpeg($0) }
    }
    public static func merge(_ left: [Self]?, _ right: [Self]?) -> [Self]? {
        guard left != nil || right != nil else { return nil }
        var result: [String: Self] = [:]
        for value in (left ?? []) + (right ?? []) {
            if let old = result[value.id] {
                guard old.conversationID == value.conversationID, old.turnID == value.turnID else { continue }
                if old.finishedAt != nil && value.finishedAt == nil { continue }
                if let prior = old.finishedAt, let incoming = value.finishedAt, prior > incoming { continue }
            }
            var safe = value; safe.detail = value.detail.map { redact($0) }; safe.input = value.input.map { redact($0) } ?? result[value.id]?.input; safe.output = value.output.map { redact($0) } ?? result[value.id]?.output; result[value.id] = safe
        }
        return result.values.sorted { $0.ordinal == $1.ordinal ? ($0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt) : $0.ordinal < $1.ordinal }
    }
    public static func redact(_ source: String, limit: Int = 16_384) -> String {
        let rules: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/-]+"#, "$1[redacted]"),
            (#"(?i)((?:["']?)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|client[_-]?secret|secret)(?:["']?)\s*[=:]\s*)"(?:\\.|[^"\\])*""#, "$1\"[redacted]\""),
            (#"(?i)((?:["']?)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|client[_-]?secret|secret)(?:["']?)\s*[=:]\s*)'[^']*'"#, "$1'[redacted]'"),
            (#"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|client[_-]?secret|secret)\s*[=:]\s*)[^\s,;]+"#, "$1[redacted]"),
            (#"(?i)((?:["']?)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|client[_-]?secret|secret)(?:["']?)\s*[=:]\s*)"[^"\n]*$"#, "$1\"[redacted]\""),
            (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "[redacted]")
        ]
        return rules.reduce(String(source.prefix(max(0, min(limit, 1_000_000))))) { text, rule in
            text.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }
    /// Read-only pages are cut after redaction, so a secret spanning two pages
    /// cannot leak through either half. Offsets refer to this safe snapshot.
    public static func detailPage(_ source: String, offset: Int) -> RemoteJSONValue? {
        guard (0...1_000_000).contains(offset) else { return nil }
        let safe = redact(source, limit: 1_000_000)
        guard offset <= safe.count else { return nil }
        let text = String(safe.dropFirst(offset).prefix(16_384))
        let next = offset + text.count
        return .object(["output": .string(text), "offset": .number(Double(offset)),
            "next_offset": next < safe.count ? .number(Double(next)) : .null,
            "source_truncated": .bool(source.count > 1_000_000)])
    }
    public static func remoteTimeline(_ actions: [Self]?, content: String, sources: [ConversationSource]? = nil, turn: TurnTimeline? = nil) -> RemoteJSONValue? {
        guard !(actions ?? []).isEmpty || !(sources ?? []).isEmpty || turn != nil else { return nil }
        var values: [RemoteJSONValue] = []
        if let turn {
            // Reasoning, text and actions in the order they happened; older clients read the same segment types.
            let layout = TurnLayout.make(content: content, timeline: turn, tools: actions ?? [], key: \.id)
            for item in layout.all {
                switch item {
                case let .reasoning(id, text, duration, _):
                    values.append(.object(["id": .string(id), "type": .string("reasoning"), "text": .string(redact(text)), "state": .string("done"),
                                           "duration": duration.map { .number($0) } ?? .null]))
                case let .text(id, text): values.append(.object(["id": .string(id), "type": .string("text"), "text": .string(text)]))
                case let .tools(_, group): values += group.map(remoteTool)
                case .subagents: break
                }
            }
            values.append(.object(["id": .string("turn"), "type": .string("turn"), "duration": layout.duration.map { .number($0) } ?? .null]))
        } else {
            values = (actions ?? []).map(remoteTool)
        }
        values += (sources ?? []).map { source in .object(["id": .string(source.id), "type": .string("source"), "url": .string(source.url), "title": .string(source.title), "references": .array((source.references ?? []).map { .number(Double($0)) })]) }
        if turn == nil, !content.isEmpty { values.append(.object(["id": .string("answer"), "type": .string("text"), "text": .string(content)])) }
        return .array(values)
    }

    private static func remoteTool(_ value: Self) -> RemoteJSONValue {
        .object(["id": .string(value.id), "type": .string("tool"), "tool": .object([
            "id": .string(value.id), "name": .string(value.name),
            // Optional fidelity for new clients; legacy status stays compatible.
            "actionState": .string(value.state.rawValue),
            "startedAt": .number(value.startedAt.timeIntervalSince1970),
            "finishedAt": value.finishedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "status": .string(value.state == .running || value.state == .waiting ? "running" : value.state == .failed ? "error" : "done"),
            "input": value.input.map { .string(redact($0)) } ?? .null,
            "output": value.output.map { .string(redact($0)) } ?? .null,
            "resultPreview": .string(redact(value.output ?? value.detail ?? "")),
            "localResult": value.detailReference == nil ? .string(redact(value.detail ?? "")) : .null,
            "duration": value.duration.map { .number($0) } ?? .null,
            "mediaID": value.mediaID.map { .string($0.uuidString) } ?? .null,
            "timestamp": value.timestamp.map { .number($0) } ?? .null,
            "previewJPEG": value.previewJPEG.flatMap { InputMediaPreview.validatedJPEG($0) ?? InputMediaPreview.jpeg($0) }.map { .string($0.base64EncodedString()) } ?? .null, "hasFullResult": .bool(value.detailReference == nil),
            "warning": .string(value.state == .needsReview ? "Effect unknown · inspect before retrying" : "")])])
    }

}
