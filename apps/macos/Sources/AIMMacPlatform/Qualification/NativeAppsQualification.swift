#if DEBUG
import AIMAgentKit
import AppKit
import EventKit
import Foundation

/// Real qualification of the Calendar, Reminders, Notes and Mail adapters in
/// dedicated "AIM Test" containers that are created and removed by the suite.
/// Mail is read (counts only, never content) and a draft to the account's own
/// address is created then deleted; `mail_send` is never called.
public enum NativeAppsQualification {
    public static func run(into report: QualificationReport, apps: Set<String>) async {
        let tag = "AIM Test \(UUID().uuidString.prefix(6))"
        report.set("container_name", tag)
        if apps.contains("calendar") { report.set("calendar", await calendar(tag: tag)); report.checkpoint() }
        if apps.contains("reminders") { report.set("reminders", await reminders(tag: tag)); report.checkpoint() }
        if apps.contains("notes") { report.set("notes", await notes(tag: tag)); report.checkpoint() }
        if apps.contains("mail") { report.set("mail", await mail(tag: tag)); report.checkpoint() }
        var failed: [String] = []
        for app in apps.sorted() {
            if (report.value(app) as? [String: Any])?["passed"] as? Bool != true { failed.append(app) }
        }
        report.set("conclusion", failed.isEmpty ? "all native app cases passed (\(apps.count))" :
            "failed: \(failed.joined(separator: ", "))")
    }

    private static func call(_ service: any ToolExecutor, _ name: String, _ arguments: [String: String],
                             risk: ToolRisk = .computerAction) async -> (result: ToolResult, json: [String: Any]?) {
        let result = await service.execute(ToolRequest(name: name, arguments: arguments, risk: risk))
        let json = result.content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (result, json)
    }

    /// Adapter JSON escapes "/" in identifiers; compare decoded values.
    static func containsID(_ content: String, _ id: String) -> Bool {
        guard let data = content.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func search(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary["id"] as? String == id || dictionary.values.contains(where: search)
            }
            if let array = value as? [Any] { return array.contains(where: search) }
            return false
        }
        return search(object)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Calendar

    private static func calendar(tag: String) async -> [String: Any] {
        var record: [String: Any] = ["passed": false]
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else {
            record["error"] = "Calendar full access was not granted to AIM."
            return record
        }
        let container = EKCalendar(for: .event, eventStore: store)
        container.title = tag
        guard let source = store.sources.first(where: { $0.sourceType == .local }) ??
                store.defaultCalendarForNewEvents?.source else {
            record["error"] = "No calendar source is available."
            return record
        }
        container.source = source
        do { try store.saveCalendar(container, commit: true) } catch {
            record["error"] = "Test calendar could not be created: \(error.localizedDescription)"
            return record
        }
        record["source_kind"] = source.sourceType == .local ? "local" : "account"
        defer { try? store.removeCalendar(container, commit: true) }
        let service = MacCalendarToolService()
        var steps: [String: Bool] = [:]
        let start = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let startISO = iso(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: start)!)
        let endISO = iso(Calendar.current.date(bySettingHour: 10, minute: 30, second: 0, of: start)!)
        let created = await call(service, "calendar_create", ["title": "AIM Test event", "start_iso": startISO,
            "end_iso": endISO, "calendar_id": container.calendarIdentifier, "notes": "Created by AIM qualification"])
        steps["create"] = !created.result.isError
        guard let id = created.json?["id"] as? String else {
            record["steps"] = steps
            record["error"] = String(created.result.content.prefix(300))
            return record
        }
        let fetched = await call(service, "calendar_get", ["id": id], risk: .computerRead)
        steps["get"] = fetched.json?["title"] as? String == "AIM Test event"
        let listed = await call(service, "calendar_events", ["start_iso": startISO, "end_iso": endISO,
            "calendar_id": container.calendarIdentifier], risk: .computerRead)
        steps["list"] = Self.containsID(listed.result.content, id)
        let updated = await call(service, "calendar_update", ["id": id, "expected_title": "AIM Test event",
            "expected_start_iso": startISO, "expected_end_iso": endISO, "title": "AIM Test event edited"])
        let reread = await call(service, "calendar_get", ["id": id], risk: .computerRead)
        steps["update"] = !updated.result.isError && reread.json?["title"] as? String == "AIM Test event edited"
        let stale = await call(service, "calendar_update", ["id": id, "expected_title": "AIM Test event",
            "expected_start_iso": startISO, "expected_end_iso": endISO, "title": "Should not apply"])
        steps["stale_precondition_refused"] = stale.result.isError
        let deleted = await call(service, "calendar_delete", ["id": id, "expected_title": "AIM Test event edited",
            "expected_start_iso": startISO, "expected_end_iso": endISO])
        let gone = await call(service, "calendar_get", ["id": id], risk: .computerRead)
        steps["delete"] = !deleted.result.isError && gone.result.isError
        record["steps"] = steps
        record["passed"] = steps.values.allSatisfy { $0 }
        return record
    }

    // MARK: Reminders

    private static func reminders(tag: String) async -> [String: Any] {
        var record: [String: Any] = ["passed": false]
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else {
            record["error"] = "Reminders full access was not granted to AIM."
            return record
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = tag
        guard let source = store.defaultCalendarForNewReminders()?.source ??
                store.sources.first(where: { $0.sourceType == .local }) else {
            record["error"] = "No reminders source is available."
            return record
        }
        list.source = source
        do { try store.saveCalendar(list, commit: true) } catch {
            record["error"] = "Test list could not be created: \(error.localizedDescription)"
            return record
        }
        defer { try? store.removeCalendar(list, commit: true) }
        let service = MacRemindersToolService()
        var steps: [String: Bool] = [:]
        let due = iso(Calendar.current.date(byAdding: .day, value: 2, to: .now)!)
        let created = await call(service, "reminders_create", ["title": "AIM Test reminder", "notes": "Qualification",
            "due_iso": due, "list_id": list.calendarIdentifier])
        steps["create"] = !created.result.isError
        guard let id = created.json?["id"] as? String else {
            record["steps"] = steps
            record["error"] = String(created.result.content.prefix(300))
            return record
        }
        let fetched = await call(service, "reminders_get", ["id": id], risk: .computerRead)
        steps["get"] = fetched.json?["title"] as? String == "AIM Test reminder"
        let listed = await call(service, "reminders_list", ["list_id": list.calendarIdentifier], risk: .computerRead)
        steps["list"] = Self.containsID(listed.result.content, id)
        let updated = await call(service, "reminders_update", ["id": id, "expected_title": "AIM Test reminder",
            "title": "AIM Test reminder edited", "clear_due": "true"])
        let reread = await call(service, "reminders_get", ["id": id], risk: .computerRead)
        steps["update"] = !updated.result.isError && reread.json?["title"] as? String == "AIM Test reminder edited" &&
            reread.json?["dueISO"] == nil
        let completed = await call(service, "reminders_complete", ["id": id, "completed": "true"])
        let afterComplete = await call(service, "reminders_get", ["id": id], risk: .computerRead)
        steps["complete"] = !completed.result.isError && afterComplete.json?["completed"] as? Bool == true
        let stale = await call(service, "reminders_delete", ["id": id, "expected_title": "AIM Test reminder"])
        steps["stale_precondition_refused"] = stale.result.isError
        let deleted = await call(service, "reminders_delete", ["id": id, "expected_title": "AIM Test reminder edited"])
        let gone = await call(service, "reminders_get", ["id": id], risk: .computerRead)
        steps["delete"] = !deleted.result.isError && gone.result.isError
        record["steps"] = steps
        record["passed"] = steps.values.allSatisfy { $0 }
        return record
    }

    // MARK: Notes

    @MainActor
    private static func appleScript(_ source: String) -> (String?, String?) {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (output?.stringValue, error?[NSAppleScript.errorMessage] as? String)
    }

    private static func notes(tag: String) async -> [String: Any] {
        var record: [String: Any] = ["passed": false]
        let escaped = tag.replacingOccurrences(of: "\"", with: "")
        let (folderID, createError) = await MainActor.run {
            appleScript("tell application \"Notes\" to return id of (make new folder with properties {name:\"\(escaped)\"})")
        }
        guard let folderID, !folderID.isEmpty else {
            record["error"] = "Test folder could not be created: \(createError ?? "unknown")"
            return record
        }
        defer {
            Task { @MainActor in
                _ = appleScript("tell application \"Notes\" to delete folder id \"\(folderID)\"")
            }
        }
        let service = MacNotesToolService()
        var steps: [String: Bool] = [:]
        let folders = await call(service, "notes_folders", [:], risk: .computerRead)
        steps["folders"] = (folders.json?["folders"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == folderID }
        let created = await call(service, "notes_create", ["title": "AIM Test note", "body": "Line one é 日本",
                                                          "folder_id": folderID])
        steps["create"] = !created.result.isError
        guard let id = created.json?["id"] as? String else {
            record["steps"] = steps
            record["error"] = String(created.result.content.prefix(300))
            return record
        }
        var detail = await call(service, "notes_get", ["id": id], risk: .computerRead)
        steps["get"] = (detail.json?["plaintext"] as? String)?.contains("Line one é 日本") == true
        if let modified = detail.json?["modified"] as? String {
            let appended = await call(service, "notes_append", ["id": id, "expected_modified": modified, "text": "Line two"])
            detail = await call(service, "notes_get", ["id": id], risk: .computerRead)
            steps["append"] = !appended.result.isError && (detail.json?["plaintext"] as? String)?.contains("Line two") == true
            let stale = await call(service, "notes_append", ["id": id, "expected_modified": modified, "text": "Stale"])
            steps["stale_precondition_refused"] = stale.result.isError
        }
        if let modified = detail.json?["modified"] as? String {
            let replaced = await call(service, "notes_replace", ["id": id, "expected_modified": modified,
                "title": "AIM Test note replaced", "body": "Replaced body"])
            detail = await call(service, "notes_get", ["id": id], risk: .computerRead)
            steps["replace"] = !replaced.result.isError && (detail.json?["plaintext"] as? String)?.contains("Replaced body") == true
        }
        let searched = await call(service, "notes_search", ["query": "Replaced", "folder_id": folderID], risk: .computerRead)
        steps["search"] = (searched.json?["notes"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id }
        if let modified = detail.json?["modified"] as? String {
            let deleted = await call(service, "notes_delete", ["id": id, "expected_modified": modified])
            steps["delete"] = !deleted.result.isError
        }
        record["steps"] = steps
        record["passed"] = steps.values.allSatisfy { $0 } && steps.count >= 8
        return record
    }

    // MARK: Mail (reads and one draft; never send)

    private static func mail(tag: String) async -> [String: Any] {
        var record: [String: Any] = ["passed": false]
        let service = MacMailToolService()
        var steps: [String: Bool] = [:]
        let accounts = await call(service, "mail_accounts", [:], risk: .computerRead)
        let rows = (accounts.result.content.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ??
            (accounts.json?["accounts"] as? [[String: Any]] ?? [])
        steps["accounts"] = !accounts.result.isError && !rows.isEmpty
        record["account_count"] = rows.count
        guard let account = rows.first(where: { !($0["emailAddresses"] as? [String] ?? []).isEmpty }),
              let accountID = account["id"] as? String,
              let address = (account["emailAddresses"] as? [String])?.first else {
            record["steps"] = steps
            record["error"] = accounts.result.isError ? String(accounts.result.content.prefix(300)) : "No account with an address."
            return record
        }
        let mailboxes = await call(service, "mail_mailboxes", ["account_id": accountID, "limit": "100"], risk: .computerRead)
        let boxes = mailboxes.json?["mailboxes"] as? [[String: Any]] ?? []
        steps["mailboxes"] = !mailboxes.result.isError && !boxes.isEmpty
        record["mailbox_count"] = boxes.count
        if let inbox = boxes.first(where: { ["INBOX", "Inbox", "Boîte de réception"].contains($0["name"] as? String ?? "") })?["name"] as? String {
            let messages = await call(service, "mail_messages", ["account_id": accountID, "mailbox_name": inbox, "limit": "1"],
                risk: .computerRead)
            steps["read_messages"] = !messages.result.isError
        }
        // Remove drafts left by an earlier interrupted qualification ("AIM Test … draft").
        if let drafts = boxes.first(where: { ["Drafts", "Brouillons"].contains($0["name"] as? String ?? "") })?["name"] as? String {
            let orphans = await call(service, "mail_search", ["account_id": accountID, "mailbox_name": drafts,
                "query": "AIM Test", "limit": "20"], risk: .computerRead)
            var swept = 0
            for message in orphans.json?["messages"] as? [[String: Any]] ?? [] {
                guard let subject = message["subject"] as? String, subject.hasPrefix("AIM Test "), subject.hasSuffix(" draft"),
                      let id = message["id"] as? Int, let sender = message["sender"] as? String else { continue }
                let removed = await call(service, "mail_delete", ["account_id": accountID, "mailbox_name": drafts,
                    "id": String(id), "expected_subject": subject, "expected_sender": sender])
                if !removed.result.isError { swept += 1 } else { record["sweep_error"] = String(removed.result.content.prefix(400)) }
            }
            record["orphan_drafts_removed"] = swept
            // Let Mail finish syncing the removal before the next scripted request.
            if swept > 0 { try? await Task.sleep(for: .seconds(15)) }
        }
        let subject = "\(tag) draft"
        let recipient = address.trimmingCharacters(in: .whitespacesAndNewlines)
        record["address_shape"] = ["length": address.count, "trimmed_length": recipient.count,
                                   "has_uppercase": recipient != recipient.lowercased(),
                                   "has_plus": recipient.contains("+")]
        let to = String(decoding: (try? JSONSerialization.data(withJSONObject: [recipient])) ?? Data(), as: UTF8.self)
        let drafted = await call(service, "mail_draft", ["account_id": accountID, "sender_address": recipient,
            "to": to, "subject": subject, "body": "Draft created by AIM qualification. Safe to delete."])
        steps["draft_accepted"] = !drafted.result.isError
        if drafted.result.isError { record["draft_error"] = String(drafted.result.content.prefix(400)) }
        record["draft_outcome"] = drafted.result.metadata["action_outcome"] ?? NSNull()
        guard let drafts = boxes.first(where: { ["Drafts", "Brouillons"].contains($0["name"] as? String ?? "") })?["name"] as? String else {
            record["steps"] = steps
            record["error"] = "Drafts mailbox not found by name; the draft must be removed manually: \(subject)"
            return record
        }
        var found: [String: Any]?
        for _ in 0..<10 where found == nil {
            try? await Task.sleep(for: .seconds(1))
            let search = await call(service, "mail_search", ["account_id": accountID, "mailbox_name": drafts,
                "query": subject, "limit": "5"], risk: .computerRead)
            found = (search.json?["messages"] as? [[String: Any]])?.first { $0["subject"] as? String == subject }
        }
        steps["draft_persisted"] = found != nil
        if let found, let id = found["id"] as? Int, let sender = found["sender"] as? String {
            let deleted = await call(service, "mail_delete", ["account_id": accountID, "mailbox_name": drafts,
                "id": String(id), "expected_subject": subject, "expected_sender": sender])
            steps["draft_deleted"] = !deleted.result.isError
            if deleted.result.isError { record["delete_error"] = String(deleted.result.content.prefix(400)) }
        } else {
            record["cleanup"] = "Draft not found for deletion: \(subject)"
        }
        record["steps"] = steps
        record["passed"] = steps.values.allSatisfy { $0 }
        return record
    }
}
#endif
