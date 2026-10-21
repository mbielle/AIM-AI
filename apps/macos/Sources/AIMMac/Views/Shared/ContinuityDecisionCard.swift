import AIMApplication
import AIMCore
import SwiftUI

/// What a durable task waiting for the person is about, in plain words, and which buttons it offers.
struct ContinuityDecision: Equatable {
    enum Primary: Equatable { case resume, retry, accept, continueWithoutBlocked }
    var kind: String
    var symbol: String
    var title: String
    var detail: String?
    var primary: Primary?
    var spending = false
    var subagents = false

    private static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// nil when the task is not waiting for the person.
    static func make(_ execution: AgentExecution) -> ContinuityDecision? {
        let reason = execution.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch execution.state {
        case .waitingUser, .paused:
            if reason?.hasPrefix("Interrupted before any action") == true {
                return .init(kind: "Interrupted", symbol: "arrow.clockwise", title: "The task stopped before doing anything",
                             detail: "Nothing was changed. Retry sends a new request.", primary: .retry)
            }
            if reason?.contains("spending limit") == true {
                return .init(kind: "Spending limit", symbol: "creditcard", title: "The task is paused before sending a request",
                             detail: sentence(reason.map { $0.replacingOccurrences(of: "Paused before sending: ", with: "") } ?? "")
                                + " Raise or turn off the limit, then resume. Nothing was sent.",
                             primary: .resume, spending: true)
            }
            if reason?.hasPrefix("A sub-agent stopped") == true || reason?.contains("child requires") == true {
                return .init(kind: "Sub-agent", symbol: "person.2", title: "A sub-agent stopped and needs your decision",
                             detail: "The task continues once you decide. Continue without it stops that sub-agent and lets the agent carry on with what it has.",
                             primary: .continueWithoutBlocked, subagents: true)
            }
            if execution.state == .paused {
                return .init(kind: "Paused", symbol: "pause.circle", title: "The task is paused",
                             detail: reason == "Paused by user." ? nil : reason, primary: .resume)
            }
            return .init(kind: "Your input", symbol: "hand.raised", title: "The task is waiting for you",
                         detail: reason, primary: .resume)
        case .blocked:
            return .init(kind: "Review", symbol: "exclamationmark.triangle", title: "The task needs your review before it continues",
                         detail: reason, primary: .resume)
        case .awaitingReview:
            // A delivered answer ends the task, as in ChatGPT or Codex; a correction is just a new message.
            return nil
        case .failed:
            return .init(kind: "Failed", symbol: "xmark.circle", title: "The task failed", detail: reason, primary: .retry)
        default:
            return nil
        }
    }
}

/// A Codex-style card above the chat bar for a durable task that waits for the person:
/// its type, a plain question, and the decisions (Esc hides it; ⏎ takes the main one).
struct ContinuityDecisionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let execution: AgentExecution
    let decision: ContinuityDecision
    @State private var stopped: [SubagentSnapshot] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: decision.symbol)
                Text(decision.kind)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            Text(decision.title)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if let detail = decision.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(stopped) { child in
                HStack(alignment: .top, spacing: 8) {
                    SubagentAvatar(id: child.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(child.title).font(.system(size: 12.5, weight: .medium))
                        if let result = child.result, !result.isEmpty {
                            Text(result).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            ForEach((model.continuityProcesses[execution.id] ?? []).filter { $0.state == "unknown" }, id: \.id) { process in
                VStack(alignment: .leading, spacing: 4) {
                    Text("A command was interrupted (\(process.id.uuidString.prefix(8))). Check its effects in the folder before continuing.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Button("I checked; continue without running it again") { Task { await model.acknowledgeContinuityProcess(process.id) } }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            if let spend = model.continuitySpend[execution.id], spend.unknownAttempts > 0 {
                Text("\(spend.unknownAttempts) request(s) may have been billed without a confirmed cost.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if decision.spending {
                    Button("Spending limit…") { model.settingsSection = .usage }.buttonStyle(.settings)
                        .help("Raise or turn off the spending limit, then resume.")
                } else if decision.subagents {
                    Button("Open sub-agents") { model.requestedWorkbench = .init(kind: .subagents) }.buttonStyle(.settings)
                }
                if !execution.state.isTerminal && decision.primary != .accept {
                    Button("Cancel task") { act { await model.controlContinuityExecution(.cancel) } }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("continuity-cancel")
                }
                Spacer()
                Button { model.dismissedContinuityDecision = key } label: {
                    HStack(spacing: 7) {
                        Text("Dismiss")
                        Text("Esc").foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }
                }
                .buttonStyle(.settings)
                .keyboardShortcut(.escape, modifiers: [])
                if let primary = decision.primary {
                    Button { perform(primary) } label: {
                        HStack(spacing: 7) {
                            Text(title(primary))
                            Image(systemName: "return")
                        }
                    }
                    .buttonStyle(.settingsPrimary)
                    .keyboardShortcut(.return, modifiers: [])
                    .help(primary == .accept ? "Close the task with this result." : "Continues the task; new model requests may be billed.")
                    .accessibilityIdentifier("continuity-primary")
                }
            }
            .controlSize(.small)
            .disabled(working)
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
        .frame(maxWidth: 760, alignment: .leading)
        .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 12, y: 3)
        .shadow(color: .black.opacity(0.045), radius: 14, y: 4)
        .task(id: key + decision.kind) {
            guard decision.subagents, let conversation = model.selectedConversationID else { stopped = []; return }
            stopped = await model.subagents(conversationID: conversation)
                .filter { $0.executionID == execution.id && ($0.state == .blocked || $0.state == .paused) }
        }
        .onChange(of: key) { _, _ in working = false }
        .accessibilityIdentifier("continuity-decision")
    }

    /// One decision per execution revision: a dismissed card returns when the task changes.
    private var key: String { "\(execution.id.uuidString)-\(execution.revision)" }

    private func title(_ primary: ContinuityDecision.Primary) -> String {
        switch primary {
        case .resume: "Resume"
        case .retry: "Retry"
        case .accept: "Accept result"
        case .continueWithoutBlocked: "Continue without it"
        }
    }

    private func perform(_ primary: ContinuityDecision.Primary) {
        act {
            switch primary {
            case .resume, .retry: await model.controlContinuityExecution(.resume)
            case .accept: await model.controlContinuityExecution(.accept)
            case .continueWithoutBlocked:
                for child in stopped where child.state == .blocked {
                    await model.cancelSubagent(executionID: child.executionID, childID: child.id)
                }
                await model.controlContinuityExecution(.resume)
            }
        }
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        guard !working else { return }
        working = true
        Task { await work() }
    }
}

/// The small line Codex leaves in the conversation while a decision card waits below.
struct ContinuityWaitingLine: View {
    let execution: AgentExecution
    var body: some View {
        if let text {
            Label(text, systemImage: icon)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .accessibilityIdentifier("continuity-status")
        }
    }
    private var text: String? {
        switch execution.state {
        case .queued: Locale.current.language.languageCode?.identifier == "fr" ? "Préparation…" : "Preparing…"
        case .running: Locale.current.language.languageCode?.identifier == "fr" ? "En cours…" : "Working…"
        case .waitingUser, .paused, .blocked: "Waiting for your decision"
        case .waitingNetwork: "Waiting for the network"
        case .waitingEvent: "Waiting for sub-agents"
        case .failed: "The task failed"
        default: nil
        }
    }
    private var icon: String {
        switch execution.state {
        case .queued, .running: "sparkles"
        case .waitingNetwork: "wifi.slash"
        case .waitingEvent: "person.2"
        case .failed: "xmark.circle"
        default: "hand.raised"
        }
    }
}
