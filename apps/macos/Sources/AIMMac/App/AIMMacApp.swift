import AIMCore
import AIMApplication
import AIMAgentRuntime
import AIMMacPlatform
import SwiftUI

struct AIMMacApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @State private var model: AppModel

    init() {
        #if DEBUG
        let galleryFolder = SettingsGallery.folder(ProcessInfo.processInfo.arguments)
        let invocation = QualificationCommand.parse(ProcessInfo.processInfo.arguments)
        // Local qualification uses the real provider store, but does not need
        // account authentication or a second Remote connection. External engines run only
        // in the durable, signed-in path, so their live suite uses the test bundle as a person does.
        // The background-control ladder records into the real store, which the agents read.
        let isQualificationRun = invocation != nil && !["external-live", "capabilities", "cua-ladder"].contains(invocation?.suite ?? "")
        let model: AppModel
        if let qa = AIMQAContext.current {
            let store = try! qa.store("host")
            model = AppModel(database: try! AIMDatabase(inMemory: true),
                turnRunner: DeterministicQualificationProvider(marker: qa.marker),
                account: MacAccountController(infoDictionary: [:], secureStoreOverride: store), providerStore: store)
        } else {
            model = isQualificationRun
                ? AppModel(database: try! AIMDatabase(inMemory: true), account: MacAccountController(service: nil))
                : (galleryFolder == nil ? AppModel() : AppModel(database: try! AIMDatabase(inMemory: true)))
        }
        #else
        let model = AppModel()
        #endif
        _model = State(initialValue: model)
        lifecycle.prepare = { await model.prepareForTermination() }
        AIMTypography.registerBundledFonts()
        #if DEBUG
        // Explicit local qualification only; absent from release builds. The
        // report contains fixture facts, never desktop pixels or user AX text.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--agent-fixture-report"), index + 1 < arguments.count {
            let destination = URL(fileURLWithPath: arguments[index + 1])
            Task {
                let report = await DesktopFixtureQualification.report()
                try? report.write(to: destination, options: [.atomic])
            }
        }
        if let galleryFolder {
            Task { @MainActor in SettingsGallery.run(into: galleryFolder, model: model, dark: arguments.contains("--dark")) }
        }
        if let invocation = QualificationCommand.parse(arguments) {
            Task { @MainActor in QualificationCommand.start(invocation, model: model) }
        }
        #endif
    }

    var body: some Scene {
        // One main window: menu commands bring it forward instead of opening another one
        // (which macOS showed as a second "AIM AI" tab with a "+" button).
        Window(AIMInstallationContext.isQualification ? "AIM Continuity Test" : "AIM AI", id: "main") {
            mainContent
                .environment(model)
                .environment(\.openURL, privacyOpenURLAction)
                .onAppear { AppearanceMode.apply() }
                .onOpenURL { url in Task { await model.account.handleCallback(url) } }
                .background(WindowReopenRegistration(lifecycle: lifecycle))
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    #if DEBUG
                    if AIMQAContext.current != nil { return }
                    #endif
                    await model.start()
                }
                .background(AppPreferenceEffects().environment(model))
                .alert("AIM AI", isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } }
                )) {
                    if [ChatServiceError.planLimitReached.errorDescription, ChatServiceError.planUsageUnavailable.errorDescription].contains(model.alertMessage) {
                        Button("Manage usage") { if !RuntimePrivacyPolicy.isApplicationNetworkBlocked { NSWorkspace.shared.open(ChatGPTPlanAuth.manageUsageURL) }; model.alertMessage = nil }
                            .disabled(RuntimePrivacyPolicy.isApplicationNetworkBlocked)
                    }
                    Button("OK") { model.alertMessage = nil }
                } message: {
                    Text(model.alertMessage ?? "")
                }
        }
        .defaultSize(width: 1_260, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { AIMAppCommands(model: model) }

        Window("AIM Computer Use", id: "computer-use") {
            Group {
                if model.hasAccess { ComputerUseSetupView() }
                else { AuthBackdrop { SignInView() } }
            }
            .environment(model)
            .environment(\.openURL, privacyOpenURLAction)
        }
        .defaultSize(width: 760, height: 620)
        .windowResizability(.contentSize)

        MenuBarExtra("AIM AI", systemImage: "sparkles", isInserted: Binding(
            get: { model.preferences.showInMenuBar }, set: { value in model.updatePreferences { $0.showInMenuBar = value } })) {
            MenuBarView()
                .environment(model)
                .environment(\.openURL, privacyOpenURLAction)
        }

    }
    @ViewBuilder private var mainContent: some View {
        #if DEBUG
        if let qa = AIMQAContext.current { AIMQAHostView(context: qa, model: model) }
        else { AccessGateView() }
        #else
        AccessGateView()
        #endif
    }

    private var privacyOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            if RuntimePrivacyPolicy.isApplicationNetworkBlocked, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .discarded }
            return .systemAction
        }
    }
}

/// Keep the scene-opening action after the last window closes. Reopening must
/// not replace AppModel, clear drafts, or interrupt background work.
private struct WindowReopenRegistration: View {
    let lifecycle: AppLifecycleDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            let action = openWindow
            lifecycle.reopenMainWindow = { action(id: "main") }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct AIMAppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Nothing below works for a signed-out Mac: the window shows only sign-in.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.settingsSection = .general; openWindow(id: "main") }
                .keyboardShortcut(model.preferences.combo(.settings).keyboardShortcut).disabled(!model.hasAccess)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { model.settingsSection = nil; Task { await model.newGeneralConversation() } }
                .keyboardShortcut(model.preferences.combo(.newChat).keyboardShortcut).disabled(!model.hasAccess)
        }
        CommandMenu("Space") {
            Button("Chat") { model.settingsSection = nil; model.selectMode(.chat) }.keyboardShortcut(model.preferences.combo(.chatSpace).keyboardShortcut)
                .disabled(!model.hasAccess)
            Button("Code") { model.settingsSection = nil; model.selectMode(.code) }.keyboardShortcut(model.preferences.combo(.codeSpace).keyboardShortcut)
                .disabled(!model.hasAccess)
        }
        CommandMenu("Compose") {
            Button("Choose Model…") { model.showModelPicker = true; openWindow(id: "main") }
                .keyboardShortcut(model.preferences.combo(.chooseModel).keyboardShortcut).disabled(!model.hasAccess)
            Button("Attach File or Image…") { model.attachmentPickerRequestID = UUID(); openWindow(id: "main") }
                .keyboardShortcut(model.preferences.combo(.attach).keyboardShortcut)
                .disabled(!model.hasAccess || !model.canImportAttachments)
            Button("Start or Stop Dictation") { model.dictationRequestID = UUID(); openWindow(id: "main") }
                .keyboardShortcut(model.preferences.combo(.dictate).keyboardShortcut)
                .disabled(!model.hasAccess)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdates() }
        }
        CommandGroup(after: .windowList) {
            Button("Show AIM AI") { openWindow(id: "main") }
        }
    }
}

/// Applies preferences that live outside SwiftUI views: the global quick-chat shortcut
/// and the close confirmation of the main window.
private struct AppPreferenceEffects: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { apply() }
            .onChange(of: model.preferences) { _, _ in apply() }
    }

    private func apply() {
        let open = openWindow
        GlobalHotKey.shared.register(model.preferences.quickChatShortcut) { [model] in
            NSApp.activate(ignoringOtherApps: true)
            open(id: "main")
            model.settingsSection = nil
            Task { await model.newGeneralConversation() }
        }
        WindowCloseGuard.shared.rule = model.preferences.closeConfirmation
    }
}

/// Asks before the main window closes (⌘W only, or also the close button).
@MainActor
final class WindowCloseGuard: NSObject {
    static let shared = WindowCloseGuard()
    var rule = AppPreferences.CloseConfirmation.never { didSet { install() } }
    private var monitor: Any?
    private weak var hooked: NSWindow?

    private func install() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.rule != .never, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "w", let window = NSApp.keyWindow, Self.isMain(window) else { return event }
                return self.confirm() ? event : nil
            }
        }
        guard let window = NSApp.windows.first(where: Self.isMain), let button = window.standardWindowButton(.closeButton) else { return }
        if rule == .always {
            button.target = self
            button.action = #selector(closeClicked(_:))
            hooked = window
        } else if hooked === window {
            button.target = window
            button.action = #selector(NSWindow.performClose(_:))
            hooked = nil
        }
    }

    @objc private func closeClicked(_ sender: Any?) {
        guard let window = hooked, confirm() else { return }
        window.close()
    }

    private func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close AIM's window?"
        alert.informativeText = "AIM keeps running in the menu bar; tasks and automations continue."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("main") == true || window.title == "AIM AI"
    }
}
