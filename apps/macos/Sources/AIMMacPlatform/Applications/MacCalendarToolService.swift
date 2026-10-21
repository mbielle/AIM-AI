import AIMAgentKit
import AIMApplication
@preconcurrency import EventKit
import Foundation

/// Bounded, typed EventKit operations. No attendee or invitation API is
/// exposed; creating an event changes only the selected local calendar.
public actor MacCalendarToolService: ToolExecutor, MissionIntentProviding {
    public nonisolated let supportedTools: Set<String> = [
        "calendar_lists", "calendar_events", "calendar_get", "calendar_create", "calendar_update", "calendar_delete"
    ]

    public init() {}

    public nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "calendar_lists", "calendar_events", "calendar_get": operation = .observe
        case "calendar_create", "calendar_update": operation = .edit
        case "calendar_delete": operation = .permanentDelete
        default: return nil
        }
        _ = try CalendarArguments(request)
        return MissionToolIntent(operation: operation,
            target: try MissionResource(kind: .application, identifier: "com.apple.iCal"))
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        var mutationStarted = false
        do {
            let arguments = try CalendarArguments(request)
            let store = EKEventStore()
            try await Self.ensureAccess(store)
            try Task.checkCancellation()
            switch arguments {
            case .lists:
                let lists = store.calendars(for: .event)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    .map { CalendarList(id: $0.calendarIdentifier, name: $0.title, writable: $0.allowsContentModifications) }
                return try Self.encoded(lists, requestID: request.id)
            case let .events(start, end, calendarID, limit):
                let calendars: [EKCalendar]?
                if let calendarID {
                    guard let selected = store.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarID }) else {
                        throw CalendarToolError.calendarUnavailable
                    }
                    calendars = [selected]
                } else { calendars = nil }
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                let all = store.events(matching: predicate)
                try Task.checkCancellation()
                let sorted = all.sorted { $0.startDate < $1.startDate }
                let page = CalendarEventPage(events: sorted.prefix(limit).map(CalendarEventSummary.init),
                    returned: min(sorted.count, limit), total: sorted.count, truncated: sorted.count > limit)
                return try Self.encoded(page, requestID: request.id)
            case let .get(id):
                guard let event = store.event(withIdentifier: id) else { throw CalendarToolError.eventUnavailable }
                return try Self.encoded(CalendarEventSummary(event), requestID: request.id)
            case let .create(title, start, end, calendarID, calendarName, location, notes, allDay):
                let calendar = try Self.selectedCalendar(store: store, id: calendarID, name: calendarName)
                guard calendar.allowsContentModifications else { throw CalendarToolError.calendarReadOnly }
                let event = EKEvent(eventStore: store)
                event.title = title
                event.startDate = start
                event.endDate = end
                event.isAllDay = allDay
                event.calendar = calendar
                event.location = location
                event.notes = notes
                try Task.checkCancellation()
                mutationStarted = true
                try store.save(event, span: .thisEvent, commit: true)
                guard let identifier = event.eventIdentifier,
                      let saved = store.event(withIdentifier: identifier),
                      saved.title == title, saved.startDate == start, saved.endDate == end,
                      saved.calendar.calendarIdentifier == calendar.calendarIdentifier else {
                    return ToolResult(requestID: request.id,
                        content: "Calendar accepted the save, but AIM could not verify this event. Inspect Calendar before retrying to avoid a duplicate.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(CalendarEventSummary(saved), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .update(id, expectedTitle, expectedStart, expectedEnd, title, start, end,
                             location, clearLocation, notes, clearNotes, calendarID):
                guard let event = store.event(withIdentifier: id) else { throw CalendarToolError.eventUnavailable }
                guard event.title == expectedTitle, event.startDate == expectedStart,
                      event.endDate == expectedEnd else { throw CalendarToolError.eventChanged }
                guard !event.hasRecurrenceRules, !event.hasAttendees else {
                    throw CalendarToolError.complexEvent
                }
                guard event.calendar.allowsContentModifications else { throw CalendarToolError.calendarReadOnly }
                if event.isAllDay, let start, let end {
                    guard Calendar.current.startOfDay(for: start) == start,
                          Calendar.current.startOfDay(for: end) == end else {
                        throw CalendarToolError.invalidArgument
                    }
                }
                if let calendarID {
                    guard let calendar = store.calendars(for: .event)
                        .first(where: { $0.calendarIdentifier == calendarID }) else {
                        throw CalendarToolError.calendarUnavailable
                    }
                    guard calendar.allowsContentModifications else { throw CalendarToolError.calendarReadOnly }
                    event.calendar = calendar
                }
                if let title { event.title = title }
                if let start, let end { event.startDate = start; event.endDate = end }
                if let location { event.location = location }
                if clearLocation { event.location = nil }
                if let notes { event.notes = notes }
                if clearNotes { event.notes = nil }
                try Task.checkCancellation()
                mutationStarted = true
                try store.save(event, span: .thisEvent, commit: true)
                let savedID = event.eventIdentifier ?? id
                guard let saved = store.event(withIdentifier: savedID),
                      saved.title == (title ?? expectedTitle),
                      saved.startDate == (start ?? expectedStart), saved.endDate == (end ?? expectedEnd),
                      (location == nil || saved.location == location),
                      (!clearLocation || saved.location == nil),
                      (notes == nil || saved.notes == notes),
                      (!clearNotes || saved.notes == nil),
                      (calendarID == nil || saved.calendar.calendarIdentifier == calendarID) else {
                    return ToolResult(requestID: request.id,
                        content: "Calendar accepted the edit, but AIM could not verify the event. Inspect Calendar before retrying.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(CalendarEventSummary(saved), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .delete(id, expectedTitle, expectedStart, expectedEnd):
                guard let event = store.event(withIdentifier: id) else { throw CalendarToolError.eventUnavailable }
                guard event.title == expectedTitle, event.startDate == expectedStart,
                      event.endDate == expectedEnd else { throw CalendarToolError.eventChanged }
                guard !event.hasRecurrenceRules, !event.hasAttendees else {
                    throw CalendarToolError.complexEvent
                }
                guard event.calendar.allowsContentModifications else { throw CalendarToolError.calendarReadOnly }
                try Task.checkCancellation()
                mutationStarted = true
                try store.remove(event, span: .thisEvent, commit: true)
                guard store.event(withIdentifier: id) == nil else {
                    return ToolResult(requestID: request.id,
                        content: "Calendar accepted the deletion, but AIM could not verify that this event is gone. Inspect Calendar before retrying.",
                        isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
                }
                var result = try Self.encoded(CalendarDeletionReceipt(id: id, deleted: true), requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            }
        } catch {
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            if ["calendar_create", "calendar_update", "calendar_delete"].contains(request.name) {
                result.actionOutcome = mutationStarted ? .unknown : .suspectedAbsent
            }
            return result
        }
    }

    public func cancel(requestID: String) async {}

    private nonisolated static func ensureAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToEvents { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else { throw CalendarToolError.permissionRequired }
        default: throw CalendarToolError.permissionRequired
        }
    }

    private nonisolated static func selectedCalendar(store: EKEventStore, id: String?, name: String?) throws -> EKCalendar {
        let calendars = store.calendars(for: .event)
        if let id {
            guard let selected = calendars.first(where: { $0.calendarIdentifier == id }) else {
                throw CalendarToolError.calendarUnavailable
            }
            return selected
        }
        if let name {
            let matches = calendars.filter { $0.title == name }
            guard matches.count == 1 else { throw CalendarToolError.calendarUnavailable }
            return matches[0]
        }
        guard let fallback = store.defaultCalendarForNewEvents,
              calendars.contains(where: { $0.calendarIdentifier == fallback.calendarIdentifier }) else {
            throw CalendarToolError.calendarUnavailable
        }
        return fallback
    }

    private nonisolated static func encoded<T: Encodable>(_ value: T, requestID: String) throws -> ToolResult {
        ToolResult(requestID: requestID, content: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}

private enum CalendarArguments {
    case lists
    case events(start: Date, end: Date, calendarID: String?, limit: Int)
    case get(id: String)
    case create(title: String, start: Date, end: Date, calendarID: String?, calendarName: String?,
                location: String?, notes: String?, allDay: Bool)
    case update(id: String, expectedTitle: String, expectedStart: Date, expectedEnd: Date,
                title: String?, start: Date?, end: Date?, location: String?, clearLocation: Bool,
                notes: String?, clearNotes: Bool, calendarID: String?)
    case delete(id: String, expectedTitle: String, expectedStart: Date, expectedEnd: Date)

    init(_ request: ToolRequest) throws {
        let values = request.arguments
        func field(_ key: String, maximum: Int) throws -> String? {
            guard let raw = values[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0") else {
                throw CalendarToolError.invalidArgument
            }
            return value
        }
        func date(_ key: String) throws -> Date {
            guard let raw = try field(key, maximum: 64) else { throw CalendarToolError.invalidArgument }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw CalendarToolError.invalidArgument }
            return date
        }
        switch request.name {
        case "calendar_lists": self = .lists
        case "calendar_get":
            guard let id = try field("id", maximum: 512) else { throw CalendarToolError.invalidArgument }
            self = .get(id: id)
        case "calendar_events":
            let start = try date("start_iso")
            let end = try date("end_iso")
            guard end > start, end.timeIntervalSince(start) <= 31 * 24 * 3_600,
                  let limit = Int(values["limit"] ?? "50"), (1...100).contains(limit) else {
                throw CalendarToolError.invalidArgument
            }
            self = .events(start: start, end: end,
                           calendarID: try field("calendar_id", maximum: 512), limit: limit)
        case "calendar_create":
            guard let title = try field("title", maximum: 500) else { throw CalendarToolError.invalidArgument }
            let start = try date("start_iso")
            let end = try date("end_iso")
            guard end > start, end.timeIntervalSince(start) <= 31 * 24 * 3_600 else {
                throw CalendarToolError.invalidArgument
            }
            let id = try field("calendar_id", maximum: 512)
            let name = try field("calendar_name", maximum: 512)
            guard id == nil || name == nil else { throw CalendarToolError.invalidArgument }
            let rawAllDay = values["all_day"] ?? "false"
            guard ["true", "false"].contains(rawAllDay) else { throw CalendarToolError.invalidArgument }
            if rawAllDay == "true" {
                guard Calendar.current.startOfDay(for: start) == start,
                      Calendar.current.startOfDay(for: end) == end else {
                    throw CalendarToolError.invalidArgument
                }
            }
            self = .create(title: title, start: start, end: end, calendarID: id,
                calendarName: name, location: try field("location", maximum: 1_000),
                notes: try field("notes", maximum: 4_000), allDay: rawAllDay == "true")
        case "calendar_update":
            guard let id = try field("id", maximum: 512),
                  let expectedTitle = try field("expected_title", maximum: 500) else {
                throw CalendarToolError.invalidArgument
            }
            let expectedStart = try date("expected_start_iso")
            let expectedEnd = try date("expected_end_iso")
            guard expectedEnd > expectedStart else { throw CalendarToolError.invalidArgument }
            let title = try field("title", maximum: 500)
            let start = values["start_iso"] == nil ? nil : try date("start_iso")
            let end = values["end_iso"] == nil ? nil : try date("end_iso")
            guard (start == nil) == (end == nil) else { throw CalendarToolError.invalidArgument }
            if let start, let end {
                guard end > start, end.timeIntervalSince(start) <= 31 * 24 * 3_600 else {
                    throw CalendarToolError.invalidArgument
                }
            }
            let location = try field("location", maximum: 1_000)
            let notes = try field("notes", maximum: 4_000)
            let clearLocation = try Self.boolean(values, key: "clear_location")
            let clearNotes = try Self.boolean(values, key: "clear_notes")
            let calendarID = try field("calendar_id", maximum: 512)
            guard !(clearLocation && location != nil), !(clearNotes && notes != nil),
                  title != nil || start != nil || location != nil || clearLocation ||
                  notes != nil || clearNotes || calendarID != nil else {
                throw CalendarToolError.invalidArgument
            }
            self = .update(id: id, expectedTitle: expectedTitle, expectedStart: expectedStart,
                expectedEnd: expectedEnd, title: title, start: start, end: end,
                location: location, clearLocation: clearLocation, notes: notes,
                clearNotes: clearNotes, calendarID: calendarID)
        case "calendar_delete":
            guard let id = try field("id", maximum: 512),
                  let expectedTitle = try field("expected_title", maximum: 500) else {
                throw CalendarToolError.invalidArgument
            }
            let expectedStart = try date("expected_start_iso")
            let expectedEnd = try date("expected_end_iso")
            guard expectedEnd > expectedStart else { throw CalendarToolError.invalidArgument }
            self = .delete(id: id, expectedTitle: expectedTitle, expectedStart: expectedStart,
                           expectedEnd: expectedEnd)
        default: throw CalendarToolError.invalidArgument
        }
    }

    private static func boolean(_ values: [String: String], key: String) throws -> Bool {
        guard let raw = values[key] else { return false }
        guard ["true", "false"].contains(raw) else { throw CalendarToolError.invalidArgument }
        return raw == "true"
    }
}

private struct CalendarList: Encodable, Sendable {
    let id: String
    let name: String
    let writable: Bool
}

private struct CalendarEventSummary: Encodable, Sendable {
    let id: String?
    let title: String
    let startISO: String
    let endISO: String
    let allDay: Bool
    let location: String?
    let notes: String?
    let calendarID: String
    let calendarName: String
    let recurring: Bool
    let hasAttendees: Bool

    init(_ event: EKEvent) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        id = event.eventIdentifier
        title = event.title
        startISO = formatter.string(from: event.startDate)
        endISO = formatter.string(from: event.endDate)
        allDay = event.isAllDay
        location = event.location
        notes = event.notes
        calendarID = event.calendar.calendarIdentifier
        calendarName = event.calendar.title
        recurring = event.hasRecurrenceRules
        hasAttendees = event.hasAttendees
    }
}

private struct CalendarDeletionReceipt: Encodable, Sendable {
    let id: String
    let deleted: Bool
}

private struct CalendarEventPage: Encodable, Sendable {
    let events: [CalendarEventSummary]
    let returned: Int
    let total: Int
    let truncated: Bool
}

private enum CalendarToolError: LocalizedError {
    case invalidArgument, permissionRequired, calendarUnavailable, calendarReadOnly,
         eventUnavailable, eventChanged, complexEvent

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Invalid Calendar arguments. Use exact IDs and ISO-8601 date-times with time zones; update needs id, expected title/start/end and at least one changed field. All-day events must use local midnight."
        case .permissionRequired: "AIM needs Calendar access. Grant it once in macOS Privacy & Security → Calendars for the signed AIM app."
        case .calendarUnavailable: "The exact calendar was not found or its name is ambiguous. Call calendar_lists and use calendar_id."
        case .calendarReadOnly: "The selected calendar does not allow new events."
        case .eventUnavailable: "The exact event ID was not found. Refresh the calendar before retrying."
        case .eventChanged: "The event changed since observation. Read it again before editing."
        case .complexEvent: "AIM cannot safely edit recurring events or invitations through this tool."
        }
    }
}
