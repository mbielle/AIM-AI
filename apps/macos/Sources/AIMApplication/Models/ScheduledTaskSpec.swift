import AIMCore
import Foundation

/// What an unattended Agent task runs, when, and within which pre-approved
/// scope. Anything outside the scope pauses the run for a person.
public struct ScheduledTaskSpec: Codable, Equatable, Hashable, Sendable {
    public enum Schedule: Codable, Equatable, Hashable, Sendable {
        case once(at: Date)
        case interval(seconds: Int)
        case daily(hour: Int, minute: Int)
        /// `weekday` follows Calendar: 1 = Sunday … 7 = Saturday.
        case weekly(weekday: Int, hour: Int, minute: Int)
    }

    public enum Trigger: Codable, Equatable, Hashable, Sendable {
        /// Entries added, removed or renamed directly inside this folder.
        case folderChanged(path: String)
        /// The application with this bundle identifier was launched.
        case applicationLaunched(bundleID: String)
        /// A new unread message arrived in Mail's inbox (checked while Mail runs).
        case newMail
        /// The person's AppleScript, run every `intervalSeconds`, returned a new non-empty
        /// result (e.g. the id of the newest file or message). The first result is a baseline.
        case scriptResultChanged(source: String, intervalSeconds: Int)
        /// A local HTTP POST to AIM's loopback webhook with the matching bearer token
        /// (only its SHA-256 is stored).
        case webhook(tokenSHA256: String)
    }

    public var schedule: Schedule?
    public var trigger: Trigger?
    public var provider: ChatProvider
    public var modelID: String
    public var workspacePath: String?
    public var allowEdits: Bool
    public var allowCommands: Bool
    /// The only actions an unattended run may take without a person.
    public var scope: [MissionAuthorizationRule]
    /// Hard ceiling for this task's billable requests in one run (decimal USD).
    public var maxSpendUSD: String?
    public var timeZoneID: String
    /// Heartbeat re-entry: each run continues the previous run's conversation
    /// instead of starting a new one, so the agent keeps its context.
    public var continuesConversation: Bool?

    public init(schedule: Schedule? = nil, trigger: Trigger? = nil, provider: ChatProvider = .openRouter,
                modelID: String, workspacePath: String? = nil, allowEdits: Bool = false, allowCommands: Bool = false,
                scope: [MissionAuthorizationRule] = [], maxSpendUSD: String? = nil,
                timeZoneID: String = TimeZone.current.identifier, continuesConversation: Bool? = nil) {
        self.schedule = schedule; self.trigger = trigger; self.provider = provider; self.modelID = modelID
        self.workspacePath = workspacePath; self.allowEdits = allowEdits; self.allowCommands = allowCommands
        self.scope = scope; self.maxSpendUSD = maxSpendUSD; self.timeZoneID = timeZoneID
        self.continuesConversation = continuesConversation
    }

    public var isValid: Bool {
        guard schedule != nil || trigger != nil, !modelID.isEmpty, modelID.utf8.count <= 255,
              TimeZone(identifier: timeZoneID) != nil, scope.count <= 20,
              workspacePath.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true else { return false }
        if let maxSpendUSD {
            guard let cap = Decimal(string: maxSpendUSD), !cap.isNaN, cap > 0 else { return false }
        }
        switch schedule {
        case .interval(let seconds)?: guard (60...(31 * 86_400)).contains(seconds) else { return false }
        case .daily(let hour, let minute)?: guard (0...23).contains(hour), (0...59).contains(minute) else { return false }
        case .weekly(let weekday, let hour, let minute)?:
            guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute) else { return false }
        case .once?, nil: break
        }
        switch trigger {
        case .folderChanged(let path)?: return path.hasPrefix("/") && path.utf8.count <= 4_096
        case .applicationLaunched(let bundleID)?: return (try? MissionResource(kind: .application, identifier: bundleID)) != nil
        case .newMail?: return true
        case .scriptResultChanged(let source, let interval)?:
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.utf8.count <= 8_000
                && (30...86_400).contains(interval)
        case .webhook(let hash)?:
            return hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        case nil: return true
        }
    }

    /// The first scheduled occurrence strictly after `date`, or nil when none remains.
    public func nextRun(after date: Date) -> Date? {
        guard let schedule else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        switch schedule {
        case .once(let at):
            return at > date ? at : nil
        case .interval(let seconds):
            return date.addingTimeInterval(TimeInterval(seconds))
        case .daily(let hour, let minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime)
        case .weekly(let weekday, let hour, let minute):
            return calendar.nextDate(after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime)
        }
    }

    public var summary: String {
        var parts: [String] = []
        switch schedule {
        case .once(let at)?: parts.append("once at \(at.formatted(date: .abbreviated, time: .shortened))")
        case .interval(let seconds)?: parts.append("every \(seconds / 60) min")
        case .daily(let hour, let minute)?: parts.append(String(format: "daily at %02d:%02d", hour, minute))
        case .weekly(let weekday, let hour, let minute)?:
            let names = Calendar(identifier: .gregorian).weekdaySymbols
            parts.append(String(format: "weekly on %@ at %02d:%02d", names[weekday - 1], hour, minute))
        case nil: break
        }
        switch trigger {
        case .folderChanged(let path)?: parts.append("when \((path as NSString).lastPathComponent) changes")
        case .applicationLaunched(let bundleID)?: parts.append("when \(bundleID) launches")
        case .newMail?: parts.append("when new mail arrives")
        case .scriptResultChanged(_, let interval)?: parts.append("when its AppleScript result changes (checked every \(interval) s)")
        case .webhook?: parts.append("when its local webhook is called")
        case nil: break
        }
        if continuesConversation == true { parts.append("continuing the same conversation") }
        return parts.joined(separator: ", ")
    }
}

public enum ScheduledRunStatus: String, Codable, Sendable {
    case succeeded, failed, needsPerson = "needs_person", spendCapped = "spend_capped", interrupted, skipped
}

public struct ScheduledExecution: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let taskID: UUID
    public let conversationID: UUID?
    public let startedAt: Date
    public let endedAt: Date?
    public let status: ScheduledRunStatus?
    public let detail: String?
}
