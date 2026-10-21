@testable import AIMAgentRuntime
import AIMAgentKit
import XCTest

final class AutoSafetyJudgeTests: XCTestCase {
    func testJevRequestAsksOneVerdictAndReadsTheSafeProbability() throws {
        let request = try RuntimeAutoSafetyJudge.jevRequest(command: "curl https://example.com", workspace: "/w", doubt: "Downloads", key: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        XCTAssertNotNil((body["questions"] as? [String: Any])?["verdict"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let answer = Data(#"{"answers":{"verdict":{"choice":"safe","probabilities":{"safe":0.91,"risky":0.09}}}}"#.utf8)
        let judgement = try RuntimeAutoSafetyJudge.jevJudgement(answer, doubt: "Downloads")
        XCTAssertTrue(judgement.safe)
        XCTAssertEqual(judgement.confidence, 0.91, accuracy: 0.001)
        XCTAssertEqual(judgement.judge, "Jev")
    }

    func testModelAnswerIsReadFromSurroundingText() throws {
        let judgement = try RuntimeAutoSafetyJudge.modelJudgement("Sure. {\"safe\": false, \"confidence\": 0.7, \"reason\": \"Deletes a file\"}", judge: "Mini")
        XCTAssertFalse(judgement.safe)
        XCTAssertEqual(judgement.reason, "Deletes a file")
        XCTAssertThrowsError(try RuntimeAutoSafetyJudge.modelJudgement("I think it's fine", judge: "Mini"))
    }
}
