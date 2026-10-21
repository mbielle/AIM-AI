import AIMAgentKit
@testable import AIMMacPlatform
import SQLite3
import XCTest

final class NativeAgentToolsTests: XCTestCase {
    func testMessagesHistoryReadsChatDatabaseReadOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aim-chat-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let now = Date.now.timeIntervalSinceReferenceDate
        let old = now - 30 * 86_400
        // Text only in attributedBody, like recent macOS: "NSString" marker, then "+", a length byte, the UTF-8 text.
        var blob = Data("streamtyped\u{81}NSAttributedString\u{0}NSObject\u{0}NSString\u{1}\u{95}\u{84}\u{1}+".utf8)
        let hidden = Data("Hidden body".utf8)
        blob.append(UInt8(hidden.count)); blob.append(hidden)
        let statements = [
            "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)",
            "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER, date INTEGER, handle_id INTEGER)",
            "INSERT INTO handle VALUES (1, '+33600000000'), (2, 'friend@example.invalid')",
            "INSERT INTO message VALUES (1, 'Hello', NULL, 0, \(Int64(now * 1_000_000_000)), 1)",
            "INSERT INTO message VALUES (2, 'Old one', NULL, 1, \(Int64(old * 1_000_000_000)), 1)",
            "INSERT INTO message VALUES (3, NULL, ?, 0, \(Int64((now - 60) * 1_000_000_000)), 2)"
        ]
        for sql in statements {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK, sql)
            if sql.contains("?") { _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), nil) } }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)

        let all = try MacMessagesToolService.read(database: file, handle: nil, limit: 10, daysBack: 0)
        XCTAssertEqual(all.map(\.text), ["Hello", "Hidden body", "Old one"])
        XCTAssertEqual(all[1].handle, "friend@example.invalid")
        let recent = try MacMessagesToolService.read(database: file, handle: "+336", limit: 10, daysBack: 7)
        XCTAssertEqual(recent.map(\.text), ["Hello"])
        XCTAssertThrowsError(try MacMessagesToolService.read(database: URL(fileURLWithPath: "/nonexistent/chat.db"), handle: nil, limit: 5, daysBack: 0))
    }

    func testAppsResolveByNameOrBundleID() async throws {
        let service = AgentLaunchToolService()
        let calculator = try await service.resolve("com.apple.calculator")
        XCTAssertEqual(calculator.bundleID, "com.apple.calculator")
        let byName = try await service.resolve(calculator.name)
        XCTAssertEqual(byName.bundleID, "com.apple.calculator")
        do { _ = try await service.resolve("No Such App 123"); XCTFail("unknown app") } catch {}
        let listed = await service.execute(ToolRequest(name: "list_apps", arguments: ["query": "calcul"], risk: .readOnly))
        XCTAssertTrue(listed.content.contains("com.apple.calculator"))
        let badURL = await service.execute(ToolRequest(name: "open_url", arguments: ["url": "file:///etc/hosts"], risk: .externalEffect))
        XCTAssertTrue(badURL.isError)
    }

    func testAppleScriptRunsAndReportsErrors() async {
        let service = AgentAppleScriptToolService()
        let sum = await service.execute(ToolRequest(name: "run_applescript", arguments: ["script": "return 20 + 22"], risk: .computerAction))
        XCTAssertEqual(sum.content, "42")
        let list = await service.execute(ToolRequest(name: "run_applescript", arguments: ["script": "return {\"a\", \"b\"}"], risk: .computerAction))
        XCTAssertEqual(list.content, "a\nb")
        let broken = await service.execute(ToolRequest(name: "run_applescript", arguments: ["script": "this is not applescript ((("], risk: .computerAction))
        XCTAssertTrue(broken.isError)
        let review = try? await service.review(ToolRequest(name: "run_applescript", arguments: ["script": "beep"], risk: .computerAction))
        XCTAssertEqual(review?.after, "beep")
    }

    func testMessagesPhoneNumbersUseInternationalForm() {
        XCTAssertEqual(MacMessagesToolService.internationalNumber("06 12 34 56 78", region: "FR"), "+33612345678")
        XCTAssertEqual(MacMessagesToolService.internationalNumber("+33 6 12 34 56 78", region: "FR"), "+33 6 12 34 56 78")
        XCTAssertEqual(MacMessagesToolService.internationalNumber("0033612345678", region: "FR"), "+33612345678")
        XCTAssertEqual(MacMessagesToolService.internationalNumber("someone@example.com", region: "FR"), "someone@example.com")
        XCTAssertEqual(MacMessagesToolService.internationalNumber("415 555 0100", region: "US"), "+14155550100")
        XCTAssertEqual(MacMessagesToolService.internationalNumber("0612345678", region: nil), "0612345678")
    }
}
