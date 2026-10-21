import AIMApplication
import AIMMacPlatform
import SwiftUI

/// The live microphone level, in place of the text field while dictating: dots at rest,
/// bars when speaking, scrolling from right to left (as in ChatGPT).
struct DictationWaveform: View {
    let levels: [Float]
    var transcribing = false
    var starting = false
    /// The on-device model is still being optimized for this Mac (first use only).
    var preparing = false

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 6
            let count = max(1, Int(size.width / step))
            let values = Array(levels.suffix(count))
            // Newest on the right; older samples scroll left, silence before them shows as dots.
            let missing = count - values.count
            let color = Color.primary.opacity(transcribing ? 0.28 : 0.55)
            for index in 0..<count {
                let x = CGFloat(index) * step + step / 2
                let level: CGFloat = index >= missing ? CGFloat(values[index - missing]) : 0
                if level < 0.04 {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.25, y: size.height / 2 - 1.25, width: 2.5, height: 2.5)), with: .color(color.opacity(0.7)))
                } else {
                    let height = 4 + level * (size.height - 6)
                    context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: (size.height - height) / 2, width: 3, height: height), cornerRadius: 1.5),
                                 with: .color(color))
                }
            }
        }
        .overlay(alignment: .leading) {
            if transcribing || starting {
                Text(transcribing ? (preparing ? "Preparing the model for this Mac (first use, about a minute)…" : "Transcribing…")
                                  : "Starting the microphone…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.background.opacity(0.9), in: Capsule())
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityElement()
        .accessibilityLabel(transcribing ? "Transcribing" : "Recording")
    }
}

/// Shown above the bar when a recording could not be transcribed: nothing is lost.
struct DictationRetryBar: View {
    let engine: DictationEngine
    /// Why the last attempt failed (shown under the title).
    var reason: String?
    let retry: () -> Void
    /// Transcribe with an on-device model instead (opens the downloads when none is installed).
    let local: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your recording is saved").font(.system(size: 13, weight: .medium))
                if let reason { Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if !engine.isLocalModel {
                Button("Transcribe on this Mac", action: local).buttonStyle(.settings)
            }
            Button("Retry", action: retry).buttonStyle(.settingsPrimary)
            Button(action: discard) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.aimHover(radius: 7)).aimTooltip("Discard the recording").accessibilityLabel("Discard the recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Dictation settings": Apple, OpenAI and downloadable on-device models.
struct DictationSettingsMenu: View {
    @Binding var selected: DictationEngine
    let hasOpenAIKey: Bool
    @Environment(\.aimMenuDismiss) private var dismiss
    @State private var language = DictationLanguage.selected
    private var models: LocalDictationModels { .shared }

    private func languageName(_ id: String) -> String {
        if id == "auto" {
            let used = DictationLanguage.detected.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                ?? Locale.current.localizedString(forIdentifier: DictationLanguage.locale("auto").identifier) ?? "Mac language"
            return "Automatic (\(used))"
        }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static func title(_ engine: DictationEngine) -> String {
        switch engine {
        case .apple: "Dictate on this Mac"
        case .openAI: "GPT Transcribe"
        default: LocalDictationModels.catalog.first { $0.engine == engine }?.title ?? "Dictation"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                AIMMenuSection("Dictation")
                Spacer()
                Menu {
                    Button(languageName("auto")) { setLanguage("auto") }
                    Divider()
                    ForEach(DictationLanguage.options(), id: \.id) { option in
                        Button(option.name) { setLanguage(option.id) }
                    }
                } label: {
                    Label(languageName(language), systemImage: "globe").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.trailing, 9)
                .aimTooltip("Spoken language")
            }
            row(.apple, title: "Dictate on this Mac", subtitle: "Apple · private, nothing leaves your Mac") {
                Image(systemName: "apple.logo").font(.system(size: 15)).foregroundStyle(.primary)
            }
            row(.openAI, title: "GPT Transcribe", subtitle: hasOpenAIKey ? "OpenAI · detects the language · uses your API key"
                : "Needs an OpenAI API key (a ChatGPT sign-in cannot transcribe) · Settings → Providers",
                enabled: hasOpenAIKey) {
                ModelCreatorLogo(creator: "openai", size: 18)
            }
            AIMMenuDivider()
            AIMMenuSection("On this Mac · download once")
            ForEach(LocalDictationModels.catalog) { item in localRow(item) }
            Text("Models come from Hugging Face (Whisper by OpenAI via WhisperKit, Parakeet by NVIDIA via FluidAudio) and run offline.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 400)
        .onAppear { models.refresh() }
    }

    private func setLanguage(_ id: String) {
        language = id
        DictationLanguage.selected = id
    }

    private func choose(_ engine: DictationEngine) {
        selected = engine
        DictationEngine.selected = engine
        if engine.isLocalModel { models.prepare(engine) }
        dismiss()
    }

    private func row<Logo: View>(_ engine: DictationEngine, title: String, subtitle: String, enabled: Bool = true,
                                 @ViewBuilder logo: () -> Logo) -> some View {
        Button { choose(engine) } label: {
            HStack(spacing: 10) {
                logo().frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if selected == engine { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.aimHover(radius: 7))
        .disabled(!enabled)
    }

    private func localRow(_ item: LocalDictationModel) -> some View {
        let state = models.state(item.engine)
        return HStack(spacing: 10) {
            ModelCreatorLogo(creator: item.engine == .parakeet ? "nvidia" : "openai", size: 18).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13))
                Text(subtitle(item, state)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            switch state {
            case .ready:
                if selected == item.engine { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                Button { models.delete(item.engine); if selected == item.engine { selected = .apple; DictationEngine.selected = .apple } } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.aimHover(radius: 6)).foregroundStyle(.secondary).aimTooltip("Delete from this Mac")
            case .downloading(let fraction):
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                Button { models.cancelDownload(item.engine) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.aimHover(radius: 6)).aimTooltip("Cancel download")
            case .absent, .failed:
                Button { models.download(item.engine) } label: {
                    Label("Download · \(item.size.replacingOccurrences(of: "≈ ", with: ""))", systemImage: "arrow.down.circle")
                        .font(.system(size: 12)).fixedSize()
                }
                .buttonStyle(.aimHover(radius: 7))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if state == .ready { choose(item.engine) } }
        .background(selected == item.engine ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private func subtitle(_ item: LocalDictationModel, _ state: LocalDictationModels.State) -> String {
        switch state {
        case .ready: models.preparing.contains(item.id) ? "Optimizing for this Mac… (first time only)" : "\(item.detail) · on this Mac"
        case .downloading(let fraction): "Downloading… \(Int(fraction * 100))% of \(item.size.replacingOccurrences(of: "≈ ", with: ""))"
        case .failed(let message): message
        case .absent: item.detail
        }
    }
}
