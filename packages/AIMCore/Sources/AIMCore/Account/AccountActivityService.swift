import CryptoKit
import Foundation

public struct AccountActivityRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case response, task, tool, voice, cost }
    public enum CostState: String, Codable, Sendable { case confirmed, estimated, reserved, unknown }
    /// Earlier portable histories did not record an execution device. Import must not guess it.
    public static let unattributedDeviceID = "legacy-origin-unknown"
    public var hasVerifiedOrigin: Bool { deviceID != Self.unattributedDeviceID }
    public var id: UUID
    public var accountID: UUID
    public var deviceID: String
    public var deviceName: String
    public var conversationID: UUID?
    public var parentTaskID: UUID?
    public var kind: Kind
    public var provider: String
    public var modelID: String
    public var mode: String
    public var startedAt: Date
    public var completedAt: Date?
    public var totalTokens: Int?
    public var costTrackedSeparately: Bool?
    public var costUSD: Double?
    public var costState: CostState
    /// Explicit provenance for a retrospective token subtotal; never a provider receipt.
    public var costEstimateBasis: String?
    public var waitingSeconds: Double?
    public var toolName: String?
    public var updatedAt: Date
    public init(id: UUID, accountID: UUID, deviceID: String, deviceName: String, conversationID: UUID? = nil,
                parentTaskID: UUID? = nil, kind: Kind = .response, provider: String, modelID: String, mode: String,
                startedAt: Date, completedAt: Date? = nil, totalTokens: Int? = nil, costUSD: Double? = nil,
                costState: CostState = .unknown, waitingSeconds: Double? = nil, toolName: String? = nil, updatedAt: Date = .now) {
        self.id = id; self.accountID = accountID; self.deviceID = deviceID; self.deviceName = deviceName
        self.conversationID = conversationID; self.parentTaskID = parentTaskID; self.kind = kind
        self.provider = provider; self.modelID = modelID; self.mode = mode; self.startedAt = startedAt
        self.completedAt = completedAt; self.totalTokens = totalTokens; self.costUSD = costUSD
        self.costState = costState; self.waitingSeconds = waitingSeconds; self.toolName = toolName; self.updatedAt = updatedAt
    }
    public var duration: TimeInterval? { completedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    public var valid: Bool {
        (totalTokens == nil || totalTokens! >= 0) && (costUSD == nil || (costUSD!.isFinite && costUSD! >= 0)) &&
        (waitingSeconds == nil || (waitingSeconds!.isFinite && waitingSeconds! >= 0)) &&
        (completedAt == nil || completedAt! >= startedAt) && deviceID.utf8.count <= 160 && modelID.utf8.count <= 256
    }
    /// A copied conversation is not another inference. Preserve its execution origin.
    public static func merge(_ records: [Self], accountID: UUID) -> [Self] {
        var result: [UUID: Self] = [:]
        for record in records where record.accountID == accountID && record.valid {
            guard let old = result[record.id] else { result[record.id] = record; continue }
            guard record.kind == old.kind else { continue }
            if record.deviceID != old.deviceID {
                // A later execution record supplies the origin missing in an explicit legacy import.
                // An imported history never replaces a known origin, regardless of its timestamp.
                if !old.hasVerifiedOrigin && record.hasVerifiedOrigin { result[record.id] = record }
                continue
            }
            var merged = record.updatedAt > old.updatedAt ? record : old
            if old.costState == .confirmed && record.costState != .confirmed { merged.costUSD = old.costUSD; merged.costState = .confirmed }
            if record.costState == .confirmed && old.costState != .confirmed { merged.costUSD = record.costUSD; merged.costState = .confirmed }
            if merged.totalTokens == nil { merged.totalTokens = old.totalTokens ?? record.totalTokens }
            if merged.completedAt == nil { merged.completedAt = old.completedAt ?? record.completedAt }
            result[record.id] = merged
        }
        return result.values.sorted { $0.startedAt < $1.startedAt }
    }
}

public struct AccountActivitySummary: Sendable {
    public let records: [AccountActivityRecord]
    public let tokens: Int
    public let peakTokens: Int?
    public let unmeasuredResponses: Int
    public let longestTask: TimeInterval?
    public let longestTaskWaiting: TimeInterval?
    public let measuredWaitingSeconds: TimeInterval?
    public let unmeasuredTasks: Int
    public let activeDays: Set<Date>
    public let longestStreak: Int
    public let currentStreak: Int
    public let dailyTokens: [Date: Int]
    public let confirmedUSD: Double
    public let estimatedUSD: Double
    public let reservedUSD: Double
    public let unknownCosts: Int
    public init(records: [AccountActivityRecord], accountID: UUID, calendar: Calendar = .current, now: Date = .now) {
        self.records = AccountActivityRecord.merge(records, accountID: accountID)
        let responses = self.records.filter { $0.kind == .response || $0.kind == .voice }
        tokens = responses.compactMap(\.totalTokens).reduce(0, +)
        peakTokens = responses.compactMap(\.totalTokens).max()
        unmeasuredResponses = responses.filter { $0.totalTokens == nil }.count
        let tasks = self.records.filter { $0.kind == .task && $0.parentTaskID == nil }
        let longestTaskRecord = tasks.filter { $0.duration != nil }.max { $0.duration! < $1.duration! }
        longestTask = longestTaskRecord?.duration
        longestTaskWaiting = longestTaskRecord?.waitingSeconds
        let waits = tasks.compactMap(\.waitingSeconds)
        measuredWaitingSeconds = waits.isEmpty ? nil : waits.reduce(0, +)
        unmeasuredTasks = tasks.filter { $0.duration == nil }.count
        dailyTokens = Dictionary(responses.compactMap { row in row.totalTokens.map { (calendar.startOfDay(for: row.startedAt), $0) } }, uniquingKeysWith: +)
        activeDays = Set(self.records.filter { $0.kind != .cost }.map { calendar.startOfDay(for: $0.startedAt) })
        let days = activeDays.sorted()
        var longest = 0, run = 0, previous: Date?
        for day in days { run = previous.flatMap { calendar.dateComponents([.day], from: $0, to: day).day } == 1 ? run + 1 : 1; longest = max(longest, run); previous = day }
        longestStreak = longest
        let daySet = Set(days); var cursor = calendar.startOfDay(for: now), current = 0
        if !daySet.contains(cursor) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        while daySet.contains(cursor) { current += 1; cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        currentStreak = current
        let costRecords = self.records
        func sum(_ state: AccountActivityRecord.CostState) -> Double { costRecords.filter { $0.costState == state && $0.costTrackedSeparately != true }.compactMap(\.costUSD).reduce(0, +) }
        confirmedUSD = sum(.confirmed); estimatedUSD = sum(.estimated); reservedUSD = sum(.reserved)
        unknownCosts = self.records.filter { [.response, .voice, .cost].contains($0.kind) && $0.costState == .unknown && $0.costTrackedSeparately != true }.count
    }
}

/// Both platforms filter the same execution records, in the explicitly displayed time zone.
public struct AccountActivityFilter: Sendable {
    public enum Period: String, CaseIterable, Sendable { case day, week, month, year, all }
    public var period: Period
    public var timeZoneID: String
    public var deviceID: String?
    public var provider: String?
    public var modelID: String?
    public var mode: String?
    public init(period: Period = .month, timeZoneID: String = TimeZone.current.identifier,
                deviceID: String? = nil, provider: String? = nil, modelID: String? = nil, mode: String? = nil) {
        self.period = period; self.timeZoneID = timeZoneID; self.deviceID = deviceID
        self.provider = provider; self.modelID = modelID; self.mode = mode
    }
    public func apply(_ source: [AccountActivityRecord], accountID: UUID, now: Date = .now) -> [AccountActivityRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        let component: Calendar.Component = switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: .era
        }
        let interval = period == .all ? nil : calendar.dateInterval(of: component, for: now)
        return AccountActivityRecord.merge(source, accountID: accountID).filter { row in
            (interval == nil || (row.startedAt >= interval!.start && row.startedAt < interval!.end)) &&
            (deviceID == nil || row.deviceID == deviceID) && (provider == nil || row.provider == provider) &&
            (modelID == nil || row.modelID == modelID) && (mode == nil || row.mode == mode)
        }
    }
}

/// One month of one device's activity, stored as a single account document (Round 37). Each
/// device writes only its own months, so two devices never write the same document.
public struct AccountActivityBatch: Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var deviceID: String
    public var month: String
    public var records: [AccountActivityRecord]

    public static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
    /// The same account, device and month always give the same document.
    public static func id(accountID: UUID, deviceID: String, month: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("aim-activity-batch:\(accountID.uuidString):\(deviceID):\(month)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 0x0F) | 0x50, bytes[7],
                           (bytes[8] & 0x3F) | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public actor AccountActivityService {
    private let accountID: UUID
    private let service: any AccountContentSyncing
    public init(accountID: UUID, service: any AccountContentSyncing) { self.accountID = accountID; self.service = service }
    /// Reads single-record documents (earlier versions) and monthly batches. With `deviceID`, this
    /// device's records are written as monthly batches, only when a month changed; without it,
    /// one document per record as before.
    public func synchronize(_ local: [AccountActivityRecord], deviceID: String? = nil) async throws -> [AccountActivityRecord] {
        let all = try await service.documents(accountID: accountID).filter { $0.kind == "activity" }
        // A record deleted on another device stays deleted: it is neither merged nor uploaded again.
        let removed = Set(all.filter(\.deleted).map(\.id))
        let documents = all.filter { !$0.deleted }
        let decoder = JSONDecoder(), encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var remote: [AccountActivityRecord] = []
        var batches: [UUID: AccountDocument] = [:]
        for document in documents {
            let data = Data(document.payload.utf8)
            if let record = try? decoder.decode(AccountActivityRecord.self, from: data) { remote.append(record) }
            else if let batch = try? decoder.decode(AccountActivityBatch.self, from: data), batch.id == document.id, batch.accountID == accountID {
                remote += batch.records; batches[document.id] = document
            }
        }
        let merged = AccountActivityRecord.merge(remote + local.filter { !removed.contains($0.id) }, accountID: accountID)
        if let deviceID {
            let own = merged.filter { $0.deviceID == deviceID }
            for (month, records) in Dictionary(grouping: own, by: { AccountActivityBatch.month(of: $0.startedAt) }) {
                let id = AccountActivityBatch.id(accountID: accountID, deviceID: deviceID, month: month)
                let batch = AccountActivityBatch(id: id, accountID: accountID, deviceID: deviceID, month: month,
                                                 records: records.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) })
                let payload = String(decoding: try encoder.encode(batch), as: UTF8.self)
                let prior = batches[id]
                if prior?.payload != payload {
                    _ = try await service.save(.init(id: id, kind: "activity", payload: payload, revision: prior?.revision ?? 0), accountID: accountID)
                }
            }
            return merged
        }
        for record in merged {
            let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
            let prior = documents.first { $0.id == record.id }
            if prior?.payload != payload {
                _ = try await service.save(.init(id: record.id, kind: "activity", payload: payload, revision: prior?.revision ?? 0), accountID: accountID)
            }
        }
        return merged
    }
}
