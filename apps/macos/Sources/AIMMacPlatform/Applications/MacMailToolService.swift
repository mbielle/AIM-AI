import AIMAgentKit
import AIMApplication
import Foundation

/// Typed Apple Mail operations. All targets are resolved by an exact account
/// ID and an unambiguous mailbox name before reading message content.
public actor MacMailToolService: ToolExecutor, MissionIntentProviding {
    public nonisolated let supportedTools: Set<String> = [
        "mail_accounts", "mail_mailboxes", "mail_messages", "mail_search", "mail_get",
        "mail_mark", "mail_move", "mail_delete", "mail_draft", "mail_send"
    ]

    private let runner: any MacAutomationScriptRunning

    public init() { runner = SystemMacAutomationScriptRunner.shared }
    init(runner: any MacAutomationScriptRunning) { self.runner = runner }

    public nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "mail_accounts", "mail_mailboxes", "mail_messages", "mail_search", "mail_get":
            operation = .observe
        case "mail_mark", "mail_move": operation = .edit
        case "mail_delete": operation = .permanentDelete
        case "mail_draft": operation = .edit
        case "mail_send": operation = .send
        default: return nil
        }
        let arguments = try MailArguments(request)
        if case let .compose(_, _, to, cc, bcc, _, _, send) = arguments, send {
            let recipients = Array(Set((to + cc + bcc).map { $0.lowercased() })).sorted()
            guard recipients.count <= 7 else { throw MailError.invalidArgument }
            return try MissionToolIntent(needs: [
                MissionPermissionNeed(operation: .send,
                    target: MissionResource(kind: .application, identifier: "com.apple.mail"))
            ] + recipients.map { address in
                MissionPermissionNeed(operation: .send,
                    target: try MissionResource(kind: .recipient, identifier: address))
            })
        }
        return MissionToolIntent(operation: operation,
            target: try MissionResource(kind: .application, identifier: "com.apple.mail"))
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        var mutationStarted = false
        do {
            let arguments = try MailArguments(request)
            try Task.checkCancellation()
            switch arguments {
            case .accounts:
                let rows = try await run(MailScripts.accounts)
                var accounts: [MailAccount] = []
                for row in rows {
                    if row.count == 5, row[0] == "account" {
                        accounts.append(MailAccount(id: row[1], name: row[2], fullName: row[3],
                                                    type: row[4], emailAddresses: []))
                    } else if row.count == 3, row[0] == "email",
                              let index = accounts.lastIndex(where: { $0.id == row[1] }) {
                        // Mail can return padded values; addresses are later matched exactly.
                        let address = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !address.isEmpty { accounts[index].emailAddresses.append(address) }
                    } else { throw MailError.invalidReply }
                }
                return try Self.encoded(accounts, requestID: request.id)
            case let .mailboxes(accountID, offset, limit):
                let rows = try await run(MailScripts.mailboxes(accountID: accountID,
                    offset: offset, limit: limit))
                let (total, payload) = try Self.pageRows(rows)
                let boxes = try payload.map { row -> MailMailbox in
                    guard row.count == 3, let unread = Int(row[2]), unread >= 0 else {
                        throw MailError.invalidReply
                    }
                    return MailMailbox(name: row[0], parentName: row[1], unreadCount: unread)
                }
                return try Self.encoded(MailMailboxPage(accountID: accountID, mailboxes: boxes,
                    total: total, nextOffset: offset + boxes.count < total ? offset + boxes.count : nil),
                    requestID: request.id)
            case let .messages(accountID, mailbox, query, searchBody, offset, limit):
                let script = MailScripts.messages(accountID: accountID, mailbox: mailbox,
                    query: query, searchBody: searchBody, offset: offset, limit: limit)
                let rows = try await run(script, timeoutSeconds: searchBody ? 60 : 30)
                let (total, payload) = try Self.pageRows(rows)
                let messages = try payload.map(MailMessageSummary.init)
                let next = offset + messages.count < total ? offset + messages.count : nil
                return try Self.encoded(MailMessagePage(accountID: accountID, mailboxName: mailbox,
                    messages: messages, total: total, nextOffset: next), requestID: request.id)
            case let .get(accountID, mailbox, id):
                let rows = try await run(MailScripts.get(accountID: accountID, mailbox: mailbox, id: id))
                guard rows.count >= 2, let first = rows.first,
                      rows[1].count == 3, rows[1][0] == "attachments_meta",
                      let attachmentTotal = Int(rows[1][1]), attachmentTotal >= 0,
                      ["true", "false"].contains(rows[1][2]) else { throw MailError.invalidReply }
                let attachments = try rows.dropFirst(2).map(MailAttachment.init)
                guard attachments.count == min(attachmentTotal, 100),
                      rows[1][2] == String(attachmentTotal > attachments.count) else {
                    throw MailError.invalidReply
                }
                return try Self.encoded(try MailMessageDetail(first, attachments: attachments,
                    attachmentTotal: attachmentTotal),
                                        requestID: request.id)
            case let .mark(accountID, mailbox, id, expectedSubject, expectedSender, read, flagged):
                mutationStarted = true
                let rows = try await run(MailScripts.mark(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: expectedSubject, expectedSender: expectedSender, read: read, flagged: flagged))
                guard rows.count == 1, rows[0].count == 3, rows[0][0] == String(id),
                      ["true", "false"].contains(rows[0][1]),
                      ["true", "false"].contains(rows[0][2]),
                      (read.map { rows[0][1] == String($0) } ?? true),
                      (flagged.map { rows[0][2] == String($0) } ?? true) else {
                    throw MailError.unverifiedMutation
                }
                var result = try Self.encoded(MailStatusReceipt(id: id, read: rows[0][1] == "true",
                    flagged: rows[0][2] == "true"), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .move(accountID, mailbox, id, expectedSubject, expectedSender,
                           destinationAccountID, destinationMailbox):
                mutationStarted = true
                let rows = try await run(MailScripts.move(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: expectedSubject, expectedSender: expectedSender,
                    destinationAccountID: destinationAccountID, destinationMailbox: destinationMailbox))
                guard rows.count == 1, rows[0].count == 3, rows[0][0] == String(id),
                      rows[0][1] == "0", rows[0][2] == "1" else {
                    throw MailError.unverifiedMutation
                }
                var result = try Self.encoded(MailMoveReceipt(id: id, sourceMailbox: mailbox,
                    destinationMailbox: destinationMailbox), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .delete(accountID, mailbox, id, expectedSubject, expectedSender):
                mutationStarted = true
                let rows = try await run(MailScripts.delete(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: expectedSubject, expectedSender: expectedSender))
                guard rows.count == 1, rows[0].count == 2, rows[0][0] == String(id),
                      rows[0][1] == "0" else { throw MailError.unverifiedMutation }
                var result = try Self.encoded(MailDeletionReceipt(id: id, removedFromSource: true),
                                              requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .compose(accountID, sender, to, cc, bcc, subject, body, send):
                mutationStarted = true
                let rows = try await run(MailScripts.compose(accountID: accountID, sender: sender,
                    to: to, cc: cc, bcc: bcc, subject: subject, body: body, send: send),
                    timeoutSeconds: 60)
                // A missing sender readback is tolerated for drafts; the account check ran before saving.
                guard rows.count == 1, rows[0].count == 4,
                      rows[0][0] == (send ? "submitted" : "draft"),
                      rows[0][2] == subject,
                      Self.senderMatches(rows[0][3], address: sender) || (!send && rows[0][3].isEmpty),
                      let id = Int(rows[0][1]), id > 0 else { throw MailError.unverifiedMutation }
                var result = try Self.encoded(MailComposeReceipt(id: id,
                    status: send ? "submitted_to_mail_not_confirmed_delivered" : "save_accepted_not_confirmed_in_drafts",
                    recipientCount: to.count + cc.count + bcc.count), requestID: request.id)
                result.actionOutcome = .unverified
                return result
            }
        } catch {
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            if ["mail_mark", "mail_move", "mail_delete", "mail_draft", "mail_send"].contains(request.name) {
                result.actionOutcome = mutationStarted ? .unknown : .suspectedAbsent
            }
            return result
        }
    }

    public func cancel(requestID: String) async {}

    private func run(_ script: String, timeoutSeconds: Int = 30) async throws -> [[String]] {
        try await runner.run(script, helpers: MailScripts.helpers, timeoutSeconds: timeoutSeconds)
    }

    /// Mail reports a sender as "Full Name <address>" or a bare address.
    nonisolated static func senderMatches(_ reported: String, address: String) -> Bool {
        let value = reported.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expected = address.lowercased()
        return value == expected || value.hasSuffix("<\(expected)>")
    }

    private nonisolated static func pageRows(_ rows: [[String]]) throws -> (Int, ArraySlice<[String]>) {
        guard let first = rows.first, first.count == 2, first[0] == "meta",
              let total = Int(first[1]), total >= 0, rows.count <= 101 else {
            throw MailError.invalidReply
        }
        return (total, rows.dropFirst())
    }

    private nonisolated static func encoded<T: Encodable>(_ value: T, requestID: String) throws -> ToolResult {
        ToolResult(requestID: requestID, content: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}

private enum MailArguments {
    case accounts
    case mailboxes(accountID: String, offset: Int, limit: Int)
    case messages(accountID: String, mailbox: String, query: String?, searchBody: Bool,
                  offset: Int, limit: Int)
    case get(accountID: String, mailbox: String, id: Int)
    case mark(accountID: String, mailbox: String, id: Int, expectedSubject: String,
              expectedSender: String, read: Bool?, flagged: Bool?)
    case move(accountID: String, mailbox: String, id: Int, expectedSubject: String,
              expectedSender: String, destinationAccountID: String, destinationMailbox: String)
    case delete(accountID: String, mailbox: String, id: Int, expectedSubject: String,
                expectedSender: String)
    case compose(accountID: String, sender: String, to: [String], cc: [String], bcc: [String],
                 subject: String, body: String, send: Bool)

    init(_ request: ToolRequest) throws {
        let values = request.arguments
        func field(_ name: String, max: Int) throws -> String? {
            guard let raw = values[name] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= max,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw MailError.invalidArgument
            }
            return value
        }
        func exactSubject() throws -> String? {
            guard let value = values["expected_subject"] else { return nil }
            guard value.utf8.count <= 1_000,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw MailError.invalidArgument
            }
            return value
        }
        func page() throws -> (Int, Int) {
            guard let offset = Int(values["offset"] ?? "0"), (0...100_000).contains(offset),
                  let limit = Int(values["limit"] ?? "50"), (1...100).contains(limit) else {
                throw MailError.invalidArgument
            }
            return (offset, limit)
        }
        func recipients(_ key: String, required: Bool) throws -> [String] {
            guard let raw = values[key] else {
                if required { throw MailError.invalidArgument }
                return []
            }
            guard let data = raw.data(using: .utf8),
                  let addresses = try? JSONDecoder().decode([String].self, from: data),
                  addresses.count <= 7, (!required || !addresses.isEmpty) else {
                throw MailError.invalidArgument
            }
            for address in addresses {
                guard address.utf8.count <= 320,
                      (try? MissionResource(kind: .recipient, identifier: address))?.identifier == address.lowercased() else {
                    throw MailError.invalidArgument
                }
            }
            return addresses
        }
        switch request.name {
        case "mail_accounts": self = .accounts
        case "mail_mailboxes":
            guard let id = try field("account_id", max: 512) else { throw MailError.invalidArgument }
            let (offset, limit) = try page()
            self = .mailboxes(accountID: id, offset: offset, limit: limit)
        case "mail_messages", "mail_search":
            guard let id = try field("account_id", max: 512),
                  let mailbox = try field("mailbox_name", max: 512) else {
                throw MailError.invalidArgument
            }
            let query = try field("query", max: 200)
            guard request.name != "mail_search" || query != nil else { throw MailError.invalidArgument }
            guard request.name != "mail_messages" || query == nil else { throw MailError.invalidArgument }
            let rawSearchBody = values["search_body"] ?? "false"
            guard ["true", "false"].contains(rawSearchBody),
                  request.name == "mail_search" || rawSearchBody == "false" else {
                throw MailError.invalidArgument
            }
            let (offset, limit) = try page()
            self = .messages(accountID: id, mailbox: mailbox, query: query,
                searchBody: rawSearchBody == "true", offset: offset, limit: limit)
        case "mail_get":
            guard let accountID = try field("account_id", max: 512),
                  let mailbox = try field("mailbox_name", max: 512),
                  let id = Int(values["id"] ?? ""), id > 0 else { throw MailError.invalidArgument }
            self = .get(accountID: accountID, mailbox: mailbox, id: id)
        case "mail_mark", "mail_move", "mail_delete":
            guard let accountID = try field("account_id", max: 512),
                  let mailbox = try field("mailbox_name", max: 512),
                  let id = Int(values["id"] ?? ""), id > 0,
                  let subject = try exactSubject(),
                  let sender = try field("expected_sender", max: 1_000) else {
                throw MailError.invalidArgument
            }
            if request.name == "mail_mark" {
                func boolean(_ key: String) throws -> Bool? {
                    guard let raw = values[key] else { return nil }
                    guard ["true", "false"].contains(raw) else { throw MailError.invalidArgument }
                    return raw == "true"
                }
                let read = try boolean("read")
                let flagged = try boolean("flagged")
                guard read != nil || flagged != nil else { throw MailError.invalidArgument }
                self = .mark(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: subject, expectedSender: sender, read: read, flagged: flagged)
            } else if request.name == "mail_move" {
                guard let destinationAccountID = try field("destination_account_id", max: 512),
                      let destinationMailbox = try field("destination_mailbox_name", max: 512),
                      destinationAccountID != accountID || destinationMailbox != mailbox else {
                    throw MailError.invalidArgument
                }
                self = .move(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: subject, expectedSender: sender,
                    destinationAccountID: destinationAccountID, destinationMailbox: destinationMailbox)
            } else {
                self = .delete(accountID: accountID, mailbox: mailbox, id: id,
                    expectedSubject: subject, expectedSender: sender)
            }
        case "mail_draft", "mail_send":
            guard let accountID = try field("account_id", max: 512),
                  let sender = try field("sender_address", max: 320),
                  (try? MissionResource(kind: .recipient, identifier: sender)) != nil,
                  let subject = try field("subject", max: 1_000),
                  let body = values["body"], body.utf8.count <= 32_000,
                  body.unicodeScalars.allSatisfy({ scalar in
                      !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
                  }) else { throw MailError.invalidArgument }
            let to = try recipients("to", required: true)
            let cc = try recipients("cc", required: false)
            let bcc = try recipients("bcc", required: false)
            guard to.count + cc.count + bcc.count <= 7 else { throw MailError.invalidArgument }
            self = .compose(accountID: accountID, sender: sender, to: to, cc: cc, bcc: bcc,
                subject: subject, body: body, send: request.name == "mail_send")
        default: throw MailError.invalidArgument
        }
    }
}

enum MailScripts {
    // The protected system application is the intended automation target.
    // A bundle-ID lookup depends on per-user LaunchServices registration even
    // when AppleScript only compiles a dictionary in a fresh isolated profile.
    static let applicationTarget = "\"/System/Applications/Mail.app\""
    static let helpers = NotesScripts.safeText

    static func literal(_ value: String) -> String { NotesScripts.literal(value) }

    private static func mailText(_ value: String) -> String {
        let parts = value.components(separatedBy: "\n")
        return parts.map { part in
            part.components(separatedBy: "\t").map(literal).joined(separator: " & tab & ")
        }.joined(separator: " & linefeed & ")
    }

    static let accounts = """
    set out to {}
    tell application \(applicationTarget)
        repeat with acct in every account
            set accountID to my safeText(id of acct)
            set end of out to {"account", accountID, my safeText(name of acct), my safeText(full name of acct), my safeText(account type of acct)}
            -- Copy to a local list first: iterating Mail's property yields
            -- references that do not coerce to text.
            set addressList to (email addresses of acct) as list
            repeat with i from 1 to count of addressList
                set end of out to {"email", accountID, my safeText(item i of addressList)}
            end repeat
        end repeat
    end tell
    return out
    """

    static func mailboxes(accountID: String, offset: Int = 0, limit: Int = 50) -> String {
        """
        set out to {}
        tell application \(applicationTarget)
            set acctRef to first account whose id is \(literal(accountID))
            set allBoxes to every mailbox of acctRef
            set total to count of allBoxes
            set end of out to {"meta", total as string}
            set firstIndex to \(offset) + 1
            set lastIndex to \(offset) + \(limit)
            if lastIndex > total then set lastIndex to total
            repeat with i from firstIndex to lastIndex
                set boxRef to item i of allBoxes
                set parentName to ""
                try
                    set parentName to my safeText(name of container of boxRef)
                end try
                set end of out to {my safeText(name of boxRef), parentName, my safeText(unread count of boxRef)}
            end repeat
        end tell
        return out
        """
    }

    private static func selectMailbox(accountID: String, mailbox: String) -> String {
        """
        set acctRef to first account whose id is \(literal(accountID))
        set matchingBoxes to every mailbox of acctRef whose name is \(literal(mailbox))
        if (count of matchingBoxes) is not 1 then error "AIM_MAILBOX_NOT_UNIQUE"
        set boxRef to item 1 of matchingBoxes
        """
    }

    private static func bulk(_ variable: String, property: String) -> String {
        """
        set \(variable) to {}
        try
            set \(variable) to \(property) of selectedMessages
        on error
            repeat with oneMessage in selectedMessages
                set oneValue to ""
                try
                    set oneValue to \(property) of oneMessage
                end try
                set end of \(variable) to oneValue
            end repeat
        end try
        """
    }

    static func messages(accountID: String, mailbox: String, query: String?, searchBody: Bool,
                         offset: Int, limit: Int) -> String {
        let collection: String
        if let query {
            let q = literal(query)
            let clause = searchBody
                ? "(subject contains \(q)) or (sender contains \(q)) or (content contains \(q))"
                : "(subject contains \(q)) or (sender contains \(q))"
            collection = "(messages of boxRef whose \(clause))"
        } else { collection = "every message of boxRef" }
        return """
        set out to {}
        tell application \(applicationTarget)
            \(selectMailbox(accountID: accountID, mailbox: mailbox))
            set allMessages to \(collection)
            set total to count of allMessages
            set end of out to {"meta", total as string}
            set lastIndex to total - \(offset)
            set firstIndex to lastIndex - \(limit) + 1
            if firstIndex < 1 then set firstIndex to 1
            if lastIndex > 0 then
                set selectedMessages to items firstIndex thru lastIndex of allMessages
                \(bulk("idValues", property: "id"))
                \(bulk("subjectValues", property: "subject"))
                \(bulk("senderValues", property: "sender"))
                \(bulk("dateValues", property: "date received"))
                \(bulk("readValues", property: "read status"))
                \(bulk("flagValues", property: "flagged status"))
                repeat with i from (count of idValues) to 1 by -1
                    set end of out to {my safeText(item i of idValues), my safeText(item i of subjectValues), my safeText(item i of senderValues), my safeText(item i of dateValues), my safeText(item i of readValues), my safeText(item i of flagValues)}
                end repeat
            end if
        end tell
        return out
        """
    }

    static func get(accountID: String, mailbox: String, id: Int) -> String {
        """
        set out to {}
        tell application \(applicationTarget)
            \(selectMailbox(accountID: accountID, mailbox: mailbox))
            set msgRef to first message of boxRef whose id is \(id)
            set messageText to my safeText(content of msgRef)
            if (length of messageText) > 500000 then error "AIM_MAIL_MESSAGE_TOO_LARGE"
            set end of out to {"message", my safeText(id of msgRef), my safeText(subject of msgRef), my safeText(sender of msgRef), messageText, my safeText(date received of msgRef), my safeText(date sent of msgRef), my safeText(read status of msgRef), my safeText(flagged status of msgRef), my safeText(message id of msgRef)}
            set allAttachments to mail attachments of msgRef
            set attachmentTotal to count of allAttachments
            set attachmentLimit to attachmentTotal
            if attachmentLimit > 100 then set attachmentLimit to 100
            set truncatedAttachments to false
            if attachmentTotal > attachmentLimit then set truncatedAttachments to true
            set end of out to {"attachments_meta", attachmentTotal as string, my safeText(truncatedAttachments)}
            repeat with attachmentIndex from 1 to attachmentLimit
                set attachmentRef to item attachmentIndex of allAttachments
                set end of out to {"attachment", my safeText(id of attachmentRef), my safeText(name of attachmentRef), my safeText(MIME type of attachmentRef), my safeText(file size of attachmentRef), my safeText(downloaded of attachmentRef)}
            end repeat
        end tell
        return out
        """
    }

    private static func selectMessage(accountID: String, mailbox: String, id: Int,
                                      expectedSubject: String, expectedSender: String) -> String {
        """
        \(selectMailbox(accountID: accountID, mailbox: mailbox))
        set msgRef to first message of boxRef whose id is \(id)
        if (my safeText(subject of msgRef)) is not \(literal(expectedSubject)) then error "AIM_MAIL_MESSAGE_CHANGED"
        if (my safeText(sender of msgRef)) is not \(literal(expectedSender)) then error "AIM_MAIL_MESSAGE_CHANGED"
        """
    }

    static func mark(accountID: String, mailbox: String, id: Int,
                     expectedSubject: String, expectedSender: String,
                     read: Bool?, flagged: Bool?) -> String {
        let readLine = read.map { "set read status of msgRef to \($0 ? "true" : "false")" } ?? ""
        let flagLine = flagged.map { "set flagged status of msgRef to \($0 ? "true" : "false")" } ?? ""
        return """
        tell application \(applicationTarget)
            \(selectMessage(accountID: accountID, mailbox: mailbox, id: id,
                             expectedSubject: expectedSubject, expectedSender: expectedSender))
            \(readLine)
            \(flagLine)
            return {{my safeText(id of msgRef), my safeText(read status of msgRef), my safeText(flagged status of msgRef)}}
        end tell
        """
    }

    static func move(accountID: String, mailbox: String, id: Int,
                     expectedSubject: String, expectedSender: String,
                     destinationAccountID: String, destinationMailbox: String) -> String {
        """
        tell application \(applicationTarget)
            \(selectMessage(accountID: accountID, mailbox: mailbox, id: id,
                             expectedSubject: expectedSubject, expectedSender: expectedSender))
            set destinationAccount to first account whose id is \(literal(destinationAccountID))
            set destinationMatches to every mailbox of destinationAccount whose name is \(literal(destinationMailbox))
            if (count of destinationMatches) is not 1 then error "AIM_DESTINATION_MAILBOX_NOT_UNIQUE"
            set destinationBox to item 1 of destinationMatches
            move msgRef to destinationBox
            set remainingSource to count of (messages of boxRef whose id is \(id))
            repeat 10 times
                if remainingSource is 0 then exit repeat
                delay 0.5
                set remainingSource to count of (messages of boxRef whose id is \(id))
            end repeat
            set presentDestination to count of (messages of destinationBox whose id is \(id))
            return {{\(literal(String(id))), remainingSource as string, presentDestination as string}}
        end tell
        """
    }

    static func delete(accountID: String, mailbox: String, id: Int,
                       expectedSubject: String, expectedSender: String) -> String {
        """
        tell application \(applicationTarget)
            \(selectMessage(accountID: accountID, mailbox: mailbox, id: id,
                             expectedSubject: expectedSubject, expectedSender: expectedSender))
            delete msgRef
            -- IMAP mailboxes apply the deletion asynchronously and may keep a
            -- message flagged as deleted until expunge; neither counts as present.
            set remainingSource to count of (messages of boxRef whose id is \(id) and deleted status is false)
            repeat 10 times
                if remainingSource is 0 then exit repeat
                delay 0.5
                set remainingSource to count of (messages of boxRef whose id is \(id) and deleted status is false)
            end repeat
            return {{\(literal(String(id))), remainingSource as string}}
        end tell
        """
    }

    static func compose(accountID: String, sender: String, to: [String], cc: [String],
                        bcc: [String], subject: String, body: String, send: Bool) -> String {
        let toLines = to.map { "make new to recipient at end of to recipients of msgRef with properties {address:\(literal($0))}" }
        let ccLines = cc.map { "make new cc recipient at end of cc recipients of msgRef with properties {address:\(literal($0))}" }
        let bccLines = bcc.map { "make new bcc recipient at end of bcc recipients of msgRef with properties {address:\(literal($0))}" }
        let ending = send ? """
            set accepted to send msgRef
            if accepted is not true then error "AIM_MAIL_SEND_REJECTED"
            return {{"submitted", messageID as string, \(literal(subject)), \(literal(sender))}}
            """ : """
            save msgRef
            -- An unsaved outgoing message has no stable id: confirm the draft that
            -- Mail actually stored (newest one with this exact subject) and return it.
            repeat 20 times
                delay 0.5
                set found to (messages of drafts mailbox whose subject is \(literal(subject)))
                if (count of found) > 0 then
                    set draftRef to item -1 of found
                    return {{"draft", (id of draftRef) as string, my safeText(subject of draftRef), my safeText(sender of draftRef)}}
                end if
            end repeat
            error "AIM_MAIL_DRAFT_NOT_FOUND"
            """
        return """
        tell application \(applicationTarget)
            set acctRef to first account whose id is \(literal(accountID))
            set matchingSender to false
            set addressList to (email addresses of acctRef) as list
            repeat with i from 1 to count of addressList
                if (my safeText(item i of addressList)) is \(literal(sender)) then set matchingSender to true
            end repeat
            if matchingSender is false then error "AIM_MAIL_SENDER_NOT_IN_ACCOUNT"
            set msgRef to make new outgoing message with properties {subject:\(literal(subject)), content:\(mailText(body)), visible:false, sender:\(literal(sender))}
            \((toLines + ccLines + bccLines).joined(separator: "\n            "))
            set messageID to id of msgRef
            \(ending)
        end tell
        """
    }
}

private struct MailAccount: Encodable, Sendable {
    let id: String
    let name: String
    let fullName: String
    let type: String
    var emailAddresses: [String]
}

private struct MailMailbox: Encodable, Sendable {
    let name: String
    let parentName: String
    let unreadCount: Int
}

private struct MailMailboxPage: Encodable, Sendable {
    let accountID: String
    let mailboxes: [MailMailbox]
    let total: Int
    let nextOffset: Int?
}

private struct MailMessageSummary: Encodable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let received: String
    let read: Bool
    let flagged: Bool

    init(_ row: [String]) throws {
        guard row.count == 6, let id = Int(row[0]), id > 0,
              ["true", "false"].contains(row[4]), ["true", "false"].contains(row[5]) else {
            throw MailError.invalidReply
        }
        self.id = id; subject = row[1]; sender = row[2]; received = row[3]
        read = row[4] == "true"; flagged = row[5] == "true"
    }
}

private struct MailMessagePage: Encodable, Sendable {
    let accountID: String
    let mailboxName: String
    let messages: [MailMessageSummary]
    let total: Int
    let nextOffset: Int?
}

private struct MailAttachment: Encodable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
    let downloaded: Bool

    init(_ row: [String]) throws {
        guard row.count == 6, row[0] == "attachment", let size = Int(row[4]), size >= 0,
              ["true", "false"].contains(row[5]) else {
            throw MailError.invalidReply
        }
        id = row[1]; name = row[2]; mimeType = row[3]
        self.size = size; downloaded = row[5] == "true"
    }
}

private struct MailMessageDetail: Encodable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let content: String
    let received: String
    let sent: String
    let read: Bool
    let flagged: Bool
    let rfcMessageID: String
    let attachments: [MailAttachment]
    let attachmentTotal: Int
    let attachmentsTruncated: Bool

    init(_ row: [String], attachments: [MailAttachment], attachmentTotal: Int) throws {
        guard row.count == 10, row[0] == "message", let id = Int(row[1]), id > 0,
              ["true", "false"].contains(row[7]), ["true", "false"].contains(row[8]) else {
            throw MailError.invalidReply
        }
        self.id = id; subject = row[2]; sender = row[3]; content = row[4]
        received = row[5]; sent = row[6]; read = row[7] == "true"
        flagged = row[8] == "true"; rfcMessageID = row[9]
        self.attachments = attachments
        self.attachmentTotal = attachmentTotal
        attachmentsTruncated = attachmentTotal > attachments.count
    }
}

private struct MailStatusReceipt: Encodable, Sendable {
    let id: Int
    let read: Bool
    let flagged: Bool
}

private struct MailMoveReceipt: Encodable, Sendable {
    let id: Int
    let sourceMailbox: String
    let destinationMailbox: String
}

private struct MailDeletionReceipt: Encodable, Sendable {
    let id: Int
    let removedFromSource: Bool
}

private struct MailComposeReceipt: Encodable, Sendable {
    let id: Int
    let status: String
    let recipientCount: Int
}

private enum MailError: LocalizedError {
    case invalidArgument, invalidReply, unverifiedMutation

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Invalid Mail arguments. Use exact account IDs and unambiguous mailbox names; list/search pages are at most 100 messages."
        case .invalidReply: "Mail returned an unexpected result. Refresh the account and mailbox before retrying."
        case .unverifiedMutation: "Mail may have changed the message, but AIM could not verify the result. Inspect Mail before retrying."
        }
    }
}
