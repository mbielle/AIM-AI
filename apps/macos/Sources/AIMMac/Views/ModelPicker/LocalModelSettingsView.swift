import AIMApplication
import AIMMacPlatform
import SwiftUI

/// One local model's own settings: context and memory, instructions, response length and
/// sampling. Saved at once; context and cache changes reload the model before the next message.
struct LocalModelSettingsView: View {
    let name: String
    let file: URL?
    let creator: String

    @Environment(\.colorScheme) private var scheme
    @State private var settings = LocalModelSettings()
    @State private var architecture: LocalModelMemory.Architecture?
    @State private var weights: Int64 = 0
    @State private var budget: Int64 = LocalModelMemory.budget()
    @State private var loaded = false
    @State private var newStop = ""
    private let store = LocalModelSettingsStore.shared

    private var recommended: LocalModelSettings { .recommended(modelID: name) }
    private var quantized: Bool { settings.kvCacheQuantized ?? false }
    private var recommendedContext: Int {
        LocalModelMemory.recommendedContext(weightsBytes: weights, architecture: architecture, quantizedCache: quantized, budget: budget)
    }
    private var context: Int { min(settings.contextTokens ?? recommendedContext, maxContext) }
    private var maxContext: Int { architecture?.maxContext ?? 131_072 }
    private var estimate: LocalModelMemory.Estimate {
        LocalModelMemory.estimate(weightsBytes: weights, architecture: architecture, context: context, quantizedCache: quantized, budget: budget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                ModelCreatorLogo(creator: creator, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text("Settings for this model only · saved on this Mac").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset all") { update { $0 = LocalModelSettings() } }
                    .buttonStyle(.settings).disabled(settings.isDefault)
            }

            group("Memory and context", icon: "memorychip") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Context length").font(.system(size: 13, weight: .medium))
                        info("How much of the conversation the model can read at once. More context uses more memory.")
                        Spacer()
                        resetButton(settings.contextTokens != nil) { update { $0.contextTokens = nil } }
                        TextField("", value: Binding(get: { context }, set: { value in
                            update { $0.contextTokens = min(max(value, 1_024), maxContext) }
                        }), format: .number.grouping(.never))
                        .textFieldStyle(.settings).frame(width: 88).multilineTextAlignment(.trailing)
                    }
                    Slider(value: Binding(get: { Double(stepIndex(context)) }, set: { index in
                        let steps = availableSteps
                        update { $0.contextTokens = steps[min(max(Int(index.rounded()), 0), steps.count - 1)] }
                    }), in: 0...Double(max(availableSteps.count - 1, 1)), step: 1)
                    .tint(AIMTheme.toggleOn)
                    HStack {
                        Text("Recommended: \(Self.tokens(recommendedContext))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text(architecture?.maxContext.map { "Model supports up to \(Self.tokens($0))" } ?? "Model limit unknown")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    MemoryBar(estimate: estimate)
                    if estimate.verdict == .tooLarge {
                        HStack {
                            SettingsNotice("This context does not fit in this Mac's memory: the model would fail to load or slow the Mac down.", tone: .warning)
                            Button("Use the largest that fits") {
                                let largest = LocalModelMemory.largestFittingContext(weightsBytes: weights, architecture: architecture,
                                                                                    quantizedCache: quantized, budget: budget)
                                update { $0.contextTokens = max(2_048, largest * 9 / 10 / 1_024 * 1_024) }
                            }.buttonStyle(.settings)
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("KV cache quantization").font(.system(size: 13, weight: .medium))
                                Text("Experimental").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            Text("Stores the context in 8 bits: half the memory for the same context, very slightly less precise.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SettingsSwitch(isOn: Binding(get: { quantized }, set: { value in update { $0.kvCacheQuantized = value ? true : nil } }))
                    }
                }
            }

            group("Responses", icon: "text.bubble") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Instructions").font(.system(size: 13, weight: .medium))
                        info("Replaces AIM's instructions for this model. Leave empty to use AIM's.")
                        Spacer()
                        resetButton(settings.customSystemPrompt != nil) { update { $0.systemPrompt = nil } }
                    }
                    ZStack(alignment: .topLeading) {
                        if (settings.systemPrompt ?? "").isEmpty {
                            Text(LocalModelTuning.systemPrompt(mode: .chat))
                                .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(get: { settings.systemPrompt ?? "" }, set: { value in update { $0.systemPrompt = value } }))
                            .font(.system(size: 12.5)).scrollContentBackground(.hidden).focusEffectDisabled()
                    }
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                    Divider()
                    HStack {
                        Text("Limit response length").font(.system(size: 13, weight: .medium))
                        info("Stops the answer after this many tokens. Off: the model finishes when it is done.")
                        Spacer()
                        if let limit = settings.maxResponseTokens {
                            TextField("", value: Binding(get: { limit }, set: { value in update { $0.maxResponseTokens = max(16, value) } }),
                                      format: .number.grouping(.never))
                            .textFieldStyle(.settings).frame(width: 80).multilineTextAlignment(.trailing)
                        }
                        SettingsSwitch(isOn: Binding(get: { settings.maxResponseTokens != nil },
                                                     set: { value in update { $0.maxResponseTokens = value ? 2_048 : nil } }))
                    }
                }
            }

            Color.clear.frame(height: 0).id("local-sampling")
            group("Sampling", icon: "dial.medium") {
                VStack(alignment: .leading, spacing: 16) {
                    parameter("Temperature", help: "Higher is more varied and creative, lower is more focused and predictable.",
                              value: \.temperature, range: 0...2, step: 0.05, digits: 2)
                    parameter("Top P", help: "Keeps the smallest set of likely words whose probabilities add up to this value.",
                              value: \.topP, range: 0...1, step: 0.01, digits: 2)
                    parameter("Min P", help: "Ignores words much less likely than the best one.",
                              value: \.minP, range: 0...1, step: 0.01, digits: 2)
                    parameter("Repeat penalty", help: "Above 1 discourages repeating the same words.",
                              value: \.repeatPenalty, range: 0.8...2, step: 0.01, digits: 2)
                    integer("Top K", help: "Picks among this many most likely words.", value: \.topK, fallback: recommended.topK ?? 40)
                    HStack {
                        Text("Seed").font(.system(size: 13, weight: .medium))
                        info("A fixed seed gives the same answer to the same message; random gives variety.")
                        Spacer()
                        if let seed = settings.seed {
                            TextField("", value: Binding(get: { seed }, set: { value in update { $0.seed = max(0, value) } }),
                                      format: .number.grouping(.never))
                            .textFieldStyle(.settings).frame(width: 90).multilineTextAlignment(.trailing)
                        } else {
                            Text("Random").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        SettingsSwitch(isOn: Binding(get: { settings.seed != nil }, set: { value in update { $0.seed = value ? 42 : nil } }))
                    }
                    stopStrings
                }
            }

            Text("Changes apply to your next message. Context and memory changes reload the model, which takes a few seconds.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .task(id: name) { await load() }
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.03))
            Divider()
            content().padding(16)
        }
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }

    private func info(_ text: String) -> some View {
        Image(systemName: "questionmark.circle").font(.system(size: 11.5)).foregroundStyle(.tertiary).help(text)
    }

    private func resetButton(_ visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22)
        }
        .buttonStyle(.aimHover(radius: 6)).foregroundStyle(.secondary)
        .help("Back to the recommended value").accessibilityLabel("Reset")
        .opacity(visible ? 1 : 0).allowsHitTesting(visible)
    }

    private func parameter(_ title: String, help: String, value: WritableKeyPath<LocalModelSettings, Double?>,
                           range: ClosedRange<Double>, step: Double, digits: Int) -> some View {
        let current = settings[keyPath: value] ?? recommended[keyPath: value] ?? range.lowerBound
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                info(help)
                if settings[keyPath: value] == nil {
                    Text("recommended").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                resetButton(settings[keyPath: value] != nil) { update { $0[keyPath: value] = nil } }
                TextField("", value: Binding(get: { current }, set: { new in
                    update { $0[keyPath: value] = min(max(new, range.lowerBound), range.upperBound) }
                }), format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.settings).frame(width: 70).multilineTextAlignment(.trailing)
            }
            Slider(value: Binding(get: { current }, set: { new in
                update { $0[keyPath: value] = (new / step).rounded() * step }
            }), in: range).tint(AIMTheme.toggleOn)
        }
    }

    private func integer(_ title: String, help: String, value: WritableKeyPath<LocalModelSettings, Int?>, fallback: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            info(help)
            if settings[keyPath: value] == nil { Text("recommended").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Spacer()
            resetButton(settings[keyPath: value] != nil) { update { $0[keyPath: value] = nil } }
            TextField("", value: Binding(get: { settings[keyPath: value] ?? fallback }, set: { new in
                update { $0[keyPath: value] = max(0, new) }
            }), format: .number.grouping(.never))
            .textFieldStyle(.settings).frame(width: 70).multilineTextAlignment(.trailing)
        }
    }

    private var stopStrings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stop strings").font(.system(size: 13, weight: .medium))
                info("The answer ends as soon as the model writes one of these (up to 4).")
                Spacer()
                TextField("Type and press Return", text: $newStop)
                    .textFieldStyle(.settings).frame(width: 190)
                    .onSubmit {
                        let value = newStop
                        guard !value.isEmpty else { return }
                        update { $0.stopStrings = Array(Set(($0.stopStrings ?? []) + [value])).sorted().prefix(4).map { $0 } }
                        newStop = ""
                    }
            }
            if let stops = settings.stopStrings, !stops.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(stops, id: \.self) { stop in
                        HStack(spacing: 5) {
                            Text(stop.replacingOccurrences(of: "\n", with: "⏎")).font(.system(size: 12, design: .monospaced))
                            Button { update { $0.stopStrings = $0.stopStrings?.filter { $0 != stop }; if $0.stopStrings?.isEmpty == true { $0.stopStrings = nil } } } label: {
                                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(stop)")
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Data

    private var availableSteps: [Int] {
        var steps = LocalModelMemory.contextSteps.filter { $0 < maxContext }
        steps.append(maxContext)
        return steps
    }

    private func stepIndex(_ value: Int) -> Int {
        availableSteps.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
    }

    private func update(_ change: (inout LocalModelSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        withAnimation(.easeOut(duration: 0.15)) { settings = next }
        store.save(next, for: name)
    }

    private func load() async {
        settings = store.settings(for: name)
        guard let file else { return }
        let measured = await Task.detached(priority: .userInitiated) {
            (LocalModelMemory.weightsBytes(file), LocalModelMemory.architecture(file))
        }.value
        weights = measured.0
        architecture = measured.1
        loaded = true
    }

    static func tokens(_ value: Int) -> String {
        value >= 1_024 && value % 1_024 == 0 ? "\(value / 1_024)k" : value.formatted()
    }
}

/// Weights, context and working memory against what this Mac gives the GPU.
private struct MemoryBar: View {
    let estimate: LocalModelMemory.Estimate
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let budget = Double(max(estimate.budgetBytes, 1))
        let scale = max(budget, Double(estimate.totalBytes))
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    HStack(spacing: 1.5) {
                        Rectangle().fill(Color.primary.opacity(0.55)).frame(width: width * Double(estimate.weightsBytes) / scale)
                        Rectangle().fill(color).frame(width: width * Double(estimate.contextBytes) / scale)
                        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: width * Double(estimate.overheadBytes) / scale)
                    }
                    .clipShape(Capsule())
                    // What macOS lets the GPU use.
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5, height: 16)
                        .offset(x: width * budget / scale - 1)
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                legend(Color.primary.opacity(0.55), "Model " + gb(estimate.weightsBytes))
                legend(color, "Context " + gb(estimate.contextBytes))
                Spacer()
                Text(verdict).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            Text("\(gb(estimate.totalBytes)) of the \(gb(estimate.budgetBytes)) this Mac gives to models")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.2), value: estimate.contextBytes)
    }

    private var color: Color {
        switch estimate.verdict { case .fits: .green; case .tight: .orange; case .tooLarge: .red }
    }

    private var verdict: String {
        switch estimate.verdict { case .fits: "Fits"; case .tight: "Tight: may slow other apps"; case .tooLarge: "Too large for this Mac" }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func gb(_ bytes: Int64) -> String {
        (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}
