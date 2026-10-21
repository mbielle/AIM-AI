import Foundation

/// One observed step of a sub-agent, kept in its parent's durable journal so the person can
/// follow it: what the parent asked, the child's reasoning summaries, text and tool calls,
/// and the notes it sent back. Text is bounded and secrets are masked before storage.
public struct SubagentJournalEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case parentMessage, reasoning, text, toolStarted, toolFinished, noteToParent }
    public var childID: UUID
    public var kind: Kind
    public var text: String?
    public var callID: String?
    public var name: String?
    public var isError: Bool?
    /// A fragment of streamed text or reasoning: it joins the previous one without a break.
    public var streamed: Bool?
    public var at: Date
    public static let textLimit = 16_384
    /// The parent journal event kind holding one encoded entry.
    public static let eventKind = "childJournal"

    public init(childID: UUID, kind: Kind, text: String? = nil, callID: String? = nil, name: String? = nil, isError: Bool? = nil,
                streamed: Bool? = nil, at: Date = .now) {
        self.childID = childID; self.kind = kind; self.callID = callID; self.name = name; self.isError = isError; self.at = at
        self.streamed = streamed
        self.text = text.map { ConversationAction.redact($0, limit: Self.textLimit) }
    }
}

/// A sub-agent's journal as a conversation: the parent's messages, then the child's turn
/// timeline (reasoning, text and actions in order), notes to the parent shown as actions.
public struct SubagentTranscript: Sendable {
    public enum Item: Sendable, Identifiable {
        case parentMessage(id: String, text: String, at: Date)
        case turn(id: String, layout: TurnLayout<ConversationAction>)
        public var id: String { switch self { case let .parentMessage(id, _, _), let .turn(id, _): id } }
    }
    public var items: [Item]
    public var actions: [ConversationAction]

    public init(childID: UUID, prompt: String, startedAt: Date, entries: [SubagentJournalEntry], running: Bool, now: Date = .now) {
        var items: [Item] = [.parentMessage(id: "prompt", text: prompt, at: startedAt)]
        var actions: [ConversationAction] = []
        var builder = TurnTimelineBuilder(startedAt: startedAt)
        var content = ""
        var started = false
        var turnActionIDs: Set<String> = []
        func flush(final: Bool) {
            guard started else { return }
            if final { builder.finish(at: entries.last?.at ?? now) }
            items.append(.turn(id: "turn:\(items.count)", layout: TurnLayout.make(content: content, timeline: builder.timeline, tools: actions.filter { turnActionIDs.contains($0.id) },
                                                                                  key: \.id, running: running && !final, now: now)))
        }
        for (index, entry) in entries.enumerated() where entry.childID == childID {
            switch entry.kind {
            case .parentMessage:
                flush(final: true)
                items.append(.parentMessage(id: "parent:\(index)", text: entry.text ?? "", at: entry.at))
                builder = TurnTimelineBuilder(startedAt: entry.at); content = ""; started = false; turnActionIDs = []
            case .reasoning:
                started = true; builder.reasoning(entry.text ?? "", at: entry.at)
            case .text:
                // Streamed fragments join as written; older whole-step entries end a paragraph.
                started = true; let piece = (entry.text ?? "") + (entry.streamed == true ? "" : "\n\n")
                builder.text(piece, at: entry.at); content += piece
            case .toolStarted, .noteToParent:
                started = true
                let id = entry.callID ?? "call:\(index)"
                let name = entry.kind == .noteToParent ? "message_parent" : entry.name ?? "tool"
                builder.action(id, at: entry.at); turnActionIDs.insert(id)
                actions.append(ConversationAction(id: id, conversationID: childID, turnID: childID, ordinal: actions.count, name: name,
                    // A call still open when the child stopped has an unknown effect, never "done".
                    state: entry.kind == .noteToParent ? .completed : (running ? .running : .needsReview), startedAt: entry.at,
                    finishedAt: entry.kind == .noteToParent ? entry.at : nil, input: entry.text))
            case .toolFinished:
                guard let index = actions.firstIndex(where: { $0.id == entry.callID }) else { continue }
                actions[index].state = entry.isError == true ? .failed : .completed
                actions[index].finishedAt = entry.at
                if let text = entry.text { actions[index].output = text }
            }
        }
        flush(final: !running)
        self.items = items
        self.actions = actions
    }
}
