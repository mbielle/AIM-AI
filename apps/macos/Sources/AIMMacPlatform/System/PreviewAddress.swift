import Foundation

public enum PreviewAddress {
    public static func parse(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 8_192,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !raw.contains("\\") else { return nil }
        let address: String
        if raw.allSatisfy(\.isNumber) {
            guard let port = Int(raw), (1...65_535).contains(port) else { return nil }
            address = "http://localhost:\(port)"
        }
        else if raw.contains("://") { address = raw }
        else { address = "http://\(raw)" }
        guard let url = URL(string: address), allows(url) else { return nil }
        if !raw.contains("://"), URLComponents(string: raw)?.scheme != nil, url.port == nil { return nil }
        return url
    }

    public static func allows(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              !url.absoluteString.contains("\\"),
              !host.contains(where: { $0.isWhitespace }) else { return false }
        if let port = url.port, !(1...65_535).contains(port) { return false }
        return true
    }
}
