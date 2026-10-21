import Foundation

/// Budgets belong to the executing installation. Reading a Remote mirror never spends here.
public enum DeviceBudgetRules {
    public static func committedUSD(records: [AccountActivityRecord], accountID: UUID, deviceID: String,
                                    calendar: Calendar = .current, now: Date = .now) -> Double {
        let interval = calendar.dateInterval(of: .month, for: now)!
        return AccountActivityRecord.merge(records, accountID: accountID).filter {
            $0.deviceID == deviceID && $0.startedAt >= interval.start && $0.startedAt < interval.end
        }.compactMap(\.costUSD).reduce(0, +)
    }
    public static func hasUnknownCosts(records: [AccountActivityRecord], accountID: UUID, deviceID: String,
                                       calendar: Calendar = .current, now: Date = .now,
                                       includingCompleted: Bool = true) -> Bool {
        let interval = calendar.dateInterval(of: .month, for: now)!
        return AccountActivityRecord.merge(records, accountID: accountID).contains {
            $0.deviceID == deviceID && $0.startedAt >= interval.start && $0.startedAt < interval.end && [.response, .voice, .cost].contains($0.kind) && $0.costUSD == nil && $0.costTrackedSeparately != true && (includingCompleted || $0.completedAt == nil)
        }
    }
    public static func completedUnknownCostCount(records: [AccountActivityRecord], accountID: UUID, deviceID: String,
                                                calendar: Calendar = .current, now: Date = .now) -> Int {
        let interval = calendar.dateInterval(of: .month, for: now)!
        return AccountActivityRecord.merge(records, accountID: accountID).filter {
            $0.deviceID == deviceID && $0.startedAt >= interval.start && $0.startedAt < interval.end &&
            [.response, .voice, .cost].contains($0.kind) && $0.costUSD == nil &&
            $0.costTrackedSeparately != true && $0.completedAt != nil
        }.count
    }
    /// Reconstruct only completed legacy text responses with complete saved usage
    /// and an exact native-catalog match. Unknown search fees stay in the message
    /// metadata; the new amount is an explicitly attributed token subtotal, not
    /// a historical provider invoice. Failed, reserved and confirmed rows are untouched.
    public static func recoveringLegacyEstimates(records: [AccountActivityRecord], conversations: [NativeChatConversation],
                                                accountID: UUID, deviceID: String,
                                                models: [ChatProvider: [ChatModel]], now: Date = .now) -> [AccountActivityRecord] {
        records.map { record in
            guard record.accountID == accountID, record.deviceID == deviceID, record.kind == .response,
                  record.mode == "chat", record.costUSD == nil, record.costState == .unknown,
                  record.completedAt != nil, let conversationID = record.conversationID,
                  let conversation = conversations.first(where: { $0.id == conversationID }),
                  conversation.provider.rawValue == record.provider, conversation.modelID == record.modelID,
                  !conversation.messages.contains(where: { ($0.attachments ?? []).contains(where: \.containsVisualContent) }),
                  let turn = conversation.turns.first(where: { $0.id == record.id }), turn.completedAt != nil,
                  let message = conversation.messages.first(where: { $0.id == record.id && $0.role == .assistant }),
                  (message.skillActivities ?? []).allSatisfy({
                      ProjectSourceTools.contains($0.name) && !$0.isError && $0.running == false
                  }),
                  let provider = ChatProvider(rawValue: record.provider),
                  let model = models[provider]?.first(where: { $0.id == record.modelID }),
                  let cost = ChatCostRules.estimateUSD(usage: turn.usage, pricing: model.pricing,
                      webSearch: message.webSearchUsage, allowPartialWebSearchCost: true), cost.isFinite, cost >= 0 else { return record }
            // Do not reinterpret already-saved provider totals as retrospective estimates.
            guard message.webSearchUsage?.providerTotalCostUSD == nil else { return record }
            var recovered = record
            recovered.costUSD = cost; recovered.costState = .estimated
            recovered.costEstimateBasis = "legacy-saved-usage-current-native-catalog-v1"
            recovered.updatedAt = now
            return recovered
        }
    }
    public enum AdmissionFailure: String, Error, Sendable {
        case invalidLimit, unknownHistory, exhausted, reserved, requestTooLarge, unknownPrice
    }
    public enum HistoryPolicy: Sendable {
        case requireComplete, estimatedKnownCharges
    }
    /// Known charges and in-flight/uncertain reservations remain distinct. Unknown
    /// historical charges never become zero simply because the UI uses estimates.
    public static func admissionFailure(bound: Double?, limit: Double, records: [AccountActivityRecord],
                                        accountID: UUID, deviceID: String, calendar: Calendar = .current,
                                        now: Date = .now, historyPolicy: HistoryPolicy = .requireComplete) -> AdmissionFailure? {
        guard limit.isFinite, limit > 0 else { return .invalidLimit }
        // A soft estimate may omit settled unknown historical charges, while
        // preserving them as unknown. Pending/uncertain requests still block.
        if hasUnknownCosts(records: records, accountID: accountID, deviceID: deviceID, calendar: calendar, now: now,
                           includingCompleted: historyPolicy == .requireComplete) { return .unknownHistory }
        let spent = committedUSD(records: records, accountID: accountID, deviceID: deviceID, calendar: calendar, now: now)
        guard let bound, bound.isFinite, bound >= 0 else { return .unknownPrice }
        if spent + bound <= limit { return nil }
        let interval = calendar.dateInterval(of: .month, for: now)!
        let reserved = AccountActivityRecord.merge(records, accountID: accountID).filter {
            $0.deviceID == deviceID && $0.startedAt >= interval.start && $0.startedAt < interval.end && $0.costState == .reserved
        }.compactMap(\.costUSD).reduce(0, +)
        if reserved > 0 && spent - reserved + bound <= limit { return .reserved }
        return spent >= limit ? .exhausted : .requestTooLarge
    }
    /// In automatic mode reserve only output affordable by the remaining budget,
    /// and send that same limit to the provider. Explicit user limits are never
    /// silently reduced. Search fees remain outside this token-only calculation.
    public static func affordableOutputTokens(inputBytes: Int, catalogMaximum: Int?, userLimit: Int?,
                                              remainingUSD: Double, pricing: ChatModel.Pricing?) -> Int? {
        if let userLimit { return userLimit }
        guard let maximum = catalogMaximum, maximum > 0, remainingUSD.isFinite, remainingUSD > 0,
              let input = pricing?.inputPerMillion, let output = pricing?.outputPerMillion,
              input.isFinite, output.isFinite, input >= 0, output >= 0, inputBytes >= 0 else { return nil }
        let available = remainingUSD - Double(inputBytes) * input / 1_000_000
        guard available > 0 else { return nil }
        if output == 0 { return maximum }
        let affordable = (available * 1_000_000 / output).rounded(.down)
        guard affordable >= 1 else { return nil }
        return affordable >= Double(maximum) ? maximum : Int(affordable)
    }
    public static func upperBound(inputBytes: Int, maxOutputTokens: Int, pricing: ChatModel.Pricing?) -> Double? {
        guard let pricing, let input = pricing.inputPerMillion, let output = pricing.outputPerMillion,
              input.isFinite, output.isFinite, input >= 0, output >= 0, inputBytes >= 0, maxOutputTokens > 0 else { return nil }
        // UTF-8 bytes conservatively bound text tokens; extra framing is included by the caller.
        return (Double(inputBytes) * input + Double(maxOutputTokens) * output) / 1_000_000
    }
}
