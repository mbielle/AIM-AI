import Foundation

/// A read-only projection of recorded work. A citation is never promoted to a visit,
/// and provider reasoning is never used to infer actions or generate stage titles.
public struct TurnWorkPresentation: Sendable {
    public let header: String
    public let activeLabel: String?
    public let activeWebAction: ConversationAction?
    public let visitedPages: [URL]
    public let receivedSources: Int
    public let citedSources: Int
    public let hasFailedActions: Bool
    public let hasInterruptedActions: Bool
    public let sourceSummary: String?
    public let reasoningTitle: String

    public init(layout: TurnLayout<ConversationAction>, sources: [ConversationSource]?, live: Bool,
                locale: Locale = .current) {
        let french = TurnLayoutText.french(locale)
        header = TurnLayoutText.header(onlyReasoning: layout.onlyReasoning, duration: layout.duration,
                                       running: live, locale: locale)
        reasoningTitle = Self.providerReasoningTitle(locale: locale)
        let actions = layout.all.flatMap { item -> [ConversationAction] in
            if case let .tools(_, values) = item { return values }; return []
        }
        // merge deduplicates action snapshots and keeps terminal states terminal.
        let observed = ConversationAction.merge(actions, []) ?? []
        activeWebAction = live ? observed.last(where: {
            WebActivityPresentation(action: $0, locale: locale)?.isRunning == true
        }) : nil
        var pages: [URL] = [], seen = Set<String>()
        for action in observed where action.state == .completed {
            guard let web = WebActivityPresentation(action: action, locale: locale), web.kind == .page,
                  let url = web.url, seen.insert(url.absoluteString).inserted else { continue }
            pages.append(url)
        }
        visitedPages = pages
        let unique = ConversationSource.merge(sources, []) ?? []
        receivedSources = unique.count
        citedSources = unique.filter { !($0.references ?? []).isEmpty }.count
        hasFailedActions = observed.contains { $0.state == .failed }
        hasInterruptedActions = observed.contains { [.cancelled, .needsReview].contains($0.state) }
        var parts: [String] = []
        if !pages.isEmpty {
            parts.append(french ? "\(pages.count) page\(pages.count == 1 ? " consultée" : "s consultées")"
                         : "\(pages.count) page\(pages.count == 1 ? " read" : "s read")")
        }
        if !unique.isEmpty {
            parts.append(french ? "\(unique.count) source\(unique.count == 1 ? " reçue" : "s reçues")"
                         : "\(unique.count) source\(unique.count == 1 ? " received" : "s received")")
        }
        sourceSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if !live || activeWebAction != nil { activeLabel = nil }
        else if let action = observed.last(where: { [.running, .waiting].contains($0.state) }) {
            activeLabel = TurnLayoutText.group(names: [action.name], running: true, locale: locale)
        } else if layout.answer.contains(where: \.isText) {
            activeLabel = french ? "Rédaction de la réponse…" : "Writing the answer…"
        } else if layout.work.contains(where: { if case .reasoning = $0 { return true }; return false }) {
            activeLabel = french ? "Réflexion…" : "Thinking…"
        } else { activeLabel = nil }
    }

    public static func providerReasoningTitle(locale: Locale = .current) -> String {
        TurnLayoutText.french(locale) ? "Texte de réflexion du fournisseur" : "Provider reasoning text"
    }
}
