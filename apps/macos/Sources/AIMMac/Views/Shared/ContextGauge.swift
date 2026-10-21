import AIMApplication
import SwiftUI

/// A small ring in the composer showing how full the context window is; it opens the context
/// popover (as in Claude): what fills the window, compaction, and what the person has spent.
struct ContextGauge: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let usage = model.displayedContextUsage
        Button { open.toggle() } label: {
            // A new ring per conversation: its fill never animates from another conversation's
            // value while the chat bar moves (the detached blue dot).
            ContextRing(fraction: usage?.fraction ?? 0, compacting: model.isCompacting)
                .id(model.selectedConversationID)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.aimHover(radius: 9, active: open))
        .aimTooltip(usage?.fraction.map { "Context " + $0.formatted(.percent.precision(.fractionLength(0))) + " full" } ?? "Context and spending")
        .accessibilityLabel("Context and spending")
        .aimMenu(isPresented: $open, alignment: .trailing, maxWidth: 420) {
            ContextPopover(close: { open = false }).frame(width: 380)
        }
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, menu in open = menu?.hasPrefix("context") == true }
        #endif
    }
}

struct ContextRing: View {
    let fraction: Double
    var compacting = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.4)
            Circle().trim(from: 0, to: compacting ? 0.3 : max(0.02, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(compacting && spin ? 270 : -90))
                .animation(compacting ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3), value: spin)
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(width: 15, height: 15)
        .onChange(of: compacting) { _, value in spin = value }
    }

    private var color: Color {
        fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : Color(red: 0.25, green: 0.47, blue: 0.85)
    }
}

/// The popover's content.
struct ContextPopover: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    @State private var window: AppModel.SpendWindow = .daily
    @State private var spend = AppModel.SpendOverview()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextSection.padding(16)
            Divider()
            spendSection.padding(16)
            Divider()
            Button {
                close()
                model.settingsSection = .usage
            } label: {
                Text("View detailed spending").font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
            }
            .buttonStyle(.aimHover(radius: 7)).padding(16)
        }
        .task(id: window) { spend = await model.spendOverview(period: window) }
        #if DEBUG
        .onAppear { if model.debugOpenMenu == "context-expanded" { expanded = true } }
        #endif
    }

    // MARK: Context

    @ViewBuilder private var contextSection: some View {
        let usage = model.displayedContextUsage
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                HStack {
                    Text("Context window").foregroundStyle(.secondary)
                    Spacer()
                    Text(headline(usage)).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: 13)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SegmentedUsageBar(usage: usage)
            if expanded, let usage { breakdown(usage).transition(.opacity.combined(with: .move(edge: .top))) }
            HStack(spacing: 10) {
                Text(compactionText(usage)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    Task { await model.compactConversation() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isCompacting { ProgressView().controlSize(.mini) }
                        Text(model.isCompacting ? "Compacting…" : "Compact the session")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                }
                .buttonStyle(.aimHover(radius: 7))
                .disabled(model.selectedConversationID == nil || model.isSending || model.isCompacting || model.messages.count < 6)
                .help("The model summarizes the conversation except the last exchanges; the original messages stay in the history.")
            }
        }
    }

    private func breakdown(_ usage: ContextUsage) -> some View {
        VStack(spacing: 6) {
            ForEach(ContextUsage.Part.allCases, id: \.self) { part in
                let tokens = usage.tokens(part)
                if tokens > 0 {
                    row(color: Self.color(part), title: part.title, tokens: tokens, limit: usage.limit)
                }
            }
            if let limit = usage.limit {
                // AIM compacts early on very large windows to save cost; the buffer is only drawn near the end.
                if let auto = usage.autoCompactAt, auto < limit, auto * 2 >= limit {
                    row(color: Color.primary.opacity(0.18), title: "Auto-compact buffer", tokens: limit - auto, limit: limit)
                }
                row(color: Color.primary.opacity(0.07), title: "Free space", tokens: max(0, limit - usage.total), limit: limit)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(color: Color, title: String, tokens: Int, limit: Int?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 11, height: 11)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Text(Self.short(tokens)).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
            Text(limit.map { (Double(tokens) / Double(max($0, 1))).formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                .font(.system(size: 12.5, weight: .medium)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func headline(_ usage: ContextUsage?) -> String {
        guard let usage else { return "—" }
        guard let limit = usage.limit else { return Self.short(usage.total) + " tokens" }
        let percent = (Double(usage.total) / Double(max(limit, 1))).formatted(.percent.precision(.fractionLength(0)))
        return "\(Self.short(usage.total)) / \(Self.short(limit)) (\(percent))"
    }

    private func compactionText(_ usage: ContextUsage?) -> String {
        guard let usage, let auto = usage.autoCompactAt else { return "Compacts automatically when full" }
        let left = auto - usage.total
        return left > 0 ? "\(Self.short(left)) tokens before auto-compaction" : "Compacts at next message"
    }

    // MARK: Spending

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                ProfileTabs(selection: $window, options: [(.daily, "Daily"), (.weekly, "Weekly"), (.monthly, "Monthly")])
            }
            HStack {
                Text("This conversation").font(.system(size: 13))
                Spacer()
                Text(Self.usd(spend.conversationUSD, estimated: spend.conversationEstimated)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            HStack {
                Text(window == .daily ? "Today" : window == .weekly ? "This week" : "This month").font(.system(size: 13))
                Spacer()
                Text(Self.usd(spend.periodUSD, estimated: spend.periodEstimated)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            if let limit = spend.limitUSD {
                let fraction = min(1, spend.limitUsedUSD / limit)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(spend.limitPeriodName ?? "Limit").font(.system(size: 13))
                        Spacer()
                        if let reset = spend.limitResetsAt {
                            Text("Resets " + reset.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(fraction >= 0.9 ? Color.red : fraction >= 0.7 ? Color.orange : Color(red: 0.25, green: 0.47, blue: 0.85))
                                .frame(width: max(4, geometry.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Self.usd(spend.limitUsedUSD, estimated: false)) of \(Self.usd(limit, estimated: false))")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Formatting

    static func color(_ part: ContextUsage.Part) -> Color {
        switch part {
        case .messages: Color(red: 0.25, green: 0.47, blue: 0.85)
        case .summary: Color(red: 0.45, green: 0.62, blue: 0.95)
        case .systemTools: Color(red: 0.88, green: 0.42, blue: 0.27)
        case .mcpTools: Color(red: 0.30, green: 0.68, blue: 0.50)
        case .systemPrompt: Color(red: 0.92, green: 0.65, blue: 0.22)
        case .skills: Color(red: 0.55, green: 0.55, blue: 0.55)
        case .memory: Color(red: 0.45, green: 0.45, blue: 0.47)
        case .projectContext: Color(red: 0.62, green: 0.45, blue: 0.82)
        case .attachments: Color(red: 0.35, green: 0.70, blue: 0.80)
        }
    }

    static func short(_ value: Int) -> String {
        value >= 1_000_000 ? (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
            : value >= 1_000 ? (Double(value) / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "k"
            : value.formatted()
    }

    static func usd(_ value: Double, estimated: Bool) -> String {
        let digits = value > 0 && value < 0.1 ? 4 : 2
        return (estimated ? "≈ " : "") + "$" + value.formatted(.number.precision(.fractionLength(digits)))
    }
}

/// The context bar: one coloured segment per part, the auto-compaction buffer, then free space.
struct SegmentedUsageBar: View {
    let usage: ContextUsage?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let limit = Double(max(usage?.limit ?? usage?.total ?? 1, 1))
            HStack(spacing: 1.5) {
                if let usage {
                    ForEach(ContextUsage.Part.allCases, id: \.self) { part in
                        let tokens = usage.tokens(part)
                        if tokens > 0 {
                            Rectangle().fill(ContextPopover.color(part)).frame(width: max(2, width * Double(tokens) / limit))
                        }
                    }
                    if let full = usage.limit, let auto = usage.autoCompactAt, auto < full, auto * 2 >= full {
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.primary.opacity(0.18)).frame(width: width * Double(full - auto) / limit)
                    }
                }
            }
            .frame(width: width, alignment: .leading)
            .background(Color.primary.opacity(0.07))
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}
