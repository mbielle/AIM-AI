import XCTest
@testable import AIMApplication

private actor ArchiveRecorder {
    var values: [Data] = []
    func save(_ data: Data) { values.append(data) }
}
final class ActiveRunCompactionTests: XCTestCase {
    func testCompleteCallResultPairsAndOriginalReferenceSurviveCompaction() async throws {
        let archives = ArchiveRecorder()
        let compactor = ActiveRunCompaction(contextLength: 4096, summarize: { _ in
            "{\"objective\":\"Build\",\"decisions\":[],\"completed\":[],\"pending\":[],\"references\":[\"/tmp/original\"],\"errors\":[],\"next_step\":\"Read the original\"}"
        }, archive: { await archives.save($0) })
        let history: [[String: Any]] = [
            ["role": "system", "content": "original rules"], ["role": "user", "content": "/tmp/original exact secret: ABC123"],
            ["role": "assistant", "tool_calls": [["id": "old", "function": ["name": "read", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "old", "content": "old evidence"],
            ["role": "assistant", "tool_calls": [["id": "recent", "function": ["name": "read", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "recent", "content": "recent evidence"],
            ["role": "assistant", "content": "last"]]
        let result = try await compactor.compact(history: history, boundaries: [2, 4, 6], provider: .openRouter)
        XCTAssertEqual(result.history.first?["content"] as? String, "original rules")
        let retained = try JSONSerialization.data(withJSONObject: Array(result.history.dropFirst(2)), options: [.sortedKeys])
        let expected = try JSONSerialization.data(withJSONObject: Array(history[4...]), options: [.sortedKeys])
        XCTAssertEqual(retained, expected)
        let saved = await archives.values
        XCTAssertTrue(String(decoding: try XCTUnwrap(saved.first), as: UTF8.self).contains("ABC123"))
        XCTAssertEqual(result.boundaries, [2, 4])
    }
    func testFailedSummaryArchivesButDoesNotReplaceTranscript() async throws {
        let recorder = ArchiveRecorder()
        // Any prose summary is accepted; only an empty one is refused (the run then keeps its full history).
        let compactor = ActiveRunCompaction(contextLength: 4096, summarize: { _ in "   " }, archive: { await recorder.save($0) })
        do {
            _ = try await compactor.compact(history: [["role": "user", "content": "A"], ["role": "assistant", "content": "B"], ["role": "assistant", "content": "C"], ["role": "assistant", "content": "D"]], boundaries: [1, 2, 3], provider: .google)
            XCTFail("Empty summary accepted")
        } catch { XCTAssertTrue(error is SessionCompactionError) }
        let values = await recorder.values; XCTAssertEqual(values.count, 1)
    }

    func testFencedSummaryIsAccepted() async throws {
        let compactor = ActiveRunCompaction(contextLength: 4096, summarize: { _ in
            "Here is the summary:\n```json\n{\"objective\":\"Research\",\"decisions\":[],\"completed\":[],\"pending\":[],\"references\":[],\"errors\":[],\"next_step\":\"Read more\"}\n```"
        }, archive: { _ in })
        let result = try await compactor.compact(history: [["role": "user", "content": "A"], ["role": "assistant", "content": "B"], ["role": "assistant", "content": "C"], ["role": "assistant", "content": "D"]], boundaries: [1, 2, 3], provider: .openRouter)
        XCTAssertTrue((result.history.first?["content"] as? String)?.contains("\"objective\":\"Research\"") == true)
    }
}
