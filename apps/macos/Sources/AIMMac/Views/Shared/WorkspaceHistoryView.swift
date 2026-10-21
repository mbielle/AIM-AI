import AIMCore
import AIMApplication
import SwiftUI

struct WorkspaceHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Workspace action history").font(.title2)
                Spacer()
                Button("Refresh") { Task { await model.loadWorkspaceHistory() } }
                Button("Done") { dismiss() }
            }
            Text("Local history for the latest 10 runs, plus blocked or reviewed mission runs. A missing result does not prove that an action did not execute. Review the current target before recording an observation.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.workspaceHistoryError { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.workspaceHistory) { history in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(history.run.startedAt, style: .date)
                                Text(history.run.startedAt, style: .time)
                                Spacer()
                                Text(history.run.state == .running ? "Unfinished record" : history.run.state.rawValue.capitalized)
                            }.font(.system(size: 12, weight: .medium))
                            Text("\(history.run.provider.name) · \(history.run.modelID)").font(.system(size: 12))
                            Text(history.run.workspacePath).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(history.calls) { call in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(String(decoding: call.argumentsJSON, as: UTF8.self))
                                        Text(call.result ?? "No result was durably recorded. This action will not be replayed automatically.")
                                    }
                                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                } label: {
                                    HStack {
                                        Text(ToolDisplayName.title(call.name))
                                        Spacer()
                                        Text(call.state == .requested ? "Requested · result unknown" : call.state.rawValue.capitalized)
                                            .foregroundStyle(.secondary)
                                    }.font(.system(size: 12))
                                }
                                if let record = model.actionReconciliations.first(where: {
                                    $0.runID == history.run.id && $0.callID == call.id
                                }) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("User observed: \(record.assessment == .observed ? "effect present" : "no effect found")")
                                            .font(.caption.weight(.semibold))
                                        Text(record.note).font(.caption).textSelection(.enabled)
                                    }.padding(.leading, 12)
                                }
                            }
                            if let mission = model.agentMission, mission.state == .blocked,
                               mission.activeRunID == history.run.id {
                                let uncertain = history.calls.filter(\.requiresReconciliation)
                                ForEach(uncertain) { call in
                                    if !model.actionReconciliations.contains(where: {
                                        $0.runID == history.run.id && $0.callID == call.id
                                    }) {
                                        ActionReviewRow(call: call)
                                    }
                                }
                                let reviewedIDs = Set(model.actionReconciliations.filter { $0.runID == history.run.id }.map(\.callID))
                                if Set(uncertain.map(\.id)).isSubset(of: reviewedIDs) {
                                    ReviewCompletionSection()
                                }
                            }
                            if history.calls.isEmpty { Text("No tool request was recorded.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.workspaceHistory.isEmpty, model.workspaceHistoryError == nil {
                        Text("No workspace actions recorded yet.").foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }
        }
        .padding(24).frame(width: 680, height: 540)
        .task(id: model.selectedConversationID) { await model.loadWorkspaceHistory() }
        .onChange(of: model.completedToolCount) { _, _ in Task { await model.loadWorkspaceHistory() } }
        .onChange(of: model.isSending) { _, _ in Task { await model.loadWorkspaceHistory() } }
    }
}

private struct ActionReviewRow: View {
    @Environment(AppModel.self) private var model
    let call: WorkspaceCall
    @State private var assessment: ActionEffectAssessment = .observed
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What happened after \(ToolDisplayName.title(call.name).lowercased())?").font(.caption.weight(.semibold))
            Picker("Observed effect", selection: $assessment) {
                Text("I observed an effect").tag(ActionEffectAssessment.observed)
                Text("I did not observe an effect").tag(ActionEffectAssessment.notObserved)
            }.labelsHidden().frame(maxWidth: 230)
            TextField("Describe what you checked in the target", text: $note, axis: .vertical)
                .lineLimit(2...4)
            Button("Record my observation") {
                Task { _ = await model.recordActionReview(callID: call.id, assessment: assessment, note: note) }
            }
            .disabled(model.isReviewingMission || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("action-review-\(call.id)")
    }
}

private struct ReviewCompletionSection: View {
    @Environment(AppModel.self) private var model
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Complete the mission review").font(.caption.weight(.semibold))
            Text("This unlocks a new turn. It does not mark the mission successful or replay an action.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("What should AIM do next?", text: $note, axis: .vertical)
                .lineLimit(2...4)
            Button("Complete review") {
                Task { _ = await model.completeMissionReview(note: note) }
            }
            .disabled(model.isReviewingMission || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mission-complete-review")
    }
}
