import AIMApplication
import AppKit
import SwiftUI

/// Appearance preferences read by views that have no app model (button styles, the theme),
/// mirrored to UserDefaults whenever they change.
enum AppearancePreferences {
    static let accentKey = "aim.appearance.accent"
    static let codeFontKey = "aim.appearance.codeFont"
    static let codeSizeKey = "aim.appearance.codeSize"
    static let pointerKey = "aim.appearance.pointerCursors"

    static func mirror(_ preferences: AppPreferences) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.accent.rawValue, forKey: accentKey)
        defaults.set(preferences.codeFont.rawValue, forKey: codeFontKey)
        defaults.set(preferences.codeSize ?? 0, forKey: codeSizeKey)
        defaults.set(preferences.pointerCursors, forKey: pointerKey)
    }

    static var accent: AppPreferences.Accent {
        UserDefaults.standard.string(forKey: accentKey).flatMap(AppPreferences.Accent.init(rawValue:)) ?? .blue
    }

    static func color(_ accent: AppPreferences.Accent) -> Color {
        switch accent {
        case .blue: Color(red: 0.24, green: 0.50, blue: 0.97)
        case .purple: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .pink: Color(red: 0.93, green: 0.30, blue: 0.56)
        case .orange: Color(red: 0.96, green: 0.52, blue: 0.16)
        case .green: Color(red: 0.20, green: 0.69, blue: 0.40)
        case .graphite: Color(red: 0.42, green: 0.44, blue: 0.48)
        }
    }

    /// Code blocks: the chosen monospaced font, at the chosen size or the text-derived one.
    static func codeFont(defaultSize: Int) -> Font {
        let saved = UserDefaults.standard.integer(forKey: codeSizeKey)
        let size = CGFloat(saved > 0 ? saved : defaultSize)
        switch UserDefaults.standard.string(forKey: codeFontKey).flatMap(AppPreferences.CodeFont.init(rawValue:)) ?? .system {
        case .system: return .system(size: size, design: .monospaced)
        case .menlo: return .custom("Menlo", size: size)
        case .monaco: return .custom("Monaco", size: size)
        case .courier: return .custom("Courier New", size: size)
        }
    }

    static var pointerCursors: Bool { UserDefaults.standard.bool(forKey: pointerKey) }
}

/// The sidebar's backdrop: AIM's flat gray, or macOS's translucent sidebar material.
struct SidebarBackdrop: View {
    let translucent: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if translucent { VisualEffectBackdrop() } else { AIMTheme.sidebar(scheme) }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Settings › Appearance › Reduce motion (System follows macOS's accessibility setting).
    func aimReduceMotion(_ setting: AppPreferences.Tristate) -> some View {
        modifier(ReduceMotionModifier(setting: setting))
    }
}

private struct ReduceMotionModifier: ViewModifier {
    let setting: AppPreferences.Tristate
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    func body(content: Content) -> some View {
        let reduce = setting == .on || (setting == .system && systemReduce)
        content.transaction { transaction in
            if reduce { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
}
