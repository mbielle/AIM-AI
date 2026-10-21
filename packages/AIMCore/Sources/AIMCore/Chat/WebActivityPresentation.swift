import Foundation

/// A label for an observed web tool action. Citations and prose are deliberately not inputs:
/// receiving a source does not prove that the provider opened that page at that moment.
public struct WebActivityPresentation: Equatable, Sendable {
    public enum Kind: Sendable { case search, page, find }
    public let kind: Kind
    public let title: String
    public let subject: String?
    public let url: URL?
    public let isRunning: Bool
    public var domain: String? { url?.host }

    public init?(action: ConversationAction, locale: Locale = .current) {
        guard ["web_search", "web_fetch", "web_read", "fetch_url", "open_page", "find_in_page", "openrouter:web_search", "openrouter:web_fetch"].contains(action.name) else { return nil }
        let french = locale.language.languageCode?.identifier == "fr"
        isRunning = [.running, .waiting].contains(action.state)
        let object = action.input.flatMap { text in
            text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let operation = object?["type"] as? String ?? action.name
        let isPage = ["open_page", "web_fetch", "web_read", "fetch_url", "openrouter:web_fetch"].contains(operation)
        let isFind = operation == "find_in_page"
        kind = isFind ? .find : isPage ? .page : .search
        let rawURL = object?["url"] as? String ?? object?["source_url"] as? String
            ?? (isPage ? action.input : nil)
        url = rawURL.flatMap(Self.safeURL)
        let query = object?["query"] as? String ?? (object == nil && !isPage ? action.input : nil)
        subject = url?.host ?? query.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }.flatMap { $0.isEmpty ? nil : $0 }
        if action.state == .failed { title = french ? "Échec de la recherche web" : "Web request failed" }
        else if action.state == .cancelled { title = french ? "Recherche web annulée" : "Web request cancelled" }
        else if action.state == .needsReview { title = french ? "Résultat web inconnu" : "Web result unknown" }
        else if isFind { title = french ? (isRunning ? "Recherche dans la page" : "Recherche dans la page terminée") : (isRunning ? "Finding in page" : "Found in page") }
        else if isPage { title = french ? (isRunning ? "Lecture de la page" : "Page consultée") : (isRunning ? "Reading page" : "Read page") }
        else { title = french ? (isRunning ? "Recherche sur le web" : "Recherche web terminée") : (isRunning ? "Searching the web" : "Searched the web") }
    }

    /// The newest still-running web invocation, never a finished source rotated by a timer.
    public static func active(in actions: [ConversationAction], locale: Locale = .current) -> Self? {
        actions.filter { [.running, .waiting].contains($0.state) }
            .sorted { $0.ordinal == $1.ordinal ? $0.startedAt < $1.startedAt : $0.ordinal < $1.ordinal }
            .reversed().compactMap { Self(action: $0, locale: locale) }.first
    }

    private static func safeURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192, let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Activity only needs the site. Query strings/fragments can contain credentials.
        parts?.query = nil; parts?.fragment = nil
        return parts?.url
    }
}
