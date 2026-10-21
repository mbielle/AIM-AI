import AIMAgentKit
import AIMApplication
@preconcurrency import EventKit
import Foundation

/// Typed access to Apple Reminders. The model never supplies AppleScript or a
/// generic EventKit command. System permission is requested only after AIM's
/// tool policy has admitted an actual reminder operation.
public actor MacRemindersToolService: ToolExecutor, MissionIntentProviding {
    public nonisolated let supportedTools: Set<String> = [
        "reminders_lists", "reminders_list", "reminders_get", "reminders_create", "reminders_update", "reminders_complete", "reminders_delete"
    ]

    public init() {}

    public nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "reminders_lists", "reminders_list", "reminders_get": operation = .observe
        case "reminders_create", "reminders_update", "reminders_complete": operation = .edit
        case "reminders_delete": operation = .permanentDelete
        default: return nil
        }
        _ = try ReminderArguments(request)
        return MissionToolIntent(operation: operation,
            target: try MissionResource(kind: .application, identifier: "com.apple.reminders"))
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        var mutationStarted = false
        do {
            let arguments = try ReminderArguments(request)
            let store = EKEventStore()
            try await Self.ensureAccess(store)
            try Task.checkCancellation()
            switch arguments {
            case .lists:
                let calendars = store.calendars(for: .reminder)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let output = calendars.map { ReminderList(id: $0.calendarIdentifier, name: $0.title) }
                return try Self.encoded(output, requestID: request.id)
            case let .list(listID, listName, includeCompleted, limit):
                let calendars = try Self.selectedCalendars(store: store, id: listID, name: listName)
                let predicate = store.predicateForReminders(in: calendars)
                let all = await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderSummary], Never>) in
                    store.fetchReminders(matching: predicate) { reminders in
                        let items = (reminders ?? []).map(ReminderSummary.init)
                        continuation.resume(returning: items)
                    }
                }
                try Task.checkCancellation()
                let filtered = all.filter { includeCompleted || !$0.completed }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let page = ReminderPage(reminders: Array(filtered.prefix(limit)),
                                        returned: min(limit, filtered.count),
                                        total: filtered.count, truncated: filtered.count > limit)
                return try Self.encoded(page, requestID: request.id)
            case let .get(id):
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw ReminderError.reminderUnavailable
                }
                return try Self.encoded(ReminderSummary(reminder), requestID: request.id)
            case let .create(title, notes, dueDate, listID, listName):
                let calendars = try Self.selectedCalendars(store: store, id: listID, name: listName)
                guard let calendar = calendars?.onlyElement ?? store.defaultCalendarForNewReminders() else {
                    throw ReminderError.listUnavailable
                }
                let reminder = EKReminder(eventStore: store)
                reminder.title = title
                reminder.notes = notes
                reminder.calendar = calendar
                if let dueDate {
                    var gregorian = Calendar(identifier: .gregorian)
                    gregorian.timeZone = .current
                    var components = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
                    components.calendar = gregorian
                    components.timeZone = gregorian.timeZone
                    reminder.startDateComponents = components
                    reminder.dueDateComponents = components
                    reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
                }
                try Task.checkCancellation()
                mutationStarted = true
                try store.save(reminder, commit: true)
                let identifier = reminder.calendarItemIdentifier
                guard let saved = store.calendarItem(withIdentifier: identifier) as? EKReminder,
                      saved.title == title, saved.calendar.calendarIdentifier == calendar.calendarIdentifier else {
                    return ToolResult(requestID: request.id,
                        content: "Reminders accepted the save, but AIM could not verify the new item. Inspect Reminders before retrying to avoid a duplicate.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(ReminderSummary(saved), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .complete(id, completed):
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw ReminderError.reminderUnavailable
                }
                if reminder.isCompleted != completed {
                    reminder.isCompleted = completed
                    try Task.checkCancellation()
                    mutationStarted = true
                    try store.save(reminder, commit: true)
                }
                guard let saved = store.calendarItem(withIdentifier: id) as? EKReminder,
                      saved.isCompleted == completed else {
                    return ToolResult(requestID: request.id,
                        content: "Reminders accepted the status change, but AIM could not verify it. Inspect this reminder before retrying.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(ReminderSummary(saved), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .update(id, expectedTitle, title, notes, clearNotes, dueDate, clearDue, listID):
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw ReminderError.reminderUnavailable
                }
                guard reminder.title == expectedTitle else { throw ReminderError.reminderChanged }
                guard !reminder.hasRecurrenceRules else { throw ReminderError.recurringReminder }
                guard reminder.calendar.allowsContentModifications else { throw ReminderError.listReadOnly }
                if let title { reminder.title = title }
                if let notes { reminder.notes = notes }
                if clearNotes { reminder.notes = nil }
                if let dueDate { Self.setDueDate(dueDate, on: reminder) }
                if clearDue {
                    let oldDueDate = reminder.dueDateComponents?.date
                    reminder.startDateComponents = nil
                    reminder.dueDateComponents = nil
                    if let oldDueDate {
                        for alarm in reminder.alarms ?? [] where alarm.absoluteDate == oldDueDate {
                            reminder.removeAlarm(alarm)
                        }
                    }
                }
                if let listID {
                    guard let calendar = store.calendars(for: .reminder)
                        .first(where: { $0.calendarIdentifier == listID }) else {
                        throw ReminderError.listUnavailable
                    }
                    guard calendar.allowsContentModifications else { throw ReminderError.listReadOnly }
                    reminder.calendar = calendar
                }
                try Task.checkCancellation()
                mutationStarted = true
                try store.save(reminder, commit: true)
                guard let saved = store.calendarItem(withIdentifier: id) as? EKReminder,
                      saved.title == (title ?? expectedTitle),
                      (notes == nil || saved.notes == notes),
                      (!clearNotes || saved.notes == nil),
                      (dueDate == nil || saved.dueDateComponents?.date == dueDate),
                      (!clearDue || saved.dueDateComponents == nil),
                      (listID == nil || saved.calendar.calendarIdentifier == listID) else {
                    return ToolResult(requestID: request.id,
                        content: "Reminders accepted the edit, but AIM could not verify the result. Inspect this reminder before retrying.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(ReminderSummary(saved), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .delete(id, expectedTitle):
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw ReminderError.reminderUnavailable
                }
                guard reminder.title == expectedTitle else { throw ReminderError.reminderChanged }
                guard !reminder.hasRecurrenceRules else { throw ReminderError.recurringReminder }
                guard reminder.calendar.allowsContentModifications else { throw ReminderError.listReadOnly }
                try Task.checkCancellation()
                mutationStarted = true
                try store.remove(reminder, commit: true)
                guard store.calendarItem(withIdentifier: id) == nil else {
                    return ToolResult(requestID: request.id,
                        content: "Reminders accepted the deletion, but AIM could not verify that this item is gone. Inspect Reminders before retrying.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(ReminderDeletionReceipt(id: id, deleted: true), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            }
        } catch {
            let outcome: ActionOutcome? = ["reminders_create", "reminders_update", "reminders_complete", "reminders_delete"].contains(request.name)
                ? (mutationStarted ? .unknown : .suspectedAbsent) : nil
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            result.actionOutcome = outcome
            return result
        }
    }

    public func cancel(requestID: String) async {}

    private nonisolated static func ensureAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToReminders { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else { throw ReminderError.permissionRequired }
        default: throw ReminderError.permissionRequired
        }
    }

    private nonisolated static func selectedCalendars(store: EKEventStore, id: String?, name: String?) throws -> [EKCalendar]? {
        if let id {
            guard let calendar = store.calendar(withIdentifier: id),
                  store.calendars(for: .reminder).contains(where: { $0.calendarIdentifier == id }) else {
                throw ReminderError.listUnavailable
            }
            return [calendar]
        }
        if let name {
            let matches = store.calendars(for: .reminder).filter { $0.title == name }
            guard matches.count == 1 else { throw ReminderError.listUnavailable }
            return matches
        }
        return nil
    }

    private nonisolated static func setDueDate(_ dueDate: Date, on reminder: EKReminder) {
        let previousDueDate = reminder.dueDateComponents?.date
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        var components = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
        components.calendar = gregorian
        components.timeZone = gregorian.timeZone
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
        if let previousDueDate {
            let matchingAlarms = (reminder.alarms ?? []).filter { $0.absoluteDate == previousDueDate }
            for alarm in matchingAlarms { reminder.removeAlarm(alarm) }
            if !matchingAlarms.isEmpty { reminder.addAlarm(EKAlarm(absoluteDate: dueDate)) }
        }
    }

    private nonisolated static func encoded<T: Encodable>(_ value: T, requestID: String) throws -> ToolResult {
        let data = try JSONEncoder().encode(value)
        return ToolResult(requestID: requestID, content: String(decoding: data, as: UTF8.self))
    }
}

private extension Collection {
    var onlyElement: Element? { count == 1 ? first : nil }
}

private enum ReminderArguments {
    case lists
    case list(id: String?, name: String?, includeCompleted: Bool, limit: Int)
    case get(id: String)
    case create(title: String, notes: String?, dueDate: Date?, id: String?, name: String?)
    case update(id: String, expectedTitle: String, title: String?, notes: String?, clearNotes: Bool,
                dueDate: Date?, clearDue: Bool, listID: String?)
    case complete(id: String, completed: Bool)
    case delete(id: String, expectedTitle: String)

    init(_ request: ToolRequest) throws {
        let values = request.arguments
        func optional(_ key: String, maximum: Int) throws -> String? {
            guard let raw = values[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0") else {
                throw ReminderError.invalidArgument
            }
            return value
        }
        switch request.name {
        case "reminders_lists": self = .lists
        case "reminders_list":
            let id = try optional("list_id", maximum: 512)
            let name = try optional("list_name", maximum: 512)
            guard id == nil || name == nil else { throw ReminderError.invalidArgument }
            let include = values["include_completed"] ?? "false"
            guard ["true", "false"].contains(include),
                  let limit = Int(values["limit"] ?? "50"), (1...100).contains(limit) else {
                throw ReminderError.invalidArgument
            }
            self = .list(id: id, name: name, includeCompleted: include == "true", limit: limit)
        case "reminders_get":
            guard let id = try optional("id", maximum: 512) else { throw ReminderError.invalidArgument }
            self = .get(id: id)
        case "reminders_create":
            guard let title = try optional("title", maximum: 500) else { throw ReminderError.invalidArgument }
            let notes = try optional("notes", maximum: 4_000)
            let id = try optional("list_id", maximum: 512)
            let name = try optional("list_name", maximum: 512)
            guard id == nil || name == nil else { throw ReminderError.invalidArgument }
            var date: Date?
            if let raw = try optional("due_iso", maximum: 64) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = formatter.date(from: raw)
                if date == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    date = formatter.date(from: raw)
                }
                guard date != nil else { throw ReminderError.invalidArgument }
            }
            self = .create(title: title, notes: notes, dueDate: date, id: id, name: name)
        case "reminders_complete":
            guard let id = try optional("id", maximum: 512),
                  let raw = values["completed"], ["true", "false"].contains(raw) else {
                throw ReminderError.invalidArgument
            }
            self = .complete(id: id, completed: raw == "true")
        case "reminders_update":
            guard let id = try optional("id", maximum: 512),
                  let expectedTitle = try optional("expected_title", maximum: 500) else {
                throw ReminderError.invalidArgument
            }
            let title = try optional("title", maximum: 500)
            let notes = try optional("notes", maximum: 4_000)
            let listID = try optional("list_id", maximum: 512)
            let clearNotes = try Self.boolean(values, key: "clear_notes")
            let clearDue = try Self.boolean(values, key: "clear_due")
            guard !(clearNotes && notes != nil), !clearDue || values["due_iso"] == nil,
                  title != nil || notes != nil || clearNotes || clearDue || values["due_iso"] != nil || listID != nil else {
                throw ReminderError.invalidArgument
            }
            let dueDate = try Self.parsedDate(values["due_iso"])
            self = .update(id: id, expectedTitle: expectedTitle, title: title, notes: notes,
                clearNotes: clearNotes, dueDate: dueDate, clearDue: clearDue, listID: listID)
        case "reminders_delete":
            guard let id = try optional("id", maximum: 512),
                  let expectedTitle = try optional("expected_title", maximum: 500) else {
                throw ReminderError.invalidArgument
            }
            self = .delete(id: id, expectedTitle: expectedTitle)
        default: throw ReminderError.invalidArgument
        }
    }

    private static func boolean(_ values: [String: String], key: String) throws -> Bool {
        guard let raw = values[key] else { return false }
        guard ["true", "false"].contains(raw) else { throw ReminderError.invalidArgument }
        return raw == "true"
    }

    private static func parsedDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        guard !raw.isEmpty, raw.utf8.count <= 64 else { throw ReminderError.invalidArgument }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { throw ReminderError.invalidArgument }
        return date
    }
}

private struct ReminderList: Encodable, Sendable {
    let id: String
    let name: String
}

private struct ReminderSummary: Encodable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let completed: Bool
    let dueISO: String?
    let listID: String
    let listName: String
    let recurring: Bool

    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title
        notes = reminder.notes
        completed = reminder.isCompleted
        dueISO = reminder.dueDateComponents?.date.map { ISO8601DateFormatter().string(from: $0) }
        listID = reminder.calendar.calendarIdentifier
        listName = reminder.calendar.title
        recurring = reminder.hasRecurrenceRules
    }
}

private struct ReminderPage: Encodable, Sendable {
    let reminders: [ReminderSummary]
    let returned: Int
    let total: Int
    let truncated: Bool
}

private struct ReminderDeletionReceipt: Encodable, Sendable {
    let id: String
    let deleted: Bool
}

private enum ReminderError: LocalizedError {
    case invalidArgument, permissionRequired, listUnavailable, listReadOnly, reminderUnavailable,
         reminderChanged, recurringReminder

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Invalid reminder arguments. Use exact IDs and ISO-8601 due dates with time zones; update requires id, expected_title and at least one changed field."
        case .permissionRequired: "AIM needs Reminders access. Grant it once in macOS Privacy & Security → Reminders for the signed AIM app."
        case .listUnavailable: "The exact reminder list was not found or its name is ambiguous. Call reminders_lists and use list_id."
        case .listReadOnly: "The selected reminder list does not allow edits."
        case .reminderUnavailable: "The exact reminder ID was not found. Refresh the list before retrying."
        case .reminderChanged: "The reminder title changed since observation. Read it again before editing."
        case .recurringReminder: "AIM cannot safely edit or delete a recurring reminder through this tool."
        }
    }
}
