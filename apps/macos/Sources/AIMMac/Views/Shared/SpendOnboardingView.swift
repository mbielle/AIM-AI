import AIMApplication
import SwiftUI

struct SpendOnboardingView: View {
    @Environment(AppModel.self) private var model
    let onComplete: @MainActor () -> Void
    @State private var amount = ""
    @State private var period: SpendPeriod = .calendarMonth
    @State private var activating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a spending limit").font(.system(size: 20, weight: .semibold))
            Text("AIM has no spending limit by default. You can apply one global limit to billable requests sent by this installation, across Chat, Code, Agent and auxiliary features.")
            Text("Some provider costs cannot yet be bounded before sending. With a limit active, AIM will pause each such request and ask whether to allow that attempt only. The figure shown in AIM is not your final provider invoice.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Limit in USD", text: $amount)
                .textFieldStyle(.settings)
                .accessibilityIdentifier("spend-onboarding-amount")
            HStack {
                Text("Period").font(.system(size: 13))
                Spacer()
                SettingsMenu(selection: $period, options: [(SpendPeriod.calendarMonth, "Calendar month"),
                                                           (.day, "Per day"), (.envelope, "Envelope without renewal")])
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Continue without a limit") { Task { await choose(enabled: false) } }.buttonStyle(.settings)
                Spacer()
                Button("Activate limit") { Task { await choose(enabled: true) } }
                    .buttonStyle(.settingsPrimary)
                    .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(activating)
        }
        .padding(26)
        .frame(width: 570, alignment: .leading)
        .aimDialogCard()
        .accessibilityIdentifier("spend-onboarding")
    }

    private func choose(enabled: Bool) async {
        guard !activating else { return }
        activating = true
        defer { activating = false }
        do {
            try await model.configureSpendPolicy(GlobalSpendPolicy(enabled: enabled,
                limitUSD: enabled ? amount.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                period: period, timeZoneID: TimeZone.current.identifier))
            errorMessage = nil
            onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
