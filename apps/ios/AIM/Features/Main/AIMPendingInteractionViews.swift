import AIMCore
import SwiftUI
import UIKit

struct AIMRemoteVisualApprovalCard: View {
    let approval: RemotePendingApproval
    let store: MainExperienceStore
    let online: Bool
    @State private var selected = ""
    @State private var busy = false
    private var choices: [RemoteJSONValue] { approval.questions ?? [] }
    private var chosen: [String: RemoteJSONValue]? {
        choices.first { ($0.objectValue?["provider"]?.stringValue ?? "") + ":" + ($0.objectValue?["model_id"]?.stringValue ?? "") == selected }?.objectValue
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Visual sub-agent", systemImage: "eye").font(.headline)
            Text(approval.summary).font(.caption).foregroundStyle(.secondary)
            Picker("Provider and visual model", selection: $selected) {
                Text("Choose a model").tag("")
                ForEach(Array(choices.enumerated()), id: \.offset) { _, value in
                    let row = value.objectValue ?? [:]
                    let provider = row["provider"]?.stringValue ?? ""
                    let id = row["model_id"]?.stringValue ?? ""
                    Text(provider + " · " + (row["name"]?.stringValue ?? id)).tag(provider + ":" + id)
                }
            }.tint(.primary).disabled(busy)
            Text("No model is substituted. Cost may be unknown; the execution Mac checks its budget before each request.").font(.caption).foregroundStyle(.secondary)
            if choices.isEmpty { Text("No compatible visual model is available on this Mac. Connect a provider or install a compatible model there.").font(.caption).foregroundStyle(.orange) }
            if !online { Text("Reconnect to this Mac to respond.").font(.caption).foregroundStyle(.orange) }
            ViewThatFits(in: .horizontal) {
                HStack { consentButton("Decline", approve: false); consentButton("Allow once"); consentButton("Always allow", remember: true) }
                VStack { consentButton("Decline", approve: false); consentButton("Allow once"); consentButton("Always allow", remember: true) }
            }
        }.padding(16).modifier(AIMComposerBackground())
        .accessibilityIdentifier("remote-visual-approval")
    }
    private func consentButton(_ title: String, approve: Bool = true, remember: Bool = false) -> some View {
        Button(title) {
            let route = chosen
            busy = true
            Task {
                _ = await store.respondToVisualApproval(approval, provider: route?["provider"]?.stringValue, modelID: route?["model_id"]?.stringValue, remember: remember, approved: approve)
                busy = false
            }
        }.buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(approve && !remember ? Color(uiColor: .label) : Color(uiColor: .label).opacity(0.07), in: Capsule())
            .foregroundStyle(approve && !remember ? Color(uiColor: .systemBackground) : Color.primary)
            .disabled(busy || !online || (approve && chosen == nil))
    }
}

private struct AIMPendingSummaryHeight: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AIMPendingApprovalCard: View {
    let approval: RemotePendingApproval
    let online: Bool
    let busy: Bool
    let respond: (Bool) async -> Bool
    let answerQuestion: (String) async -> Bool
    @State private var showingQuestions = false
    @State private var responding = false
    @State private var summaryHeight: CGFloat = 1

    private var questions: [RemoteQuestion]? {
        guard approval.kind == "question", let raw = approval.questions else { return nil }
        return RemoteQuestionRules.pendingQuestions(
            from: .object(["kind": .string("question"), "questions": .array(raw)])
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.kind == "question" ? "remote.conversation.question" : "remote.conversation.approval", systemImage: approval.kind == "question" ? "questionmark.circle" : "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            if !approval.summary.isEmpty {
                ScrollView(.vertical) {
                    summaryText
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: AIMPendingSummaryHeight.self, value: geometry.size.height)
                            }
                        }
                }
                .scrollIndicators(.visible)
                .frame(height: min(summaryHeight, min(120, max(56, UIScreen.main.bounds.height * 0.12))))
                .onPreferenceChange(AIMPendingSummaryHeight.self) { summaryHeight = max(1, $0) }
                .accessibilityIdentifier("pending-interaction-summary")
            }
            if !online {
                Text("remote.conversation.approval_offline")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let questions, !questions.isEmpty {
                Button {
                    showingQuestions = true
                } label: {
                    Label("remote.questions.answer", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color(uiColor: .label), in: Capsule())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .disabled(busy)
                .accessibilityIdentifier("answer-agent-questions")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { consentButton(allow: false); consentButton(allow: true) }
                    VStack(spacing: 8) { consentButton(allow: true); consentButton(allow: false) }
                }
                .disabled(busy || responding)

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .modifier(AIMComposerBackground())
        .sheet(isPresented: $showingQuestions) {
            if let questions {
                AIMRemoteQuestionsSheet(
                    questions: questions,
                    busy: busy,
                    submit: answerQuestion
                )
            }
        }
    }
    private var summaryText: some View {
        Text(approval.summary)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func consentButton(allow: Bool) -> some View {
        Button {
            guard !busy, !responding else { return }
            responding = true
            Task {
                _ = await respond(allow)
                responding = false
            }
        } label: {
            Label(allow ? "remote.conversation.allow" : "remote.conversation.reject", systemImage: allow ? "checkmark" : "xmark")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .background(allow ? Color(uiColor: .label) : Color(uiColor: .label).opacity(0.07), in: Capsule())
                .foregroundStyle(allow ? Color(uiColor: .systemBackground) : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(allow ? "pending-approval-allow" : "pending-approval-reject")
    }

}

private struct AIMRemoteQuestionsSheet: View {
    let questions: [RemoteQuestion]
    let busy: Bool
    let submit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selections: [[String]]
    @State private var freeTexts: [String]
    @State private var skipped: [Bool]
    @State private var submitting = false

    init(questions: [RemoteQuestion], busy: Bool, submit: @escaping (String) async -> Bool) {
        self.questions = questions
        self.busy = busy
        self.submit = submit
        _selections = State(initialValue: questions.map { _ in [] })
        _freeTexts = State(initialValue: questions.map { _ in "" })
        _skipped = State(initialValue: questions.map { _ in false })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(question, at: index)
                    }
                }
                .padding(18)
            }
            .navigationTitle("remote.questions.title")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    let answers = RemoteQuestionRules.composeAnswers(
                        questions: questions,
                        choices: selections,
                        texts: freeTexts,
                        skipped: skipped
                    )
                    submitting = true
                    Task {
                        if await submit(answers) { dismiss() }
                        submitting = false
                    }
                } label: {
                    Group {
                        if submitting { ProgressView().tint(Color(uiColor: .systemBackground)) }
                        else { Text("remote.questions.submit") }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.plain)
                .background(Color.primary, in: Capsule())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .disabled(busy || submitting)
                .padding(16)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
    }

    @ViewBuilder
    private func questionView(_ question: RemoteQuestion, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.system(size: 16, weight: .semibold))
            if question.multi {
                Text("remote.questions.multiple_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !question.options.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Button {
                            toggle(option.label, for: question, at: index)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 15, weight: .medium))
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selections[index].contains(option.label) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 54)
                        }
                        .buttonStyle(.plain)
                        .disabled(skipped[index])
                        if optionIndex < question.options.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
                .opacity(skipped[index] ? 0.5 : 1)
            }
            TextField(
                question.options.isEmpty ? "remote.questions.free_placeholder" : "remote.questions.other_placeholder",
                text: Binding(
                    get: { freeTexts[index] },
                    set: { freeTexts[index] = $0; skipped[index] = false }
                ),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)

            Button {
                skipped[index].toggle()
            } label: {
                Label("remote.questions.skip", systemImage: skipped[index] ? "checkmark.circle.fill" : "forward")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(skipped[index] ? .primary : .secondary)
        }
    }

    private func toggle(_ label: String, for question: RemoteQuestion, at index: Int) {
        skipped[index] = false
        if question.multi {
            if let selectedIndex = selections[index].firstIndex(of: label) {
                selections[index].remove(at: selectedIndex)
            } else {
                selections[index].append(label)
            }
        } else {
            selections[index] = selections[index] == [label] ? [] : [label]
        }
    }
}
