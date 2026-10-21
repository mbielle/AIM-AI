import Foundation

/// A measured value remains unavailable when a provider did not report it.
public struct AccountActivityGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let records: [AccountActivityRecord]
    public var count: Int { records.count }
    public var measuredTokens: Int? {
        let values = records.compactMap(\.totalTokens)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    public var unmeasured: Int { records.filter { $0.totalTokens == nil }.count }
}

public extension AccountActivitySummary {
    enum HeatmapMode: String, CaseIterable, Sendable { case daily, weekly, cumulative }
    var modelUses: [AccountActivityGroup] {
        groups(records.filter { [.response, .voice].contains($0.kind) }, key: { $0.provider + ":" + $0.modelID }, title: { $0.modelID })
    }
    var toolUses: [AccountActivityGroup] {
        groups(records.filter { $0.kind == .tool && $0.toolName != nil }, key: { $0.toolName! }, title: { $0.toolName! })
    }
    func records(on day: Date, calendar: Calendar) -> [AccountActivityRecord] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return records.filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }
    }
    func heatmapValues(days: [Date], mode: HeatmapMode, calendar: Calendar) -> [Date: Int] {
        switch mode {
        case .daily: return Dictionary(days.map { ($0, dailyTokens[$0] ?? 0) }, uniquingKeysWith: { $1 })
        case .weekly:
            let totals = Dictionary(dailyTokens.map { (calendar.dateInterval(of: .weekOfYear, for: $0.key)?.start ?? $0.key, $0.value) }, uniquingKeysWith: +)
            return Dictionary(days.map { ($0, totals[calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0] ?? 0) }, uniquingKeysWith: { $1 })
        case .cumulative:
            var total = dailyTokens.filter { $0.key < (days.min() ?? .distantPast) }.values.reduce(0, +)
            var result: [Date: Int] = [:]
            for day in days.sorted() { total += dailyTokens[day] ?? 0; result[day] = total }
            return result
        }
    }
    private func groups(_ rows: [AccountActivityRecord], key: (AccountActivityRecord) -> String,
                        title: (AccountActivityRecord) -> String) -> [AccountActivityGroup] {
        Dictionary(grouping: rows, by: key).map { id, values in
            AccountActivityGroup(id: id, title: title(values[0]), records: values.sorted { $0.startedAt > $1.startedAt })
        }.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
}

/// An explicit selection of immutable execution IDs. The source is re-read before import.
public struct AccountActivityImportItem: Identifiable, Equatable, Sendable {
    public var id: UUID { record.id }
    public let title: String
    public let record: AccountActivityRecord
    public let fingerprint: Data
    public init(title: String, record: AccountActivityRecord) throws {
        self.title = title; self.record = record
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        fingerprint = try encoder.encode(record)
    }
    public static func preview(conversations: [NativeChatConversation], existing: [AccountActivityRecord],
                               accountID: UUID, deviceID: String, deviceName: String) -> [Self] {
        let known = Set(existing.map(\.id))
        var seen = known
        var result: [Self] = []
        for conversation in conversations {
            for turn in conversation.turns where !seen.contains(turn.id) {
                guard let message = conversation.messages.first(where: { $0.id == turn.id && $0.role == .assistant }) else { continue }
                // Older turns did not store their own provider/model. The current conversation
                // selection is not evidence of the model that produced an earlier answer.
                let tokens: Int? = turn.usage.inputTokens.flatMap { input in turn.usage.outputTokens.map { input + $0 } }
                let row = AccountActivityRecord(id: turn.id, accountID: accountID, deviceID: AccountActivityRecord.unattributedDeviceID, deviceName: "Unknown execution device",
                    conversationID: conversation.id, provider: "unknown", modelID: "Earlier answer", mode: "chat",
                    startedAt: message.createdAt, completedAt: turn.completedAt, totalTokens: tokens, costUSD: turn.estimatedUSD,
                    costState: turn.estimatedUSD == nil ? .unknown : .estimated, updatedAt: turn.completedAt ?? message.createdAt)
                if row.valid, let item = try? Self(title: conversation.title, record: row) { result.append(item); seen.insert(row.id) }
            }
        }
        return result.sorted { $0.record.startedAt > $1.record.startedAt }
    }
    /// Importing a stale preview must not silently attribute changed source data.
    public static func selected(_ ids: Set<UUID>, from preview: [Self], current: [Self], accountID: UUID) throws -> [AccountActivityRecord] {
        let fresh = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let requested = preview.filter { ids.contains($0.id) }
        guard requested.count == ids.count else { throw AccountServiceError.conflict }
        return try requested.map { item in
            guard item.record.accountID == accountID, let row = fresh[item.id], row.fingerprint == item.fingerprint else { throw AccountServiceError.conflict }
            return row.record
        }
    }
}
