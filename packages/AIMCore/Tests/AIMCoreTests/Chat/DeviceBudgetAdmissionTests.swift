import XCTest
@testable import AIMCore

final class DeviceBudgetAdmissionTests: XCTestCase {
    private let owner = UUID()
    private let now = Date(timeIntervalSince1970: 1_760_702_400)
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func row(cost: Double?, state: AccountActivityRecord.CostState = .confirmed, at: Date? = nil, device: String = "phone") -> AccountActivityRecord {
        .init(id: UUID(), accountID: owner, deviceID: device, deviceName: "Fixture", provider: "fixture", modelID: "fixture", mode: "chat", startedAt: at ?? now, costUSD: cost, costState: state)
    }
    func testLegacyCompletedUnknownWebChargeBecomesAttributedTokenEstimateOnly() throws {
        let messageID = UUID(), conversationID = UUID()
        let message = NativeChatMessage(id: messageID, role: .assistant, text: "Synthetic answer", webSearchUsage: .init(),
            skillActivities: [.init(id: "local-source-search", name: "project_source_search", skill: "validation", running: false)])
        let conversation = NativeChatConversation(id: conversationID, title: "Fixture", provider: .openRouter, modelID: "fixture",
            messages: [message], turns: [.init(id: messageID, usage: .init(inputTokens: 2641, outputTokens: 235), completedAt: now)])
        var legacy = row(cost: nil, state: .unknown); legacy.id = messageID; legacy.conversationID = conversationID
        legacy.provider = "openrouter"; legacy.completedAt = now
        var model = ChatModel(id: "fixture", name: "Fixture")
        model.pricing = .init(prompt: "0.000000079", completion: "0.0000048")
        let recovered = DeviceBudgetRules.recoveringLegacyEstimates(records: [legacy], conversations: [conversation], accountID: owner,
            deviceID: "phone", models: [.openRouter: [model]], now: now)
        XCTAssertEqual(try XCTUnwrap(recovered.first?.costUSD), 0.001336639, accuracy: 0.000000001)
        XCTAssertEqual(recovered.first?.costState, .estimated)
        XCTAssertNotNil(recovered.first?.costEstimateBasis)
        XCTAssertNil(message.webSearchUsage?.additionalCostUSD)
        XCTAssertEqual(DeviceBudgetRules.recoveringLegacyEstimates(records: recovered, conversations: [conversation], accountID: owner,
            deviceID: "phone", models: [.openRouter: [model]], now: now), recovered, "The attributed repair is idempotent")
        for state in [AccountActivityRecord.CostState.confirmed, .reserved] {
            legacy.costState = state
            XCTAssertEqual(DeviceBudgetRules.recoveringLegacyEstimates(records: [legacy], conversations: [conversation], accountID: owner,
                deviceID: "phone", models: [.openRouter: [model]], now: now), [legacy])
        }
        legacy.costState = .unknown
        var missingUsage = conversation; missingUsage.turns[0].usage.outputTokens = nil
        XCTAssertEqual(DeviceBudgetRules.recoveringLegacyEstimates(records: [legacy], conversations: [missingUsage], accountID: owner,
            deviceID: "phone", models: [.openRouter: [model]], now: now), [legacy])
        XCTAssertEqual(DeviceBudgetRules.recoveringLegacyEstimates(records: [legacy], conversations: [conversation], accountID: owner,
            deviceID: "another-device", models: [.openRouter: [model]], now: now), [legacy])
    }

    func testMonthExcludesPastFutureOtherDeviceAndOtherAccount() {
        let interval = calendar.dateInterval(of: .month, for: now)!
        var other = row(cost: 80); other.accountID = UUID()
        let rows = [row(cost: 0.0602), row(cost: 30, at: interval.start.addingTimeInterval(-1)), row(cost: 40, at: interval.end), row(cost: 50, device: "mac"), other, row(cost: nil, at: interval.end)]
        XCTAssertEqual(DeviceBudgetRules.committedUSD(records: rows, accountID: owner, deviceID: "phone", calendar: calendar, now: now), 0.0602)
        XCTAssertFalse(DeviceBudgetRules.hasUnknownCosts(records: rows, accountID: owner, deviceID: "phone", calendar: calendar, now: now))
    }
    func testAdmissionDistinguishesUnreportedChargesReservationsAndExhaustion() {
        func failure(_ rows: [AccountActivityRecord], _ bound: Double? = 1) -> DeviceBudgetRules.AdmissionFailure? {
            DeviceBudgetRules.admissionFailure(bound: bound, limit: 5, records: rows, accountID: owner, deviceID: "phone", calendar: calendar, now: now)
        }
        XCTAssertEqual(failure([row(cost: nil)]), .unknownHistory)
        XCTAssertEqual(failure([row(cost: 4.8, state: .reserved)]), .reserved)
        XCTAssertEqual(failure([row(cost: 5)]), .exhausted)
        XCTAssertEqual(failure([row(cost: 4.8)]), .requestTooLarge)
        XCTAssertEqual(failure([], nil), .unknownPrice)
        XCTAssertNil(failure([row(cost: 0.0602)]))
    }
    func testEstimatedHistoryRemainsUnknownButDoesNotBlockKnownNewCosts() {
        var historic = row(cost: nil, state: .unknown); historic.completedAt = now
        let rows = [historic, row(cost: 0.0602)]
        func admission(_ records: [AccountActivityRecord], _ bound: Double? = 1) -> DeviceBudgetRules.AdmissionFailure? {
            DeviceBudgetRules.admissionFailure(bound: bound, limit: 5, records: records, accountID: owner,
                deviceID: "phone", calendar: calendar, now: now, historyPolicy: .estimatedKnownCharges)
        }
        XCTAssertNil(admission(rows))
        XCTAssertNil(historic.costUSD); XCTAssertEqual(historic.costState, .unknown)
        XCTAssertTrue(DeviceBudgetRules.hasUnknownCosts(records: rows, accountID: owner, deviceID: "phone", calendar: calendar, now: now))
        XCTAssertEqual(DeviceBudgetRules.completedUnknownCostCount(records: rows, accountID: owner, deviceID: "phone", calendar: calendar, now: now), 1)
        XCTAssertEqual(admission(rows, nil), .unknownPrice)
        XCTAssertEqual(admission(rows + [row(cost: 5)]), .exhausted)
        XCTAssertEqual(admission(rows + [row(cost: 4, state: .reserved)]), .reserved)
        XCTAssertEqual(admission([row(cost: nil, state: .unknown)]), .unknownHistory, "Unsettled requests are never omitted")
        XCTAssertEqual(DeviceBudgetRules.admissionFailure(bound: 1, limit: 5, records: rows, accountID: owner,
            deviceID: "phone", calendar: calendar, now: now), .unknownHistory, "Strict callers remain fail-closed")
    }

    func testLocalSourceRecoveryDoesNotReclassifyOtherToolsAsTokenOnly() {
        let id = UUID(), conversationID = UUID()
        var record = row(cost: nil, state: .unknown); record.id = id; record.conversationID = conversationID
        record.provider = "openrouter"; record.completedAt = now
        var model = ChatModel(id: "fixture", name: "Fixture"); model.pricing = .init(prompt: "0.000000079", completion: "0.0000048")
        for activity in [NativeSkillActivity(id: "1", name: "external_paid_tool", skill: "fixture", running: false),
                         .init(id: "2", name: "project_source_search", skill: "fixture", running: true)] {
            let message = NativeChatMessage(id: id, role: .assistant, text: "Fixture", skillActivities: [activity])
            let conversation = NativeChatConversation(id: conversationID, title: "Fixture", provider: .openRouter, modelID: "fixture",
                messages: [message], turns: [.init(id: id, usage: .init(inputTokens: 2641, outputTokens: 235), completedAt: now)])
            XCTAssertEqual(DeviceBudgetRules.recoveringLegacyEstimates(records: [record], conversations: [conversation], accountID: owner,
                deviceID: "phone", models: [.openRouter: [model]], now: now), [record])
        }
    }
    func testAutomaticLargeModelCapacityUsesAffordableOutputWithoutChangingExplicitChoice() throws {
        let pricing = ChatModel.Pricing(prompt: "0.000000079", completion: "0.0000048")
        let capacity = 2_000_000, bytes = 500_000
        let output = try XCTUnwrap(DeviceBudgetRules.affordableOutputTokens(inputBytes: bytes, catalogMaximum: capacity, userLimit: nil, remainingUSD: 5 - 0.0602, pricing: pricing))
        XCTAssertGreaterThan(output, 32_000); XCTAssertLessThan(output, capacity)
        XCTAssertLessThanOrEqual(try XCTUnwrap(DeviceBudgetRules.upperBound(inputBytes: bytes, maxOutputTokens: output, pricing: pricing)), 5 - 0.0602)
        XCTAssertEqual(DeviceBudgetRules.affordableOutputTokens(inputBytes: bytes, catalogMaximum: capacity, userLimit: capacity, remainingUSD: 5, pricing: pricing), capacity)
        XCTAssertNil(DeviceBudgetRules.affordableOutputTokens(inputBytes: bytes, catalogMaximum: capacity, userLimit: nil, remainingUSD: 0.01, pricing: pricing))
    }
}
