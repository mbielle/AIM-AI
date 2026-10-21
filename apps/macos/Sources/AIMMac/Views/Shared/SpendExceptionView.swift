import AIMApplication
import SwiftUI

/// A host decision for one billable request, independent of the active chat.
struct SpendExceptionView: View {
    @Environment(AppModel.self) private var model
    let request: PendingSpendException
    @State private var deciding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Spending limit needs your decision", systemImage: "dollarsign.circle")
                .font(.headline)
            Text(reason)
                .font(.subheadline)
            LabeledContent("Provider", value: request.provider)
            LabeledContent("Model", value: request.modelID)
            LabeledContent("AIM feature", value: request.feature)
            LabeledContent("Global limit", value: "$\(request.snapshot.policy.limitUSD ?? "?") USD")
            LabeledContent("Confirmed and reserved", value: "$\(request.snapshot.countedUSD) USD")
            if request.snapshot.unknownAttempts > 0 {
                LabeledContent("Prior costs still unknown", value: "\(request.snapshot.unknownAttempts) requests")
            }
            Text("Allowing this attempt could exceed your limit. AIM cannot promise the final provider charge. Your decision will be recorded and will not cover a retry or a later request.")
                .font(.caption).foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Do not send") { decide(false) }.buttonStyle(.settings)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Allow this attempt only") { decide(true) }
                    .buttonStyle(.settingsPrimary)
            }
            .disabled(deciding)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .aimDialogCard()
        .accessibilityIdentifier("spend-exception-approval")
        .onExitCommand { decide(false) }
    }

    private var reason: String {
        if request.maximumUSD == nil {
            return "AIM cannot calculate a verified maximum for this \(request.feature) request. It has not been sent."
        }
        return "A previous request has an unresolved charge, so AIM cannot determine the balance available for this request. It has not been sent."
    }

    private func decide(_ allow: Bool) {
        guard !deciding else { return }
        deciding = true
        Task { await model.decideSpendException(id: request.id, allow: allow) }
    }
}
