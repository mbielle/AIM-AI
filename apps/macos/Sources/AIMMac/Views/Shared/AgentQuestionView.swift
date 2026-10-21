import AIMAgentKit
import AIMMacPlatform
import SwiftUI

/// A suspended run's questions stay beside the composer while the transcript
/// remains visible and scrollable. One tool call may ask up to three questions.
struct AgentQuestionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let question: AgentQuestion
    @State private var index = 0
    @State private var selections: [Int: Set<String>] = [:]
    @State private var customAnswers: [Int: String] = [:]
    @State private var skipped: Set<Int> = []
    @State private var submitting = false
    @FocusState private var freeTextFocused: Bool
    @FocusState private var cardFocused: Bool

    private var current: AgentQuestionItem { question.items[index] }
    private var customAnswer: Binding<String> {
        Binding(get: { customAnswers[index] ?? "" }, set: { customAnswers[index] = $0; skipped.remove(index) })
    }
    private var hasAnswer: Bool {
        !(customAnswers[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !(selections[index] ?? []).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble")
                Text(question.items.count == 1 ? "Question" : "Question \(index + 1) of \(question.items.count)")
                Spacer()
                Text("The agent is waiting for your answer").foregroundStyle(.tertiary)
                Button { skipAll() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.aimHover(radius: 6))
                .help("Skip the questions; the agent continues with its own judgment")
                .accessibilityLabel("Skip questions")
                .accessibilityIdentifier("agent-question-close")
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)

            Text(current.question)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !current.options.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(current.options.enumerated()), id: \.offset) { offset, option in
                        let selected = selections[index]?.contains(option) == true
                        Button { choose(option) } label: {
                            HStack(spacing: 10) {
                                Text("\(offset + 1)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .background(Color.primary.opacity(0.045), in: Circle())
                                Text(option).font(.system(size: 13, weight: selected ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-question-option-\(offset)")
                    }
                }
            }

            HStack(spacing: 9) {
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Or write your own response", text: customAnswer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($freeTextFocused)
                    .onSubmit { advance() }
                    .accessibilityIdentifier("agent-question-free-text")
                QuestionDictationButton { text in
                    let existing = customAnswers[index] ?? ""
                    customAnswer.wrappedValue = existing.isEmpty ? text : existing + " " + text
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                if index > 0 {
                    Button("Back") { index -= 1 }.buttonStyle(.settings)
                }
                Spacer()
                Button { skipped.insert(index); advance(force: true) } label: {
                    HStack(spacing: 7) {
                        Text("Skip")
                        Text("Esc").foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }
                }
                .buttonStyle(.settings)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("agent-question-skip")
                Button { advance() } label: {
                    HStack(spacing: 7) {
                        Text(index == question.items.count - 1 ? "Send" : "Next")
                        Image(systemName: "return")
                    }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(!hasAnswer)
                .accessibilityIdentifier("agent-question-send")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: 760, alignment: .leading)
        .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 12, y: 3)
        .shadow(color: .black.opacity(0.045), radius: 14, y: 4)
        .disabled(submitting)
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onAppear { cardFocused = true }
        // 1–9 pick an option while the text field is not being typed in.
        .onKeyPress(characters: .decimalDigits) { press in
            guard !freeTextFocused, let digit = Int(press.characters), digit >= 1, digit <= current.options.count else { return .ignored }
            choose(current.options[digit - 1])
            if !current.multi { advance() }
            return .handled
        }
        .onKeyPress(.return) {
            guard !freeTextFocused, hasAnswer else { return .ignored }
            advance(); return .handled
        }
        .onChange(of: question.id) { _, _ in
            index = 0; selections = [:]; customAnswers = [:]; skipped = []; submitting = false
        }
        .accessibilityIdentifier("agent-question")
    }

    private func skipAll() {
        for position in question.items.indices where position >= index { skipped.insert(position) }
        index = question.items.count - 1
        advance(force: true)
    }

    private func choose(_ option: String) {
        skipped.remove(index)
        var selected = selections[index] ?? []
        if current.multi {
            if !selected.insert(option).inserted { selected.remove(option) }
        } else {
            selected = [option]
        }
        selections[index] = selected
    }

    private func advance(force: Bool = false) {
        guard force || hasAnswer else { return }
        if index < question.items.count - 1 { index += 1; return }
        let answers = question.items.indices.map { position -> String in
            if skipped.contains(position) { return "Skipped" }
            let custom = (customAnswers[position] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            let selected = selections[position] ?? []
            return question.items[position].options.filter { selected.contains($0) }.joined(separator: ", ")
        }
        let response = answers.count == 1 ? answers[0] : answers.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        submitting = true
        Task {
            let accepted = await model.answerAgentQuestion(question, answer: response)
            if !accepted { submitting = false }
        }
    }
}

/// The microphone beside a question's answer field: records, then transcribes with the same
/// engine and language as the composer, and hands the text over to be added to the answer.
private struct QuestionDictationButton: View {
    @Environment(AppModel.self) private var model
    let insert: (String) -> Void
    @State private var recorder = DictationRecorder()
    @State private var phase = 0 // 0 idle, 1 recording, 2 transcribing
    @State private var failure: String?

    var body: some View {
        Button { phase == 1 ? stop() : start() } label: {
            Group {
                if phase == 2 { ProgressView().controlSize(.mini) }
                else { Image(systemName: phase == 1 ? "stop.circle.fill" : "mic") }
            }
            .font(.system(size: 13)).frame(width: 22, height: 22)
            .foregroundStyle(phase == 1 ? Color.red : .secondary)
        }
        .buttonStyle(.aimHover(radius: 6))
        .disabled(phase == 2)
        .help(failure ?? (phase == 1 ? "Stop and transcribe" : "Dictate your answer"))
        .accessibilityLabel(phase == 1 ? "Stop dictation" : "Dictate")
        .accessibilityIdentifier("agent-question-dictate")
        .onDisappear { if phase == 1 { recorder.cancel() } }
    }

    private func start() {
        let hasKey = model.connectedProviders.contains(.openAI)
        let engine = DictationEngine.effective(hasOpenAIKey: hasKey)
        guard DictationAvailability.check(engine, hasOpenAIKey: hasKey, isDownloaded: LocalDictationModels.shared.isReady) == .ready else {
            failure = "Set up dictation from the composer's microphone menu first."; return
        }
        failure = nil
        Task {
            do { try await recorder.start(); phase = 1 }
            catch { failure = error.localizedDescription; phase = 0 }
        }
    }

    private func stop() {
        let engine = DictationEngine.effective(hasOpenAIKey: model.connectedProviders.contains(.openAI))
        let url: URL
        do { url = try recorder.stop() } catch { failure = error.localizedDescription; phase = 0; return }
        phase = 2
        Task {
            do {
                let text: String
                switch engine {
                case .apple: text = try await AppleFileDictation.transcribe(url)
                case .openAI: text = try await model.transcribeWithOpenAI(Data(contentsOf: url), language: DictationLanguage.code())
                case .whisper, .parakeet: text = try await LocalDictationModels.shared.transcribe(url, with: engine)
                }
                DictationRecorder.discard(url)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { insert(trimmed) }
            } catch { failure = error.localizedDescription }
            phase = 0
        }
    }
}
