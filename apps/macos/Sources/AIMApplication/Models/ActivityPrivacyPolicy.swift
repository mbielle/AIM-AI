import Foundation

public enum ActivityPrivacyPolicy {
    public static let passwordManagers = [
        "bitwarden", "1password", "keepass", "keepassxc", "dashlane",
        "lastpass", "protonpass", "nordpass", "enpass", "roboform",
    ]
    // Browser windows are excluded until their private-mode state can be verified.
    public static let browsers = [
        "safari", "google chrome", "brave browser", "firefox", "microsoft edge",
        "arc", "opera", "vivaldi", "tor browser",
    ]
    private static let sensitiveApplications = [
        "bank", "banque", "revolut", "n26", "qonto", "paypal", "stripe",
        "authenticator", "authy", "password", "keychain", "wallet",
    ]

    public static let defaultExcludedDomains = [
        "bitwarden.com", "1password.com", "lastpass.com", "dashlane.com",
        "stripe.com", "paypal.com", "labanquepostale.fr", "creditagricole.fr",
        "bnpparibas", "societegenerale.fr", "caisse-epargne.fr",
        "credit-mutuel.fr", "boursorama.com", "fortuneo.fr", "revolut.com",
        "n26.com", "qonto.com", "lcl.fr", "hellobank.fr",
    ]

    private static let privateMarkers = [
        "private browsing", "private window", "incognito", "inprivate",
        "navigation privée", "navigation privee", "fenêtre privée", "fenetre privee",
    ]

    private static let sensitiveLabels = [
        "bank", "banq", "banque", "banking", "credit", "crédit", "caisse",
        "epargne", "épargne", "mutuel", "assurance", "paiement", "payment",
        "pay", "checkout", "billing", "wallet", "crypto", "coinbase",
        "binance", "kraken", "impots", "impôts", "ameli", "urssaf",
        "password", "passwords", "vault", "keychain",
    ]

    private static let sensitivePathFragments = [
        "/login", "/signin", "/connexion", "/auth/", "/checkout", "/paiement",
        "/payment", "/virement", "/transfer", "/password", "/reset-password",
    ]

    public static func shouldExclude(
        application: String,
        title: String,
        url: String?,
        isPrivate: Bool,
        settings: ActivitySettings
    ) -> Bool {
        let app = application.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        guard !app.isEmpty else { return true }
        if browsers.contains(where: { app == $0 || app.hasPrefix("\($0) ") }) { return true }
        if passwordManagers.contains(where: app.contains) { return true }
        if sensitiveApplications.contains(where: app.contains) { return true }
        if settings.excludedApplications.map({ $0.lowercased() }).contains(where: app.contains) { return true }
        if isPrivate { return true }

        let foldedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if privateMarkers.contains(where: { foldedTitle.contains($0.folding(options: .diacriticInsensitive, locale: .current)) }) {
            return true
        }

        let titleWords = Set(foldedTitle.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let protectedWords = Set(["password", "passwords", "keychain", "credentials", "secrets", "bank", "banque", "medical", "médical", "billing"])
        if !titleWords.isDisjoint(with: protectedWords) { return true }
        guard let url, !url.isEmpty else { return false }
        let candidate = url.contains("://") ? url : "https://\(url)"
        guard let components = URLComponents(string: candidate) else { return true }
        let host = (components.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if settings.excludedDomains.contains(where: { domain in
            let normalized = domain.lowercased().replacingOccurrences(of: "www.", with: "")
            return host == normalized || host.hasSuffix(".\(normalized)")
        }) { return true }

        let labels = host.split(separator: ".").flatMap { $0.split(separator: "-") }.map(String.init)
        if labels.contains(where: { label in sensitiveLabels.contains(where: label.contains) }) { return true }

        let path = components.path.lowercased()
        return sensitivePathFragments.contains(where: path.contains)
    }
}
