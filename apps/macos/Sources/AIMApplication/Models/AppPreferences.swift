import Foundation

/// The settings pages' preferences. Missing keys in older saved settings use current
/// defaults; explicitly stored choices are preserved.
public struct AppPreferences: Codable, Equatable, Sendable {
    // MARK: General
    /// Approval policy for new Agent conversations (an `ApprovalPolicy` raw value).
    public var defaultApprovalPolicy = "alwaysAsk"
    /// Folder used by Agent tasks started outside a project (nil: ask).
    public var defaultTaskFolder: String?
    /// Where AIM opens files and folders: "default", "finder", or an app bundle id.
    public var fileOpenApp = "default"
    public var showInMenuBar = true
    public var closeConfirmation = CloseConfirmation.never
    public var preventSleepWhileRunning = false

    // MARK: Composer
    public var sendWithCommandReturn = false
    public var followUp = FollowUp.steer
    public var showContextGauge = true
    public var smartPunctuation = false
    /// Global shortcut that brings AIM forward on a new chat (nil: off).
    public var quickChatShortcut: KeyCombo?

    // MARK: Notifications
    public var completionNotifications = CompletionNotifications.whenUnfocused
    public var notifyApprovals = true
    public var notifyQuestions = true
    public var notifyAutomations = true
    public var notifyRemote = true
    public var notifyLimits = true
    /// "default", "none", or a macOS sound name ("Glass", "Ping"…).
    public var notificationSound = "default"

    // MARK: Appearance
    public var accent = Accent.blue
    public var codeFont = CodeFont.system
    /// Nil follows the conversation text size.
    public var codeSize: Int?
    public var reduceMotion = Tristate.system
    /// New profiles and older preferences without this key use the macOS material.
    /// An explicitly stored false remains opaque; no migration overwrites that choice.
    public var translucentSidebar = true
    public var fullWidthConversations = false
    public var pointerCursors = false

    // MARK: Configuration
    /// Per mode ("chat", "agent", "code").
    public var modeDefaults: [String: ModeDefaults] = [:]

    // MARK: Personalization
    public var memoriesFromToolChats = true

    // MARK: Keyboard shortcuts (command id → combo; missing means the built-in default)
    public var shortcuts: [String: KeyCombo] = [:]

    public init() {}

    public enum CloseConfirmation: String, Codable, CaseIterable, Sendable { case never, shortcutOnly, always }
    public enum FollowUp: String, Codable, CaseIterable, Sendable { case queue, steer }
    public enum CompletionNotifications: String, Codable, CaseIterable, Sendable { case never, whenUnfocused, always }
    public enum Tristate: String, Codable, CaseIterable, Sendable { case system, on, off }
    public enum Accent: String, Codable, CaseIterable, Sendable { case blue, purple, pink, orange, green, graphite }
    public enum CodeFont: String, Codable, CaseIterable, Sendable { case system, menlo, monaco, courier }

    public struct ModeDefaults: Codable, Equatable, Sendable {
        public var provider: String?
        public var modelID: String?
        /// An `OpenAIReasoningEffort` raw value.
        public var effort: String?
        /// Efforts offered in the effort menu (nil: all).
        public var shownEfforts: [String]?
        public var approvalPolicy: String?
        public init() {}
    }

    /// A key and its modifiers, e.g. ⌘⇧N.
    public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
        public var key: String
        public var command = false, shift = false, option = false, control = false
        public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
            self.key = key.lowercased(); self.command = command; self.shift = shift; self.option = option; self.control = control
        }
        public var display: String {
            (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + Self.symbol(key)
        }
        static func symbol(_ key: String) -> String {
            switch key {
            case "return": "↩"
            case "space": "Space"
            case "escape": "⎋"
            case "delete": "⌫"
            case "tab": "⇥"
            default: key.uppercased()
            }
        }
    }

    // MARK: Decoding with defaults

    private enum CodingKeys: String, CodingKey {
        case defaultApprovalPolicy, defaultTaskFolder, fileOpenApp, showInMenuBar, closeConfirmation, preventSleepWhileRunning
        case sendWithCommandReturn, followUp, showContextGauge, smartPunctuation, quickChatShortcut
        case completionNotifications, notifyApprovals, notifyQuestions, notifyAutomations, notifyRemote, notifyLimits, notificationSound
        case accent, codeFont, codeSize, reduceMotion, translucentSidebar, fullWidthConversations, pointerCursors
        case modeDefaults, memoriesFromToolChats, shortcuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        defaultApprovalPolicy = v(.defaultApprovalPolicy, d.defaultApprovalPolicy)
        defaultTaskFolder = v(.defaultTaskFolder, d.defaultTaskFolder)
        fileOpenApp = v(.fileOpenApp, d.fileOpenApp)
        showInMenuBar = v(.showInMenuBar, d.showInMenuBar)
        closeConfirmation = v(.closeConfirmation, d.closeConfirmation)
        preventSleepWhileRunning = v(.preventSleepWhileRunning, d.preventSleepWhileRunning)
        sendWithCommandReturn = v(.sendWithCommandReturn, d.sendWithCommandReturn)
        followUp = v(.followUp, d.followUp)
        showContextGauge = v(.showContextGauge, d.showContextGauge)
        smartPunctuation = v(.smartPunctuation, d.smartPunctuation)
        quickChatShortcut = v(.quickChatShortcut, d.quickChatShortcut)
        completionNotifications = v(.completionNotifications, d.completionNotifications)
        notifyApprovals = v(.notifyApprovals, d.notifyApprovals)
        notifyQuestions = v(.notifyQuestions, d.notifyQuestions)
        notifyAutomations = v(.notifyAutomations, d.notifyAutomations)
        notifyRemote = v(.notifyRemote, d.notifyRemote)
        notifyLimits = v(.notifyLimits, d.notifyLimits)
        notificationSound = v(.notificationSound, d.notificationSound)
        accent = v(.accent, d.accent)
        codeFont = v(.codeFont, d.codeFont)
        codeSize = v(.codeSize, d.codeSize)
        reduceMotion = v(.reduceMotion, d.reduceMotion)
        translucentSidebar = v(.translucentSidebar, d.translucentSidebar)
        fullWidthConversations = v(.fullWidthConversations, d.fullWidthConversations)
        pointerCursors = v(.pointerCursors, d.pointerCursors)
        modeDefaults = v(.modeDefaults, d.modeDefaults)
        memoriesFromToolChats = v(.memoriesFromToolChats, d.memoriesFromToolChats)
        shortcuts = v(.shortcuts, d.shortcuts)
    }
}

/// What a local notification is about (each kind can be turned off).
public enum NotificationKind: String, CaseIterable, Sendable {
    case completion, approval, question, automation, remote, limit
}

extension AppPreferences {
    /// Whether to show a notification now. A finished answer follows its own rule;
    /// approvals, questions and limits show while AIM is not the active app (or with "Always").
    public func allowsNotification(_ kind: NotificationKind, appActive: Bool) -> Bool {
        let enabled: Bool
        switch kind {
        case .completion:
            switch completionNotifications {
            case .never: return false
            case .whenUnfocused: return !appActive
            case .always: return true
            }
        // Unattended work (automations, the phone) is reported even while AIM is in front.
        case .automation: return notifyAutomations
        case .remote: return notifyRemote
        case .approval: enabled = notifyApprovals
        case .question: enabled = notifyQuestions
        case .limit: enabled = notifyLimits
        }
        return enabled && (!appActive || completionNotifications == .always)
    }
}
