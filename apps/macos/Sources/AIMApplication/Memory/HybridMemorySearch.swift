import CryptoKit
import Foundation
import NaturalLanguage

public struct LocalMemoryVector: Codable, Sendable {
    public let model: String
    public let values: [Double]
}

/// Uses only embedding models already available in macOS. No downloads or network calls.
public enum HybridMemorySearch {
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func vector(_ text: String) -> LocalMemoryVector? {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let vector = embedding.vector(for: text), !vector.isEmpty,
              vector.allSatisfy(\.isFinite) else { return nil }
        return LocalMemoryVector(model: "apple-sentence-\(language.rawValue)-\(embedding.revision)", values: vector)
    }
    private static func similarity(_ lhs: LocalMemoryVector?, _ rhs: LocalMemoryVector?) -> Double {
        guard let lhs, let rhs, lhs.model == rhs.model, lhs.values.count == rhs.values.count else { return 0 }
        var product = 0.0, left = 0.0, right = 0.0
        for (a, b) in zip(lhs.values, rhs.values) { product += a * b; left += a * a; right += b * b }
        guard left > 0, right > 0 else { return 0 }
        return max(0, min(1, product / sqrt(left * right)))
    }
    /// Words that say nothing about a memory's subject (French and English).
    static let stopWords: Set<String> = ["the", "and", "for", "you", "your", "are", "was", "with", "that", "this", "what",
        "which", "have", "has", "from", "can", "could", "would", "should", "about", "into", "please", "tell", "give", "make",
        "les", "des", "une", "est", "pour", "que", "qui", "quoi", "dans", "avec", "pas", "sur", "mon", "mes", "ton", "tes",
        "son", "ses", "nous", "vous", "ils", "elle", "elles", "quel", "quelle", "quels", "quelles", "comment", "pourquoi",
        "faire", "fais", "peux", "veux", "moi", "toi", "aux", "par", "plus", "tout", "tous", "cette", "ces", "mais", "donc",
        "est-ce", "estce", "suis", "sont", "etre", "avoir", "ai", "as", "il", "je", "tu", "on", "du", "de", "la", "le"]

    /// Folded words of a query, without stop words; long words also match their stem
    /// (plurals, conjugations: "préférences" finds "préfère").
    static func terms(_ query: String) -> [(word: String, stem: String)] {
        let words = Set(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }.map(String.init))
            .subtracting(stopWords)
        return words.sorted().map { ($0, $0.count >= 6 ? String($0.prefix(max(5, min(6, $0.count - 2)))) : $0) }
    }

    /// Who the person is and how they work: pinned entries, identity, preferences and constraints.
    public static func isProfile(_ item: MemoryItem) -> Bool {
        item.isPinned || [.identity, .preference, .constraint].contains(item.kind)
    }

    public static func ranked(_ items: [MemoryItem], query: String, projectID: UUID?, includeGlobal: Bool = true,
                              vectors: [UUID: LocalMemoryVector] = [:], limit: Int = 8, includeProfile: Bool = false) -> [MemoryItem] {
        let words = terms(query)
        let queryVector = vector(query)
        let candidates = items.filter {
            (includeGlobal && $0.scope == "global" && $0.scopeKey == "self" || $0.scope == "project" && projectID?.uuidString == $0.scopeKey)
                && (try? MemoryContext.validate($0)) != nil
        }
        let texts = Dictionary(candidates.map { ($0.id, ($0.subjectKey + " " + $0.content).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) },
                               uniquingKeysWith: { first, _ in first })
        let frequencies = words.reduce(into: [String: Int]()) { result, term in
            result[term.stem] = candidates.filter { texts[$0.id]?.contains(term.stem) == true }.count
        }
        let scored: [(MemoryItem, Double)] = candidates.compactMap { item in
            let text = texts[item.id] ?? ""
            let lexical = words.reduce(0.0) { score, term in
                let weight = log(1 + Double(candidates.count) / Double(1 + (frequencies[term.stem] ?? 0)))
                return score + (text.contains(term.word) ? weight : text.contains(term.stem) ? weight * 0.8 : 0)
            }
            let semantic = similarity(queryVector, vectors[item.id] ?? vector(item.subjectKey + " " + item.content))
            let profile = includeProfile && isProfile(item)
            guard item.isPinned || profile || lexical > 0 || semantic >= 0.55 else { return nil }
            let review = item.status == .verified ? 0.05 : 0
            return (item, lexical + semantic * 2 + review)
        }
        return scored.sorted {
            if $0.0.isPinned != $1.0.isPinned { return $0.0.isPinned }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.scope != $1.0.scope { return $0.0.scope == "project" }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.prefix(max(0, limit)).map(\.0)
    }
    /// Consolidation is a proposal only; never silently replaces conflicting or unreviewed facts.
    public static func duplicateGroups(_ items: [MemoryItem]) -> [[UUID]] {
        var groups: [String: [UUID]] = [:]
        for item in items where item.status != .archived {
            let normalized = item.content.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = [item.kind.rawValue, item.scope, item.scopeKey, normalized].joined(separator: "\0")
            groups[key, default: []].append(item.id)
        }
        let duplicates = groups.values.filter { $0.count > 1 }.map { values in
            values.sorted { $0.uuidString < $1.uuidString }
        }
        return duplicates.sorted { ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "") }
    }
}
