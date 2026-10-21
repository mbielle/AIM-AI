import AIMApplication
import XCTest

final class ProjectSourceIndexTests: XCTestCase {
    func testRetrievalIsProjectScopedAndRescanReplacesOldPassages() async throws {
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let alpha = AIMProject(name: "Alpha"), beta = AIMProject(name: "Beta")
        try await projects.save(alpha)
        try await projects.save(beta)
        let source = ProjectSource(projectID: alpha.id, canonicalPath: "/tmp/alpha", displayName: "alpha")
        let foreign = ProjectSource(projectID: beta.id, canonicalPath: "/tmp/beta", displayName: "beta")
        try await projects.save(source: source)
        try await projects.save(source: foreign)
        let index = SQLiteProjectSourceIndex(database: db)
        try await index.replace(source: source, chunks: [ProjectSourceChunk(relativePath: "Sources/Auth.swift", startLine: 12, content: "OAuth refresh token handler")])
        try await index.replace(source: foreign, chunks: [ProjectSourceChunk(relativePath: "private.swift", startLine: 1, content: "OAuth secret from another project")])
        let first = try await index.passages(projectID: alpha.id, query: "Fix OAuth refresh")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].relativePath, "Sources/Auth.swift")
        let context = ProjectContext.messages([], project: alpha, conversationID: UUID(), passages: first)
        XCTAssertTrue(context[0].content.contains("Sources/Auth.swift:12"))
        XCTAssertFalse(context[0].content.contains("another project"))
        try await index.replace(source: source, chunks: [ProjectSourceChunk(relativePath: "Sources/Auth.swift", startLine: 25, content: "OAuth session renewal")])
        let countAfterRescan = try await index.chunkCount(sourceID: source.id)
        let oldHits = try await index.passages(projectID: alpha.id, query: "refresh")
        let newHits = try await index.passages(projectID: alpha.id, query: "renewal")
        XCTAssertEqual(countAfterRescan, 1)
        XCTAssertEqual(oldHits.count, 0)
        XCTAssertEqual(newHits.first?.startLine, 25)
        try await projects.deleteSource(id: source.id)
        let countAfterDelete = try await index.chunkCount(sourceID: source.id)
        let hitsAfterDelete = try await index.passages(projectID: alpha.id, query: "renewal")
        XCTAssertEqual(countAfterDelete, 0)
        XCTAssertTrue(hitsAfterDelete.isEmpty)
    }

    func testRetrievalDiversifiesFilesAndIgnoresQuestionFiller() async throws {
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Code")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: "/tmp/code", displayName: "code")
        try await projects.save(source: source)
        let index = SQLiteProjectSourceIndex(database: db)
        let chunks = (1...18).map { line in
            ProjectSourceChunk(relativePath: "Sources/Auth.swift", startLine: line * 10,
                               content: "OAuth refresh token handler \(line)")
        } + [ProjectSourceChunk(relativePath: "Tests/AuthTests.swift", startLine: 3,
                                content: "OAuth refresh token regression test")]
        try await index.replace(source: source, chunks: chunks)
        let matches = try await index.passages(projectID: project.id,
                                               query: "Could you please fix the OAuth refresh in this file?", limit: 3)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(Set(matches.map(\.relativePath)), ["Sources/Auth.swift", "Tests/AuthTests.swift"])
        let fillerOnly = try await index.passages(projectID: project.id,
                                                  query: "Could you please explain this file?")
        XCTAssertTrue(fillerOnly.isEmpty)
    }

    func testLongQuestionRetainsTheNamedFileAtItsEnd() async throws {
        let db = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: db)
        let project = AIMProject(name: "Long task")
        try await projects.save(project)
        let source = ProjectSource(projectID: project.id, canonicalPath: "/tmp/long", displayName: "long")
        try await projects.save(source: source)
        let index = SQLiteProjectSourceIndex(database: db)
        try await index.replace(source: source, chunks: [
            ProjectSourceChunk(relativePath: "Sources/PaymentCoordinator.swift", startLine: 14,
                               content: "func validateInvoice() {}")
        ])
        let introductoryText = (1...30).map { "backgroundword\($0)" }.joined(separator: " ")
        let matches = try await index.passages(projectID: project.id,
            query: "\(introductoryText) Please inspect PaymentCoordinator.swift", limit: 4)
        XCTAssertEqual(matches.map(\.relativePath), ["Sources/PaymentCoordinator.swift"])
    }

    func testScannerExcludesSensitiveAndDependencyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("func launch() { print(\"hello\") }".utf8).write(to: root.appendingPathComponent("Sources/Main.swift"))
        try Data("API_KEY=must_not_index".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("dependency noise".utf8).write(to: root.appendingPathComponent("node_modules/package.js"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("blob.dat"))
        let scan = try ProjectSourceScanner.scan(root)
        XCTAssertEqual(scan.indexedFiles, 1)
        XCTAssertEqual(scan.chunks.map(\.relativePath), ["Sources/Main.swift"])
        XCTAssertFalse(scan.hasReadErrors)
        XCTAssertFalse(scan.chunks.map(\.content).joined().contains("must_not_index"))
        XCTAssertFalse(scan.chunks.map(\.content).joined().contains("dependency noise"))
    }

    func testScannerPreservesWindowsCRLFLineNumbers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-source-lines-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = String(repeating: "a", count: 1_600)
        try Data("\(line)\r\n\(line)\r\nimportant target\r\n".utf8)
            .write(to: root.appendingPathComponent("main.txt"))
        let scan = try ProjectSourceScanner.scan(root)
        XCTAssertEqual(scan.indexedFiles, 1)
        let target = try XCTUnwrap(scan.chunks.first(where: { $0.content.contains("important target") }),
                                   "Chunks: \(scan.chunks.map { "\($0.startLine):\($0.content.suffix(40))" })")
        let offset = try XCTUnwrap(target.content.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex(where: { $0.contains("important target") }))
        XCTAssertEqual(target.startLine + offset, 3)
        XCTAssertFalse(target.content.contains("\r"))
    }

    func testAutomaticExcerptsMaskLikelyCredentialsButPreserveUsefulCode() {
        let project = AIMProject(name: "Security")
        let passage = ProjectSourceChunk(relativePath: "Config.swift", startLine: 4,
            content: "let api_key = \"verylongsecretvalue123\"\nfunc makeRequest() {}\nlet example = \"sk-ABCDEFGHIJKLMNOPQRST\"")
        let context = ProjectContext.messages([], project: project, conversationID: UUID(), passages: [passage])
        let text = context[0].content
        XCTAssertFalse(text.contains("verylongsecretvalue123"))
        XCTAssertFalse(text.contains("sk-ABCDEFGHIJKLMNOPQRST"))
        XCTAssertTrue(text.contains("func makeRequest()"))
        XCTAssertTrue(text.contains("[redacted possible credential]"))
    }
}
