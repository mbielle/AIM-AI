import Foundation

/// Where each part of an assistant turn happened: reasoning summaries, the text written
/// between actions, the actions themselves and the sub-agents started. Text is referenced
/// by Unicode scalar offsets into the message content, which only grows while streaming,
/// so the timeline never duplicates or rewrites the answer. Optional everywhere: messages
/// without a timeline (older ones) keep their previous presentation.
public struct TurnTimeline: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// `reasoning`, `text`, `action` or `subagents`; unknown kinds are ignored.
        public var kind: String
        public var text: String?
        public var start: Int?
        public var end: Int?
        public var actionID: String?
        public var subagentIDs: [String]?
        public var startedAt: Date?
        public var endedAt: Date?
        public init(id: String, kind: String, text: String? = nil, start: Int? = nil, end: Int? = nil, actionID: String? = nil,
                    subagentIDs: [String]? = nil, startedAt: Date? = nil, endedAt: Date? = nil) {
            self.id = id; self.kind = kind; self.text = text; self.start = start; self.end = end; self.actionID = actionID
            self.subagentIDs = subagentIDs; self.startedAt = startedAt; self.endedAt = endedAt
        }
    }
    public var entries: [Entry]
    public var startedAt: Date
    public var endedAt: Date?
    public init(entries: [Entry] = [], startedAt: Date = .now, endedAt: Date? = nil) {
        self.entries = entries; self.startedAt = startedAt; self.endedAt = endedAt
    }

    public var duration: TimeInterval? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }

    /// Keeps the more complete side: a finished timeline wins over a running copy, otherwise
    /// the one with more entries (sync never shortens a turn).
    public static func merge(_ left: Self?, _ right: Self?) -> Self? {
        guard let left else { return right }
        guard let right else { return left }
        if (left.endedAt != nil) != (right.endedAt != nil) { return left.endedAt != nil ? left : right }
        return right.entries.count >= left.entries.count ? right : left
    }
}

/// Records a turn as events arrive. Value type: the owner keeps it beside the draft message.
public struct TurnTimelineBuilder: Sendable {
    public private(set) var timeline: TurnTimeline
    private var scalars = 0
    private var counter = 0

    public init(startedAt: Date = .now, existingContent: String = "") {
        timeline = TurnTimeline(startedAt: startedAt)
        scalars = existingContent.unicodeScalars.count
    }

    public mutating func reasoning(_ text: String, at date: Date = .now) {
        guard !text.isEmpty else { return }
        if let last = timeline.entries.indices.last, timeline.entries[last].kind == "reasoning", timeline.entries[last].endedAt == nil {
            timeline.entries[last].text = (timeline.entries[last].text ?? "") + text
            return
        }
        timeline.entries.append(.init(id: nextID("reasoning"), kind: "reasoning", text: text, startedAt: date))
    }

    public mutating func text(_ text: String, at date: Date = .now) {
        let count = text.unicodeScalars.count
        guard count > 0 else { return }
        closeReasoning(at: date)
        if let last = timeline.entries.indices.last, timeline.entries[last].kind == "text" {
            timeline.entries[last].end = scalars + count
        } else {
            timeline.entries.append(.init(id: nextID("text"), kind: "text", start: scalars, end: scalars + count, startedAt: date))
        }
        scalars += count
    }

    public mutating func action(_ actionID: String, at date: Date = .now) {
        closeReasoning(at: date)
        guard !timeline.entries.contains(where: { $0.actionID == actionID }) else { return }
        timeline.entries.append(.init(id: nextID("action"), kind: "action", actionID: actionID, startedAt: date))
    }

    public mutating func subagents(_ ids: [String], at date: Date = .now) {
        let fresh = ids.filter { id in !timeline.entries.contains { $0.subagentIDs?.contains(id) == true } }
        guard !fresh.isEmpty else { return }
        closeReasoning(at: date)
        if let last = timeline.entries.indices.last, timeline.entries[last].kind == "subagents" {
            timeline.entries[last].subagentIDs = (timeline.entries[last].subagentIDs ?? []) + fresh
        } else {
            timeline.entries.append(.init(id: nextID("subagents"), kind: "subagents", subagentIDs: fresh, startedAt: date))
        }
    }

    public mutating func finish(at date: Date = .now) {
        closeReasoning(at: date)
        if timeline.endedAt == nil { timeline.endedAt = date }
    }

    private mutating func closeReasoning(at date: Date) {
        if let last = timeline.entries.indices.last, timeline.entries[last].kind == "reasoning", timeline.entries[last].endedAt == nil {
            timeline.entries[last].endedAt = date
        }
    }

    private mutating func nextID(_ kind: String) -> String { counter += 1; return "\(kind):\(counter)" }
}

/// What a tool did, independent of its exact name, for group titles and icons.
public enum ToolActivityCategory: String, CaseIterable, Sendable {
    case search, find, browse, read, edit, command, image, subagent, note, network, route, other

    public static func classify(_ name: String) -> Self {
        let name = name.lowercased()
        if name == "network" { return .network }
        if name.hasPrefix("provider ·") { return .route }
        if name == "message_parent" || name == "message_subagent" { return .note }
        if name.contains("subagent") || name == "delegate_task" { return .subagent }
        if name.contains("image") || name == "visual_analysis" || name.contains("screenshot") { return .image }
        if name.contains("web") && name.contains("search") { return .search }
        if name.contains("search") || name.contains("grep") || name.contains("find") || name.contains("glob") { return .find }
        if name.contains("browser") || name.contains("fetch") || name.contains("url") || name.contains("web") { return .browse }
        if name.contains("command") || name.contains("bash") || name.contains("shell") || name.contains("terminal") || name.contains("exec") { return .command }
        if name.contains("edit") || name.contains("write") || name.contains("patch") || name.contains("create") || name.contains("apply") { return .edit }
        if name.contains("read") || name.contains("list") || name.contains("file") || name.contains("open") { return .read }
        return .other
    }

    /// SF Symbol shared by both apps.
    public var symbol: String {
        switch self {
        case .search, .find: "magnifyingglass"
        case .note: "bubble.left"
        case .browse: "globe"
        case .read: "doc.text"
        case .edit: "pencil"
        case .command: "terminal"
        case .image: "photo"
        case .subagent: "person.2"
        case .network: "wifi"
        case .route: "arrow.triangle.branch"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// One displayable part of a turn.
public enum TurnLayoutItem<Tool: Sendable>: Sendable {
    case reasoning(id: String, text: String, duration: TimeInterval?, running: Bool)
    case text(id: String, text: String)
    case tools(id: String, tools: [Tool])
    case subagents(id: String, ids: [String])

    public var id: String {
        switch self {
        case let .reasoning(id, _, _, _), let .text(id, _), let .tools(id, _), let .subagents(id, _): id
        }
    }
    public var isText: Bool { if case .text = self { return true }; return false }
}

/// A turn split into its work (reasoning, actions, intermediate text) and its final answer.
public struct TurnLayout<Tool: Sendable>: Sendable {
    public var work: [TurnLayoutItem<Tool>]
    public var answer: [TurnLayoutItem<Tool>]
    public var duration: TimeInterval?
    /// Everything in order, for the live view and the expanded history.
    public var all: [TurnLayoutItem<Tool>] { work + answer }
    public var hasWork: Bool { !work.isEmpty }
    public var onlyReasoning: Bool { !work.isEmpty && work.allSatisfy { if case .reasoning = $0 { return true }; return false } }

    public static func make(content: String, timeline: TurnTimeline?, tools: [Tool], key: (Tool) -> String,
                            running: Bool = false, now: Date = .now) -> Self {
        guard let timeline else {
            let work: [TurnLayoutItem<Tool>] = tools.isEmpty ? [] : [.tools(id: "tools:legacy", tools: tools)]
            return .init(work: work, answer: content.isEmpty ? [] : [.text(id: "text:legacy", text: content)], duration: nil)
        }
        let scalars = Array(content.unicodeScalars)
        // Actions are stored as "web:<call>", "<run>:<call>" or "<message>:route:<n>" while the
        // timeline records the engine's call ID; an exact key wins, then a ":"-separated suffix.
        let keys = tools.map(key)
        func resolve(_ id: String) -> Int? { keys.firstIndex(of: id) ?? keys.firstIndex { $0.hasSuffix(":" + id) } }
        var resolved: [String: Int] = [:]
        for id in timeline.entries.compactMap(\.actionID) { if let index = resolve(id) { resolved[id] = index } }
        let referenced = Set(resolved.values)
        var items: [TurnLayoutItem<Tool>] = []
        let unplaced = tools.indices.filter { !referenced.contains($0) }.map { tools[$0] }
        if !unplaced.isEmpty { items.append(.tools(id: "tools:unplaced", tools: unplaced)) }
        var covered = 0
        // Text ranges recorded for a longer text than the one saved (an answer stored without its
        // working notes) would cut words: then the saved text is shown whole, after the work.
        let consistent = timeline.entries.allSatisfy { $0.kind != "text" || ($0.end ?? $0.start ?? 0) <= scalars.count }
        if !consistent { covered = scalars.count }
        for entry in timeline.entries {
            if !consistent, entry.kind == "text" { continue }
            switch entry.kind {
            case "reasoning":
                let end = entry.endedAt ?? (running ? now : timeline.endedAt)
                items.append(.reasoning(id: entry.id, text: entry.text ?? "",
                                        duration: entry.startedAt.flatMap { start in end.map { max(0, $0.timeIntervalSince(start)) } },
                                        running: running && entry.endedAt == nil))
            case "text":
                let start = min(max(0, entry.start ?? covered), scalars.count), end = min(max(start, entry.end ?? start), scalars.count)
                covered = max(covered, end)
                let piece = String(String.UnicodeScalarView(scalars[start..<end]))
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appendText(piece, id: entry.id, to: &items) }
            case "action":
                guard let id = entry.actionID, let index = resolved[id] else { continue }
                let tool = tools[index]
                if case let .tools(groupID, group)? = items.last { items[items.count - 1] = .tools(id: groupID, tools: group + [tool]) }
                else { items.append(.tools(id: "tools:" + entry.id, tools: [tool])) }
            case "subagents":
                if let ids = entry.subagentIDs, !ids.isEmpty { items.append(.subagents(id: entry.id, ids: ids)) }
            default: continue
            }
        }
        if covered < scalars.count {
            let rest = String(String.UnicodeScalarView(scalars[covered...]))
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appendText(rest, id: "text:rest", to: &items) }
        }
        if !consistent, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(.text(id: "text:saved", text: content))
        }
        let duration = timeline.endedAt.map { max(0, $0.timeIntervalSince(timeline.startedAt)) } ?? (running ? now.timeIntervalSince(timeline.startedAt) : nil)
        return split(items, duration: duration)
    }

    /// Everything after the last non-text part is the answer. A turn that ended on an action
    /// (stopped, or still waiting) keeps its last words visible as the answer.
    private static func split(_ items: [TurnLayoutItem<Tool>], duration: TimeInterval?) -> Self {
        let split = (items.lastIndex { !$0.isText }).map { $0 + 1 } ?? 0
        var work = Array(items[..<split]), answer = Array(items[split...])
        if answer.isEmpty, let last = work.lastIndex(where: \.isText) { answer = [work.remove(at: last)] }
        return .init(work: work, answer: answer, duration: duration)
    }

    /// The same split for parts already in order (a Remote timeline): adjacent texts and
    /// actions are merged, everything after the last non-text part is the answer.
    public static func ordered(_ pieces: [TurnLayoutItem<Tool>], duration: TimeInterval?) -> Self {
        var items: [TurnLayoutItem<Tool>] = []
        for piece in pieces {
            switch (piece, items.last) {
            case let (.tools(_, more), .tools(id, group)?): items[items.count - 1] = .tools(id: id, tools: group + more)
            case let (.text(id, text), _): appendText(text, id: id, to: &items)
            default: items.append(piece)
            }
        }
        return split(items, duration: duration)
    }

    private static func appendText(_ piece: String, id: String, to items: inout [TurnLayoutItem<Tool>]) {
        if case let .text(previousID, previous)? = items.last { items[items.count - 1] = .text(id: previousID, text: previous + piece) }
        else { items.append(.text(id: id, text: piece)) }
    }
}

/// Short titles in the app's language (English or French).
public enum TurnLayoutText {
    public static func french(_ locale: Locale = .current) -> Bool { locale.language.languageCode?.identifier == "fr" }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    /// The collapsed header: "Thought for 8 s" when only reasoning happened, else "Worked for …".
    public static func header(onlyReasoning: Bool, duration seconds: TimeInterval?, running: Bool, locale: Locale = .current) -> String {
        let fr = french(locale)
        if running { return onlyReasoning ? (fr ? "Réflexion…" : "Thinking…") : (fr ? "Travail en cours…" : "Working…") }
        guard let seconds else { return onlyReasoning ? (fr ? "Réflexion" : "Thoughts") : (fr ? "Activité" : "Activity") }
        if onlyReasoning { return (fr ? "Réfléchi pendant " : "Thought for ") + duration(seconds) }
        return (fr ? "Travaillé pendant " : "Worked for ") + duration(seconds)
    }

    /// A group title such as "Searched the web, read 3 files".
    public static func group(names: [String], running: Bool, locale: Locale = .current) -> String {
        let fr = french(locale)
        var counts: [ToolActivityCategory: Int] = [:]
        var order: [ToolActivityCategory] = []
        for name in names {
            let category = ToolActivityCategory.classify(name)
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += 1
        }
        let phrases = order.map { phrase($0, count: counts[$0] ?? 1, running: running, fr: fr) }
        guard let first = phrases.first else { return fr ? "Actions" : "Actions" }
        let joined = ([first.prefix(1).uppercased() + first.dropFirst()] + phrases.dropFirst().prefix(2)).joined(separator: ", ")
        return phrases.count > 3 ? joined + (fr ? " et plus" : " and more") : joined
    }

    private static func phrase(_ category: ToolActivityCategory, count: Int, running: Bool, fr: Bool) -> String {
        let n = count > 1 ? "\(count) " : ""
        switch (category, fr) {
        case (.search, false): return running ? "searching" : count > 1 ? "searched \(count) times" : "searched the web"
        case (.search, true): return running ? "recherche" : count > 1 ? "\(count) recherches" : "recherche effectuée"
        case (.find, false): return running ? "searching files" : count > 1 ? "searched files \(count) times" : "searched files"
        case (.find, true): return running ? "recherche dans les fichiers" : count > 1 ? "\(count) recherches de fichiers" : "fichiers recherchés"
        case (.note, false): return count > 1 ? "sent \(count) notes" : "sent a note"
        case (.note, true): return count > 1 ? "\(count) notes envoyées" : "note envoyée"
        case (.browse, false): return running ? "reading pages" : "read \(n)page\(count > 1 ? "s" : "")"
        case (.browse, true): return running ? "lecture de pages" : "\(n)page\(count > 1 ? "s" : "") lue\(count > 1 ? "s" : "")"
        case (.read, false): return running ? "reading files" : "read \(n)file\(count > 1 ? "s" : "")"
        case (.read, true): return running ? "lecture de fichiers" : "\(n)fichier\(count > 1 ? "s" : "") lu\(count > 1 ? "s" : "")"
        case (.edit, false): return running ? "editing" : "edited \(n)file\(count > 1 ? "s" : "")"
        case (.edit, true): return running ? "modification" : "\(n)fichier\(count > 1 ? "s" : "") modifié\(count > 1 ? "s" : "")"
        case (.command, false): return running ? "running commands" : "ran \(n)command\(count > 1 ? "s" : "")"
        case (.command, true): return running ? "commandes en cours" : "\(n)commande\(count > 1 ? "s" : "") exécutée\(count > 1 ? "s" : "")"
        case (.image, false): return "viewed \(n)image\(count > 1 ? "s" : "")"
        case (.image, true): return "\(n)image\(count > 1 ? "s" : "") analysée\(count > 1 ? "s" : "")"
        case (.subagent, false): return running ? "working with sub-agents" : "worked with sub-agents"
        case (.subagent, true): return running ? "sous-agents au travail" : "sous-agents sollicités"
        case (.network, false): return running ? "waiting for the network" : "waited for the network"
        case (.network, true): return running ? "attente du réseau" : "réseau attendu"
        case (.route, false): return "changed provider"
        case (.route, true): return "fournisseur changé"
        case (.other, false): return running ? "using tools" : "used \(n)tool\(count > 1 ? "s" : "")"
        case (.other, true): return running ? "outils en cours" : "\(n)outil\(count > 1 ? "s" : "") utilisé\(count > 1 ? "s" : "")"
        }
    }
}
