import AIMApplication
import SwiftUI

struct AgentPlanView: View {
    let plan: AgentPlan
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Plan").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(plan.steps.filter { $0.status == .done }.count)/\(plan.steps.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: step.status))
                        .foregroundStyle(step.status == .doing ? Color.accentColor : .secondary)
                    Text(step.title).font(.system(size: 12))
                        .foregroundStyle(step.status == .done ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 760, alignment: .leading)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
        .accessibilityElement(children: .contain)
    }

    private func symbol(for status: AgentPlanStepStatus) -> String {
        switch status {
        case .todo: "circle"
        case .doing: "circle.dotted"
        case .done: "checkmark.circle.fill"
        }
    }
}
