import AIMAgentKit
import AIMApplication
import Foundation
@testable import AIMMacPlatform
import XCTest

final class MacMailToolTests: XCTestCase {
    func testMailArgumentsAndScopeAreValidatedBeforeAutomation() async throws {
        let runner = FixtureMailRunner()
        let service = MacMailToolService(runner: runner)
        let invalid: [(String, [String: String])] = [
            ("mail_mailboxes", [:]),
            ("mail_messages", ["account_id": "a", "mailbox_name": "Inbox", "limit": "101"]),
            ("mail_search", ["account_id": "a", "mailbox_name": "Inbox", "query": ""]),
            ("mail_get", ["account_id": "a", "mailbox_name": "Inbox", "id": "0"]),
            ("mail_mark", ["account_id": "a", "mailbox_name": "Inbox", "id": "42",
                           "expected_subject": "Subject", "expected_sender": "sender@example.com"]),
            ("mail_move", ["account_id": "a", "mailbox_name": "Inbox", "id": "42",
                           "expected_subject": "Subject", "expected_sender": "sender@example.com",
                           "destination_account_id": "a", "destination_mailbox_name": "Inbox"]),
            ("mail_delete", ["account_id": "a", "mailbox_name": "Inbox", "id": "42",
                             "expected_subject": "\n", "expected_sender": "sender@example.com"]),
            ("mail_send", ["account_id": "a", "sender_address": "fixture-user-2@example.invalid",
                           "to": "[]", "subject": "Subject", "body": "Body"]),
            ("mail_send", ["account_id": "a", "sender_address": "fixture-user-2@example.invalid",
                           "to": "[\"bad address\"]", "subject": "Subject", "body": "Body"])
        ]
        for (name, arguments) in invalid {
            let result = await service.execute(ToolRequest(name: name, arguments: arguments, risk: .computerRead))
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.content.contains("Invalid Mail"), result.content)
        }
        let scripts = await runner.scripts
        XCTAssertTrue(scripts.isEmpty)
        let intent = try service.missionIntent(for: ToolRequest(name: "mail_get",
            arguments: ["account_id": "a", "mailbox_name": "Inbox", "id": "42"], risk: .computerRead))
        XCTAssertEqual(intent?.operation, .observe)
        XCTAssertEqual(intent?.target,
            try MissionResource(kind: .application, identifier: "com.apple.mail"))
        let deleteIntent = try service.missionIntent(for: ToolRequest(name: "mail_delete",
            arguments: ["account_id": "a", "mailbox_name": "Inbox", "id": "42",
                        "expected_subject": "", "expected_sender": "sender@example.com"], risk: .computerAction))
        XCTAssertEqual(deleteIntent?.operation, .permanentDelete)
    }

    func testMailReadResultsKeepExactAccountMailboxAndAttachmentMetadata() async {
        let runner = FixtureMailRunner(rows: [
            [["account", "a1", "Work", "Work User", "imap"], ["email", "a1", "work@example.com"]],
            [["meta", "2"], ["Inbox", "Work", "3"], ["Archive", "Work", "0"]],
            [["meta", "1"], ["42", "Subject", "sender@example.com", "today", "false", "true"]],
            [["message", "42", "Subject", "sender@example.com", "Hello", "today", "", "false", "true", "rfc-42"],
             ["attachments_meta", "1", "false"],
             ["attachment", "att-1", "report.pdf", "application/pdf", "123", "true"]]
        ])
        let service = MacMailToolService(runner: runner)
        let accounts = await service.execute(ToolRequest(name: "mail_accounts", arguments: [:], risk: .computerRead))
        XCTAssertFalse(accounts.isError, accounts.content)
        XCTAssertTrue(accounts.content.contains("work@example.com"))
        let boxes = await service.execute(ToolRequest(name: "mail_mailboxes",
            arguments: ["account_id": "a1"], risk: .computerRead))
        XCTAssertFalse(boxes.isError, boxes.content)
        let messages = await service.execute(ToolRequest(name: "mail_messages",
            arguments: ["account_id": "a1", "mailbox_name": "Inbox"], risk: .computerRead))
        XCTAssertFalse(messages.isError, messages.content)
        XCTAssertTrue(messages.content.contains("\"accountID\":\"a1\""))
        let detail = await service.execute(ToolRequest(name: "mail_get",
            arguments: ["account_id": "a1", "mailbox_name": "Inbox", "id": "42"], risk: .computerRead))
        XCTAssertFalse(detail.isError, detail.content)
        XCTAssertTrue(detail.content.contains("report.pdf"))
        XCTAssertTrue(detail.content.contains("application"))
        XCTAssertTrue(detail.content.contains("\"attachmentsTruncated\":false"))
        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 4)
        XCTAssertTrue(scripts[2].contains("AIM_MAILBOX_NOT_UNIQUE"))
        XCTAssertTrue(scripts[3].contains("whose id is 42"))
    }

    func testMailAttachmentLimitIsExplicitAndMalformedFlagsAreRejected() async {
        let message = ["message", "42", "Subject", "sender@example.com", "Hello", "today", "",
                       "false", "true", "rfc-42"]
        let attachments = (0..<100).map { index in
            ["attachment", "att-\(index)", "file-\(index).txt", "text/plain", "1", "true"]
        }
        let runner = FixtureMailRunner(rows: [
            [message, ["attachments_meta", "101", "true"]] + attachments,
            [message, ["attachments_meta", "1", "false"],
             ["attachment", "att-1", "file.txt", "text/plain", "1", "possibly"]]
        ])
        let service = MacMailToolService(runner: runner)
        let request = ToolRequest(name: "mail_get",
            arguments: ["account_id": "a1", "mailbox_name": "Inbox", "id": "42"], risk: .computerRead)
        let truncated = await service.execute(request)
        XCTAssertFalse(truncated.isError, truncated.content)
        XCTAssertTrue(truncated.content.contains("\"attachmentTotal\":101"))
        XCTAssertTrue(truncated.content.contains("\"attachmentsTruncated\":true"))
        let invalid = await service.execute(request)
        XCTAssertTrue(invalid.isError)
    }

    func testFixedMailReadScriptsCompileWithoutExecutingAutomation() {
        let scripts = [MailScripts.accounts, MailScripts.mailboxes(accountID: "a1"),
                       MailScripts.messages(accountID: "a1", mailbox: "Inbox", query: nil,
                                            searchBody: false, offset: 0, limit: 50),
                       MailScripts.messages(accountID: "a1", mailbox: "Inbox", query: "test",
                                            searchBody: true, offset: 0, limit: 50),
                       MailScripts.get(accountID: "a1", mailbox: "Inbox", id: 42)]
        for body in scripts {
            let source = "\(MailScripts.helpers)\nwith timeout of 30 seconds\n\(body)\nend timeout"
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
        }
    }

    func testMailMutationsRequireExactTargetAndVerifyResult() async {
        let runner = FixtureMailRunner(rows: [
            [["42", "true", "false"]],
            [["42", "0", "1"]],
            [["42", "0"]]
        ])
        let service = MacMailToolService(runner: runner)
        let target = ["account_id": "a1", "mailbox_name": "Inbox", "id": "42",
                      "expected_subject": "", "expected_sender": "sender@example.com"]
        var mark = target
        mark["read"] = "true"
        let marked = await service.execute(ToolRequest(name: "mail_mark", arguments: mark, risk: .computerAction))
        XCTAssertFalse(marked.isError, marked.content)
        XCTAssertEqual(marked.actionOutcome, .confirmed)
        var move = target
        move["destination_account_id"] = "a1"
        move["destination_mailbox_name"] = "Archive"
        let moved = await service.execute(ToolRequest(name: "mail_move", arguments: move, risk: .computerAction))
        XCTAssertFalse(moved.isError, moved.content)
        XCTAssertEqual(moved.actionOutcome, .confirmed)
        let deleted = await service.execute(ToolRequest(name: "mail_delete", arguments: target, risk: .computerAction))
        XCTAssertFalse(deleted.isError, deleted.content)
        XCTAssertEqual(deleted.actionOutcome, .confirmed)
        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 3)
        XCTAssertTrue(scripts.allSatisfy { $0.contains("AIM_MAIL_MESSAGE_CHANGED") })
    }

    func testMailMutationWithUnverifiedEffectStaysUnknown() async {
        let runner = FixtureMailRunner(rows: [[["42", "1", "0"]]])
        let service = MacMailToolService(runner: runner)
        let result = await service.execute(ToolRequest(name: "mail_move", arguments: [
            "account_id": "a1", "mailbox_name": "Inbox", "id": "42",
            "expected_subject": "Subject", "expected_sender": "sender@example.com",
            "destination_account_id": "a1", "destination_mailbox_name": "Archive"
        ], risk: .computerAction))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.actionOutcome, .unknown)
    }

    func testFixedMailMutationScriptsCompileWithoutExecutingAutomation() {
        let scripts = [
            MailScripts.mark(accountID: "a1", mailbox: "Inbox", id: 42,
                             expectedSubject: "", expectedSender: "sender@example.com", read: true, flagged: nil),
            MailScripts.move(accountID: "a1", mailbox: "Inbox", id: 42,
                             expectedSubject: "Subject", expectedSender: "sender@example.com",
                             destinationAccountID: "a1", destinationMailbox: "Archive"),
            MailScripts.delete(accountID: "a1", mailbox: "Inbox", id: 42,
                               expectedSubject: "Subject", expectedSender: "sender@example.com")
        ]
        for body in scripts {
            let source = "\(MailScripts.helpers)\nwith timeout of 30 seconds\n\(body)\nend timeout"
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
        }
    }

    func testMailComposeUsesExactRecipientsAndHonestDeliveryStatus() async throws {
        let runner = FixtureMailRunner(rows: [
            [["draft", "123", "Subject", "fixture-user-2@example.invalid"]],
            [["submitted", "124", "Subject", "fixture-user-2@example.invalid"]]
        ])
        let service = MacMailToolService(runner: runner)
        let arguments = ["account_id": "a1", "sender_address": "fixture-user-2@example.invalid",
                         "to": "[\"you@example.com\"]", "cc": "[\"copy@example.com\"]",
                         "subject": "Subject", "body": "Hello\nworld"]
        let draft = await service.execute(ToolRequest(name: "mail_draft", arguments: arguments,
                                                       risk: .computerAction))
        XCTAssertFalse(draft.isError, draft.content)
        XCTAssertEqual(draft.actionOutcome, .unverified)
        XCTAssertTrue(draft.content.contains("save_accepted_not_confirmed_in_drafts"))
        let sendIntent = try service.missionIntent(for: ToolRequest(name: "mail_send", arguments: arguments,
                                                                    risk: .computerAction))
        XCTAssertEqual(sendIntent?.needs.count, 3)
        XCTAssertEqual(sendIntent?.needs.filter { $0.target.kind == .recipient }.count, 2)
        let sent = await service.execute(ToolRequest(name: "mail_send", arguments: arguments,
                                                      risk: .computerAction))
        XCTAssertFalse(sent.isError, sent.content)
        XCTAssertEqual(sent.actionOutcome, .unverified)
        XCTAssertTrue(sent.content.contains("submitted_to_mail_not_confirmed_delivered"))
        let scripts = await runner.scripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[0].contains("save msgRef"))
        XCTAssertTrue(scripts[1].contains("send msgRef"))
        XCTAssertTrue(scripts[1].contains(" & linefeed & "))
        XCTAssertTrue(scripts[1].contains("AIM_MAIL_SENDER_NOT_IN_ACCOUNT"))
    }

    func testFixedMailComposeScriptsCompileWithoutExecutingAutomation() {
        for send in [false, true] {
            let body = MailScripts.compose(accountID: "a1", sender: "fixture-user-2@example.invalid",
                to: ["you@example.com"], cc: ["copy@example.com"], bcc: [],
                subject: "Subject", body: "Hello\nworld", send: send)
            let source = "\(MailScripts.helpers)\nwith timeout of 60 seconds\n\(body)\nend timeout"
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            XCTAssertTrue(script?.compileAndReturnError(&error) == true, "\(error ?? [:])")
        }
    }
}

private actor FixtureMailRunner: MacAutomationScriptRunning {
    private var replies: [[[String]]]
    var scripts: [String] = []
    init(rows: [[[String]]] = []) { replies = rows }
    func run(_ script: String, helpers: String, timeoutSeconds: Int) throws -> [[String]] {
        guard helpers.contains("on safeText"), (30...60).contains(timeoutSeconds) else {
            throw NSError(domain: "Invalid Mail runner configuration", code: 1)
        }
        scripts.append(script)
        guard !replies.isEmpty else { throw NSError(domain: "Unexpected Mail call", code: 1) }
        return replies.removeFirst()
    }
}

final class MailSenderFormatTests: XCTestCase {
    func testSenderMatchesBareOrNamedAddressOnly() {
        XCTAssertTrue(MacMailToolService.senderMatches("fixture-user-2@example.invalid", address: "fixture-user-2@example.invalid"))
        XCTAssertTrue(MacMailToolService.senderMatches("Jane Doe <FIXTURE-USER-2@EXAMPLE.INVALID>", address: "fixture-user-2@example.invalid"))
        XCTAssertFalse(MacMailToolService.senderMatches("Jane <other@example.com>", address: "fixture-user-2@example.invalid"))
        XCTAssertFalse(MacMailToolService.senderMatches("fixture-user-1@example.invalid", address: "fixture-user-2@example.invalid"))
    }
}
