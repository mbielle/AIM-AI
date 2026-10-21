import AIMCore
import AIMApplication
import SwiftUI

/// Reasoning effort for the selected model: only the levels this model accepts, as named
/// pills. The header (model · effort ›) opens the model picker.
struct OpenAIReasoningSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.aimMenuDismiss) private var dismissMenu
    let modelID: String
    @State private var saving = false
    @State private var error: String?
    @State private var headerHovered = false
    @Namespace private var thumb

    private var info: ChatModel? { model.modelInfo(provider: model.selectedProvider, modelID: modelID) }
    private var levels: [OpenAIReasoningEffort] {
        let all = OpenAIReasoningEffort.levels(provider: model.selectedProvider, modelID: modelID, info: info?.reasoning)
        // Settings › Configuration can hide efforts from this menu (the current one stays visible).
        guard let shown = model.preferences.modeDefaults[model.mode.rawValue]?.shownEfforts, model.selectedProvider != .local else { return all }
        let filtered = all.filter { shown.contains($0.rawValue) || $0 == model.effectiveReasoningEffort }
        return filtered.isEmpty ? all : filtered
    }
    /// Local models answer without thinking unless asked.
    private var defaultLevel: OpenAIReasoningEffort? {
        model.selectedProvider == .local ? OpenAIReasoningEffort.none : OpenAIReasoningEffort.defaultLevel(info: info?.reasoning)
    }
    /// The level in effect: the saved one, else the model's default.
    private var current: OpenAIReasoningEffort? { model.reasoningEffort(provider: model.selectedProvider, modelID: modelID) ?? defaultLevel }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                dismissMenu()
                model.showModelPicker = true
            } label: {
                HStack(spacing: 8) {
                    let presentation = model.selectedModelPresentation
                    ModelCreatorLogo(creator: presentation.creator, size: 18)
                    Text(presentation.name)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(current.map(label) ?? "Default").font(.system(size: 14)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Capsule().fill(headerHovered ? AIMTheme.hover(scheme) : .clear))
                .overlay(Capsule().strokeBorder(headerHovered ? AIMTheme.cardBorder(scheme) : .clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { headerHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: headerHovered)
            .help("Choose another model")

            HStack(spacing: 2) {
                ForEach(levels, id: \.self) { level in
                    let selected = level == current
                    Button { select(level) } label: {
                        Text(label(level))
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background {
                                if selected {
                                    Capsule().fill(scheme == .dark ? Color.white.opacity(0.16) : .white)
                                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                        .matchedGeometryEffect(id: "thumb", in: thumb)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(level.title + (level == defaultLevel ? ", model default" : ""))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
            .animation(.snappy(duration: 0.22), value: current)
            .disabled(saving)

            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
            if model.selectedProvider == .local, model.builtInModelFile(modelID) != nil {
                Divider()
                Button {
                    dismissMenu()
                    model.openLocalModelSettings(name: modelID)
                } label: {
                    Label("Model settings", systemImage: "slider.horizontal.3").lineLimit(1)
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.aimHover(radius: 8))
            }
        }
        .padding(4)
    }

    /// Local models only switch thinking on or off.
    private func label(_ level: OpenAIReasoningEffort) -> String {
        level.label(provider: model.selectedProvider)
    }

    private func select(_ level: OpenAIReasoningEffort) {
        saving = true; error = nil
        // Choosing the model's own default stores "default" so future catalog changes follow it.
        let stored: OpenAIReasoningEffort? = level == defaultLevel ? nil : level
        Task {
            do { try await model.setOpenAIReasoningEffort(stored, modelID: modelID) }
            catch { self.error = "Could not save this setting." }
            saving = false
        }
    }
}
