import GRDB
@testable import AIMApplication
import XCTest

/// Diagnostic corpus: report actual local models/cache/scores before changing a recall policy.
final class HybridMemoryProbeTests: XCTestCase {
    func testReportsLocalParaphraseAndUnrelatedControls() async throws {
        let pairs: [(String, String, String, Bool)] = [
            ("I prefer short explanations.", "reply style", "Keep messages concise.", true),
            ("Use brief answers.", "output preference", "Respond concisely.", true),
            ("Give compact replies.", "communication preference", "Provide short responses.", true),
            ("I develop native interfaces for Apple computers.", "software stack", "My macOS applications use SwiftUI.", true),
            ("Questions should be answered briefly.", "response length", "I dislike lengthy responses.", true),
            ("I prefer short explanations.", "transport", "I enjoy cycling outdoors.", false),
            ("Use brief answers.", "database", "Schema migrations rely on SQLite.", false),
            ("Give compact replies.", "cuisine", "The recipe requires ripe tomatoes.", false),
        ]
        var rows: [[String: Any]] = []
        for (query, subject, content, related) in pairs {
            let database = try AIMDatabase(inMemory: true)
            let repository = SQLiteMemoryRepository(database: database)
            let item = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: subject,
                content: content, status: .verified)
            try await repository.save(item)
            let id = item.id
            let cache = try await database.pool.read { db in
                (try String.fetchOne(db, sql: "SELECT contentHash FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString]),
                 try Data.fetchOne(db, sql: "SELECT vector FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString]))
            }
            let queryVector = HybridMemorySearch.vector(query)
            let cachedVector = cache.1.flatMap { try? JSONDecoder().decode(LocalMemoryVector.self, from: $0) }
            let contentVector = HybridMemorySearch.vector(content)
            let recalled = try await repository.searchScoped(query, projectID: nil, includeGlobal: true, limit: 1)
            let expectedHash = HybridMemorySearch.fingerprint(subject + " " + content)
            XCTAssertEqual(cache.0, expectedHash, "The cached vector must describe the saved text")
            let queryWords = Set(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }.map(String.init))
            let candidateText = (subject + " " + content).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let lexicalMatches = queryWords.filter { candidateText.contains($0) }.sorted()
            XCTAssertTrue(lexicalMatches.isEmpty, "The diagnostic corpus must isolate semantic recall")
            func cosine(_ lhs: LocalMemoryVector?, _ rhs: LocalMemoryVector?) -> Any {
                guard let lhs, let rhs, lhs.model == rhs.model, lhs.values.count == rhs.values.count else { return NSNull() }
                let numerator = zip(lhs.values, rhs.values).reduce(0.0) { $0 + $1.0 * $1.1 }
                let left = lhs.values.reduce(0.0) { $0 + $1 * $1 }
                let right = rhs.values.reduce(0.0) { $0 + $1 * $1 }
                guard left > 0, right > 0 else { return NSNull() }
                return numerator / sqrt(left * right)
            }
            rows.append(["query": query, "subject": subject, "content": content, "related": related,
                "query_model": queryVector?.model as Any? ?? NSNull(), "cached_model": cachedVector?.model as Any? ?? NSNull(),
                "cosine_with_subject": cosine(queryVector, cachedVector), "cosine_content_only": cosine(queryVector, contentVector),
                "lexical_matches": lexicalMatches,
                "content_hash_matches": cache.0 == expectedHash, "recalled": recalled.contains(where: { $0.id == item.id })])
        }
        let data = try JSONSerialization.data(withJSONObject: ["semantic_threshold": 0.55, "rows": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/private/tmp/aim-memory-paraphrase-probe-20261005.json"), options: .atomic)
    }
}
