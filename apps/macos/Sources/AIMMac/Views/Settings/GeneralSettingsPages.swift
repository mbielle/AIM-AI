import AIMCore
import AIMAgentRuntime
import AIMMacPlatform
import AIMAgentKit
import AIMApplication
import AppKit
import SwiftUI

// MARK: General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showLicenses = false
    @State private var experimentalRemote = ContinuityRemoteAvailability.current().experimentalOptIn
    @State private var availabilityError: String?
    @State private var applicationPrivate = RuntimePrivacyPolicy.isGlobalEnabled
    @State private var changingPrivacy = false
    @State private var privacyError: String?
    @AppStorage(RuntimePrivacyPolicy.defaultsKey, store: AIMInstallationContext.sharedPreferences) private var privateAgentMode = false
    @AppStorage("AIMMaximumSubagentDepth", store: AIMInstallationContext.sharedPreferences) private var maximumSubagentDepth = 0
    private var prefs: AppPreferences { model.preferences }

    var body: some View {
        SettingsPage("General") {
            SettingsGroup("Permissions", footer: prefs.defaultApprovalPolicy == ApprovalPolicy.autoApprove.rawValue
                          ? "Auto lets the Agent edit the folder and run verified commands without asking. Commands that could reach the network or change the system still ask." : nil) {
                SettingsMenuRow("Default permissions", description: "How new Agent tasks ask before acting. You can change it per task in the composer.",
                                selection: binding(\.defaultApprovalPolicy),
                                options: ApprovalPolicy.allCases.map { ($0.rawValue, PolicyText.title($0)) })
                SettingsToggleRow("Private Agent mode", description: "Block cloud model requests and external Agent tools. Local models can continue. Account sign-in and other application services have separate network access.", isOn: $privateAgentMode)
                SettingsToggleRow("Private application mode", description: "Block new AIM external connections and stop Remote and managed external processes. Built-in local models remain available. Existing account data is preserved.",
                    isOn: Binding(get: { applicationPrivate }, set: { value in
                        Task {
                            changingPrivacy = true; defer { changingPrivacy = false }
                            do { try await model.setApplicationPrivateMode(value); applicationPrivate = RuntimePrivacyPolicy.isGlobalEnabled; privacyError = nil }
                            catch { applicationPrivate = RuntimePrivacyPolicy.isGlobalEnabled; privacyError = error.localizedDescription }
                        }
                    })).disabled(changingPrivacy)
                if let privacyError { SettingsNotice(privacyError, tone: .error) }
                if model.hasPendingApplicationPrivacyChange {
                    SettingsNotice(model.applicationPrivacyPendingDiagnostic ?? "A private-mode change is pending. New external connections remain blocked.", tone: .error)
                    SettingsRow("Pending private-mode change", description: "Cancelling this change explicitly allows AIM's external connections again.") {
                        Button("Cancel pending change") {
                            Task {
                                changingPrivacy = true; defer { changingPrivacy = false }
                                do { try await model.setApplicationPrivateMode(false); applicationPrivate = RuntimePrivacyPolicy.isGlobalEnabled; privacyError = nil }
                                catch { privacyError = error.localizedDescription }
                            }
                        }.buttonStyle(.settings).disabled(changingPrivacy)
                    }
                }
            }
            SettingsGroup("General") {
                SettingsRow("Default task folder", description: "Where Agent tasks started outside a project work by default.") {
                    Text(prefs.defaultTaskFolder.map(Self.abbreviated) ?? "Ask each time")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    if prefs.defaultTaskFolder != nil {
                        SettingsIconButton(systemImage: "xmark", help: "Ask each time") { model.updatePreferences { $0.defaultTaskFolder = nil } }
                    }
                    Button("Change") { chooseFolder() }.buttonStyle(.settings)
                }
                SettingsMenuRow("Open files in", description: "Where AIM opens files and folders.",
                                selection: binding(\.fileOpenApp), options: FileOpenDestination.available.map { ($0.id, $0.name) })
                SettingsRow("Language", description: "Language of menus and settings.") {
                    Text("English").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                SettingsToggleRow("Show in menu bar", description: "Keep AIM in the macOS menu bar when the main window is closed.",
                                  isOn: binding(\.showInMenuBar))
                SettingsMenuRow("Confirm before closing the window", description: "Warn before ⌘W or the close button hides AIM's window.",
                                selection: binding(\.closeConfirmation),
                                options: [(.never, "Never"), (.shortcutOnly, "Close shortcut only"), (.always, "Always")])
                SettingsToggleRow("Prevent sleep while running", description: "Keep the Mac awake while AIM answers or runs a task.",
                                  isOn: binding(\.preventSleepWhileRunning))
                SettingsToggleRow("Launch AIM AI at login", description: "Automations keep running when the window is closed.",
                                  isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                SettingsRow("Open source licenses", description: "Third-party notices for bundled components.") {
                    Button("View") { showLicenses = true }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Continuous missions") {
                SettingsToggleRow("Allow experimental continuous Remote", description: "Expose the new continuous mission commands to your paired iPhone for manual testing. This opt-in does not mark the native Mac/iPhone workflow as qualified.",
                    isOn: Binding(get: { experimentalRemote }, set: { value in
                        do { try ContinuityRemoteAvailability.setExperimentalOptIn(value); experimentalRemote = value; availabilityError = nil }
                        catch { availabilityError = error.localizedDescription }
                    }))
                if let availabilityError { SettingsNotice(availabilityError, tone: .error) }
                SettingsToggleRow("Run in the background", description: "Keep missions running after quitting AIM, in your open macOS session.",
                    isOn: Binding(get: { model.continuitySettings.permanent }, set: { value in Task { await model.setPermanentContinuity(value) } }))
                    .disabled(model.isChangingContinuityService)
                SettingsToggleRow("Keep the Mac awake", description: "Prevent idle sleep while the background service is enabled. Lid-close and forced sleep still apply.",
                    isOn: Binding(get: { model.continuitySettings.keepAwake }, set: { model.updateContinuityResources(keepAwake: $0) }))
                SettingsRow("Concurrent missions") {
                    Stepper("\(model.continuitySettings.maximumRoots)", value: Binding(get: { model.continuitySettings.maximumRoots },
                        set: { model.updateContinuityResources(maximumRoots: $0) }), in: 1...Int.max)
                }
                SettingsRow("Concurrent sub-agents") {
                    Stepper("\(model.continuitySettings.maximumChildren)", value: Binding(get: { model.continuitySettings.maximumChildren },
                        set: { model.updateContinuityResources(maximumChildren: $0) }), in: 1...Int.max)
                }
                SettingsToggleRow("Limit delegation depth", description: "Disable to allow recursive delegation without a depth ceiling. Permissions, budgets and concurrency still apply.",
                    isOn: Binding(get: { maximumSubagentDepth > 0 }, set: { maximumSubagentDepth = $0 ? 4 : 0 }))
                if maximumSubagentDepth > 0 {
                    SettingsRow("Delegation levels") { Stepper("\(maximumSubagentDepth)", value: $maximumSubagentDepth, in: 1...Int.max) }
                }
                if model.continuitySettings.permanent {
                    SettingsRow("Background service") {
                        Button("Stop service") { Task { await model.setPermanentContinuity(false) } }.buttonStyle(.settings)
                            .disabled(model.isChangingContinuityService)
                    }
                }
            }
            ExecutionEnvironmentSettingsView()
            VirtualMachineSettingsView()
            PeerWorkersSettingsView()
            SettingsGroup("Composer") {
                SettingsRow("Send shortcut", description: "Choose whether Return sends a message or inserts a new line.") {
                    AIMSegmentedControl(selection: binding(\.sendWithCommandReturn), options: [(false, "Return"), (true, "⌘ Return")], compact: true)
                }
                SettingsRow("Follow-up behavior",
                            description: "While a task runs, queue new messages for after it, or steer the running task. \(prefs.sendWithCommandReturn ? "⌥⌘↩" : "⌘↩") does the opposite for one message.") {
                    AIMSegmentedControl(selection: binding(\.followUp), options: [(.queue, "Queue"), (.steer, "Steer")], compact: true)
                }
                SettingsToggleRow("Show context window usage", description: "The ring in the composer with context, compaction and spending.",
                                  isOn: binding(\.showContextGauge))
                SettingsToggleRow("Smart punctuation", description: "Turn straight quotes, double hyphens and three dots into typographic ones as you type.",
                                  isOn: binding(\.smartPunctuation))
                SettingsRow("Quick chat shortcut", description: "A global shortcut that brings AIM forward on a new chat, from any app.") {
                    KeyComboRecorder(combo: Binding(get: { prefs.quickChatShortcut }, set: { value in model.updatePreferences { $0.quickChatShortcut = value } }))
                }
            }
        }
        .sheet(isPresented: $showLicenses) { OpenSourceLicensesView() }
    }

    private func binding<Value: Equatable>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { value in model.updatePreferences { $0[keyPath: path] = value } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        model.updatePreferences { $0.defaultTaskFolder = canonical }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum PolicyText {
    static func title(_ policy: ApprovalPolicy) -> String {
        switch policy {
        case .plan: "Plan · read only"
        case .alwaysAsk: "Always ask"
        case .smart: "Smart"
        case .autoApprove: "Auto (full access in the folder)"
        }
    }
}

/// Where files open: Finder, the file's default app, or a detected editor.
struct FileOpenDestination: Identifiable {
    let id: String
    let name: String

    static let editors: [(id: String, name: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.apple.dt.Xcode", "Xcode"), ("dev.zed.Zed", "Zed"), ("com.sublimetext.4", "Sublime Text"),
    ]

    static var available: [FileOpenDestination] {
        [.init(id: "default", name: "Default app"), .init(id: "finder", name: "Finder")]
            + editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }.map { .init(id: $0.id, name: $0.name) }
    }

    static func name(_ id: String) -> String {
        available.first { $0.id == id }?.name ?? "Default app"
    }

    /// Opens a file or folder following Settings › General.
    @MainActor static func open(_ url: URL, with id: String) {
        if !url.isFileURL, RuntimePrivacyPolicy.isApplicationNetworkBlocked { return }
        switch id {
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([url])
        case "default": NSWorkspace.shared.open(url)
        default:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { NSWorkspace.shared.open(url); return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Records one key combination (a modifier is required so typing never triggers it).
struct KeyComboRecorder: View {
    @Binding var combo: AppPreferences.KeyCombo?
    var allowsClear = true
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Type a shortcut…" : (combo?.display ?? "Off"))
                    .font(.system(size: 12.5, design: .rounded)).frame(minWidth: 90)
            }
            .buttonStyle(.settings)
            if allowsClear, combo != nil, !recording {
                SettingsIconButton(systemImage: "xmark", help: "Remove the shortcut") { combo = nil }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // Escape cancels
            let flags = event.modifierFlags
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
                  let key = KeyComboRecorder.keyName(event) else { return nil }
            combo = .init(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                          option: flags.contains(.option), control: flags.contains(.control))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func keyName(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "return"
        case 49: return "space"
        case 48: return "tab"
        case 51: return "delete"
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first, !character.isWhitespace else { return nil }
            return String(character)
        }
    }
}

/// Core dependencies and optional integrations; exact distributed artifacts require release review.
struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    static let components: [(name: String, license: String, url: String)] = [
        ("libdatachannel", "MPL 2.0", "https://github.com/paullouisageneau/libdatachannel"),
        ("Mbed TLS", "Apache 2.0", "https://github.com/Mbed-TLS/mbedtls"),
        ("libjuice", "MPL 2.0", "https://github.com/paullouisageneau/libjuice"),
        ("usrsctp", "BSD 3-Clause", "https://github.com/sctplab/usrsctp"),
        ("plog", "MIT", "https://github.com/SergiusTheBest/plog"),
        ("nlohmann/json", "MIT", "https://github.com/nlohmann/json"),
        ("GRDB.swift", "MIT", "https://github.com/groue/GRDB.swift"),
        ("Sparkle", "MIT", "https://github.com/sparkle-project/Sparkle"),
        ("supabase-swift", "MIT", "https://github.com/supabase/supabase-swift"),
        ("swift-markdown", "Apache 2.0", "https://github.com/swiftlang/swift-markdown"),
        ("SwiftMath", "MIT", "https://github.com/mgriebling/SwiftMath"),
        ("WhisperKit", "MIT", "https://github.com/argmaxinc/WhisperKit"),
        ("FluidAudio", "Apache 2.0", "https://github.com/FluidInference/FluidAudio"),
        ("swift-argument-parser", "Apache 2.0", "https://github.com/apple/swift-argument-parser"),
        ("llama.cpp", "MIT", "https://github.com/ggml-org/llama.cpp"),
        ("MLX Swift", "MIT", "https://github.com/ml-explore/mlx-swift"),
        ("Playwright MCP", "Apache 2.0", "https://github.com/microsoft/playwright-mcp"),
        ("Lobe Icons", "MIT", "https://github.com/lobehub/lobe-icons"),
        ("Lora (font)", "SIL Open Font License 1.1", "https://github.com/cyrealtype/Lora-Cyrillic"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Open source licenses").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.settingsPrimary).keyboardShortcut(.defaultAction)
            }
            Text("Core dependencies and optional integrations. Native transport notices are included in this app’s resources; optional engines depend on the installed build.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                SettingsCard {
                    ForEach(Self.components, id: \.name) { item in
                        SettingsRow(item.name, description: item.license) {
                            Link("Source", destination: URL(string: item.url)!).font(.system(size: 12.5))
                        }
                    }
                }
            }
        }
        .padding(24).frame(width: 560, height: 520)
    }
}

// MARK: Notifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    private var prefs: AppPreferences { model.preferences }

    var body: some View {
        SettingsPage("Notifications", subtitle: "macOS notifications from AIM on this Mac. Nothing is sent by e-mail or from a server.") {
            SettingsGroup("Tasks") {
                SettingsMenuRow("Answer and task completion", description: "When AIM finishes answering or a task ends.",
                                selection: binding(\.completionNotifications),
                                options: [(.never, "Never"), (.whenUnfocused, "Only when AIM is in the background"), (.always, "Always")])
                SettingsToggleRow("Approval needed", description: "When the Agent waits for your permission to act.", isOn: binding(\.notifyApprovals))
                SettingsToggleRow("Questions", description: "When the Agent needs an answer to continue.", isOn: binding(\.notifyQuestions))
            }
            SettingsGroup("Unattended work") {
                SettingsToggleRow("Automations", description: "Scheduled tasks that finish, fail or need you.", isOn: binding(\.notifyAutomations))
                SettingsToggleRow("Remote", description: "When your phone starts or continues a task on this Mac.", isOn: binding(\.notifyRemote))
                SettingsToggleRow("Usage limits", description: "When your spending limit or ChatGPT plan limit is reached.", isOn: binding(\.notifyLimits))
            }
            SettingsGroup("Sound") {
                SettingsMenuRow("Notification sound", description: "Played with AIM's notifications.", selection: binding(\.notificationSound),
                                options: [("default", "Default"), ("none", "None")] + AIMNotifier.systemSounds.map { ($0, $0) })
                SettingsRow("Test", description: "Shows a sample notification now.") {
                    Button("Send test") {
                        var forced = prefs
                        forced.completionNotifications = .always
                        AIMNotifier.post(.completion, title: "AIM AI", body: "Notifications are working.", preferences: forced)
                    }.buttonStyle(.settings)
                }
            }
        }
        .onChange(of: prefs.notificationSound) { _, sound in
            if sound != "default", sound != "none" { NSSound(named: NSSound.Name(sound))?.play() }
        }
    }

    private func binding<Value: Equatable>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { value in model.updatePreferences { $0[keyPath: path] = value } })
    }
}
