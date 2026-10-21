import AIMCore
import AIMAgentKit
import AIMApplication
import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: Configuration

struct ConfigurationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: AIMMode = .chat
    @State private var researchKeyInput = ""
    @State private var researchKeyNotice: String?

    private var defaults: AppPreferences.ModeDefaults { model.preferences.modeDefaults[mode.rawValue] ?? .init() }

    var body: some View {
        SettingsPage("Configuration", subtitle: "Choose how AIM starts its work in each space. You can still change everything per conversation.") {
            AIMSegmentedControl(selection: $mode, options: [(.chat, "Chat"), (.agent, "Agent"), (.code, "Code")], compact: true)
                .padding(.bottom, 4)
            SettingsGroup {
                SettingsRow("Default model", description: defaultModelText) {
                    if defaults.modelID != nil {
                        SettingsIconButton(systemImage: "xmark", help: "Use the last chosen model") { update { $0.provider = nil; $0.modelID = nil } }
                    }
                    Button("Use current model") {
                        update { $0.provider = model.selectedProvider.rawValue; $0.modelID = model.selectedModelID }
                    }
                    .buttonStyle(.settings).disabled(model.selectedModelID.isEmpty)
                }
                SettingsMenuRow("Default reasoning effort", description: "Used when a model has no effort of its own chosen; ignored by models that do not offer it.",
                                selection: Binding(get: { defaults.effort ?? "" }, set: { value in update { $0.effort = value.isEmpty ? nil : value } }),
                                options: [("", "Model default")] + OpenAIReasoningEffort.allCases.map { ($0.rawValue, $0.title) })
                SettingsRow("Efforts shown in the effort menu", description: shownDescription) {
                    Menu {
                        ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                            Toggle(effort.title, isOn: Binding(
                                get: { defaults.shownEfforts?.contains(effort.rawValue) ?? true },
                                set: { on in
                                    update { value in
                                        var shown = value.shownEfforts ?? OpenAIReasoningEffort.allCases.map(\.rawValue)
                                        if on { shown.append(effort.rawValue) } else { shown.removeAll { $0 == effort.rawValue } }
                                        let unique = OpenAIReasoningEffort.allCases.map(\.rawValue).filter(shown.contains)
                                        value.shownEfforts = unique.count == OpenAIReasoningEffort.allCases.count ? nil : unique
                                    }
                                }))
                        }
                    } label: { Text(shownLabel).font(.system(size: 12.5)) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if mode != .chat {
                    SettingsMenuRow("Permissions", description: "How new \(mode == .agent ? "Agent" : "Code") tasks ask before acting.",
                                    selection: Binding(get: { defaults.approvalPolicy ?? "" }, set: { value in update { $0.approvalPolicy = value.isEmpty ? nil : value } }),
                                    options: [("", "Same as General (\(PolicyText.title(ApprovalPolicy(rawValue: model.preferences.defaultApprovalPolicy) ?? .alwaysAsk)))")]
                                        + ApprovalPolicy.allCases.map { ($0.rawValue, PolicyText.title($0)) })
                }
            }
            if mode == .chat {
                SettingsGroup("Web search") {
                    SettingsRow("Search automatically", description: model.researchMode.isOrchestrated ? "Model usage and search API charges are recorded separately. An absent search receipt remains unknown." : NativeWebSearchRules.costDescription(provider: model.selectedProvider, modelID: model.selectedModelID)) {
                        Toggle("Search automatically", isOn: Binding(get: { model.automaticWebSearch }, set: { model.setAutomaticWebSearch($0) }))
                            .labelsHidden()
                    }
                    SettingsRow("Research mode", description: "Provider-hosted search stays the default. AIM research uses a separate profile search key and never falls back to another paid service.") {
                        Picker("Research mode", selection: Binding(get: { model.researchMode }, set: { model.setResearchMode($0); researchKeyInput = ""; researchKeyNotice = nil })) {
                            ForEach(AIMResearchMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden().frame(maxWidth: 220)
                    }
                    if model.researchMode.isOrchestrated {
                        SettingsRow("Search API key", description: "Stored only for this profile. Saving a key sends no request.") {
                            SecureField("Search API key", text: $researchKeyInput).frame(maxWidth: 220)
                        }
                        HStack {
                            Button("Save search key") {
                                do { try model.saveResearchAPIKey(researchKeyInput, mode: model.researchMode); researchKeyInput = ""; researchKeyNotice = "Search key saved for this profile." }
                                catch { researchKeyNotice = error.localizedDescription }
                            }.disabled(researchKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove search key") {
                                do { try model.removeResearchAPIKey(mode: model.researchMode); researchKeyInput = ""; researchKeyNotice = "Search key removed from this profile." }
                                catch { researchKeyNotice = error.localizedDescription }
                            }
                        }
                        if let researchKeyNotice { Text(researchKeyNotice).font(.caption).foregroundStyle(.secondary) }
                        Text("AIM research uses model tools and bounded public-page reads. Current search API charges apply. A verified-only budget can require an explicit spending exception.").font(.caption).foregroundStyle(.secondary)
                    }
                    SettingsRow("Response length", description: "Automatic uses the model’s capacity. A limit chosen in a model’s settings remains explicit.") { Text("Automatic").foregroundStyle(.secondary) }
                }
            }
            FallbackModelsView()
        }
    }

    private var defaultModelText: String {
        guard let id = defaults.modelID, let provider = defaults.provider.flatMap(ChatProvider.init(rawValue:)) else {
            return "New conversations start with the last model you chose."
        }
        let name = model.presentation(provider: provider, modelID: id).name
        return "\(name) · \(ModelDetailView.routeTitle(provider))" + (model.connectedProviders.contains(provider) ? "" : " · provider not connected")
    }

    private var shownLabel: String {
        guard let shown = defaults.shownEfforts else { return "All" }
        return "\(shown.count) selected"
    }

    private var shownDescription: String {
        "Hide efforts you never use. The menu still shows only what the selected model supports."
    }

    private func update(_ change: (inout AppPreferences.ModeDefaults) -> Void) {
        let key = mode.rawValue
        model.updatePreferences { prefs in
            var value = prefs.modeDefaults[key] ?? .init()
            change(&value)
            prefs.modeDefaults[key] = value
        }
    }
}

// MARK: Keyboard shortcuts

/// App commands whose shortcut can be changed.
enum ShortcutCommand: String, CaseIterable, Identifiable {
    case newChat, settings, chooseModel, attach, chatSpace, codeSpace, dictate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newChat: "New conversation"
        case .settings: "Settings"
        case .chooseModel: "Choose model"
        case .attach: "Attach a file or image"
        case .chatSpace: "Go to Chat"
        case .codeSpace: "Go to Code"
        case .dictate: "Start or stop dictation"
        }
    }

    var defaultCombo: AppPreferences.KeyCombo {
        switch self {
        case .newChat: .init(key: "n", command: true)
        case .settings: .init(key: ",", command: true)
        case .chooseModel: .init(key: "m", command: true, shift: true)
        case .attach: .init(key: "a", command: true, shift: true)
        case .chatSpace: .init(key: "1", command: true)
        case .codeSpace: .init(key: "2", command: true)
        case .dictate: .init(key: "d", command: true, option: true)
        }
    }
}

extension AppPreferences {
    func combo(_ command: ShortcutCommand) -> KeyCombo { shortcuts[command.rawValue] ?? command.defaultCombo }
}

extension AppPreferences.KeyCombo {
    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent
        switch key {
        case "return": equivalent = .return
        case "space": equivalent = .space
        case "tab": equivalent = .tab
        case "delete": equivalent = .delete
        default: equivalent = KeyEquivalent(key.first ?? "?")
        }
        var modifiers: SwiftUI.EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

struct ShortcutSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Fixed shortcuts shown for reference.
    private let builtIn: [(String, String)] = [
        ("Send the message", "↩ (or ⌘↩, Settings › General)"), ("New line in the message", "⇧↩"),
        ("Opposite follow-up for one message", "⌘↩ while a task runs"), ("Close the window", "⌘W"), ("Quit", "⌘Q"),
    ]

    var body: some View {
        SettingsPage("Keyboard shortcuts", subtitle: "Click a shortcut, then type the new one (with ⌘, ⌥ or ⌃). Escape cancels.") {
            SettingsGroup("Commands") {
                ForEach(ShortcutCommand.allCases) { command in
                    let combo = model.preferences.combo(command)
                    let conflict = ShortcutCommand.allCases.first { $0 != command && model.preferences.combo($0) == combo }
                    SettingsRow(command.title, description: conflict.map { "Also used by “\($0.title)”." }) {
                        KeyComboRecorder(combo: Binding(get: { combo }, set: { value in
                            model.updatePreferences { $0.shortcuts[command.rawValue] = value ?? command.defaultCombo }
                        }), allowsClear: false)
                        if combo != command.defaultCombo {
                            SettingsIconButton(systemImage: "arrow.uturn.backward", help: "Back to \(command.defaultCombo.display)") {
                                model.updatePreferences { $0.shortcuts[command.rawValue] = nil }
                            }
                        }
                    }
                }
            }
            SettingsGroup("Anywhere on the Mac") {
                SettingsRow("Quick chat", description: "Brings AIM forward on a new chat from any app.") {
                    KeyComboRecorder(combo: Binding(get: { model.preferences.quickChatShortcut },
                                                    set: { value in model.updatePreferences { $0.quickChatShortcut = value } }))
                }
            }
            SettingsGroup("Fixed") {
                ForEach(builtIn, id: \.0) { item in
                    SettingsRow(item.0) { Text(item.1).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: Global quick-chat hotkey

/// One system-wide shortcut (Carbon hot key: works while another app is active).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private var current: AppPreferences.KeyCombo?

    func register(_ combo: AppPreferences.KeyCombo?, action: @escaping () -> Void) {
        guard combo != current else { self.action = action; return }
        unregister()
        current = combo
        self.action = action
        guard let combo, let code = Self.keyCode(combo.key) else { return }
        var modifiers: UInt32 = 0
        if combo.command { modifiers |= UInt32(cmdKey) }
        if combo.shift { modifiers |= UInt32(shiftKey) }
        if combo.option { modifiers |= UInt32(optionKey) }
        if combo.control { modifiers |= UInt32(controlKey) }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: OSType(0x41494D51), id: 1), GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; current = nil
    }

    static func keyCode(_ key: String) -> UInt32? {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "space": kVK_Space, "return": kVK_Return, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        ]
        return table[key].map(UInt32.init)
    }
}
