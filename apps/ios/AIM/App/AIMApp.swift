import SwiftUI

enum AIMAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AIMInterfaceLanguage: String, CaseIterable, Identifiable {
    case french = "fr"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
}

enum AIMTypographyPreference: String, CaseIterable, Identifiable {
    case lora
    case system

    var id: String { rawValue }
}

@main
struct AIMApp: App {
    @UIApplicationDelegateAdaptor(AIMApplicationDelegate.self) private var appDelegate
    // Start observing before the first editor brings up the keyboard.
    private let keyboardHost = AIMExperimentalKeyboardHost.shared
    @State private var environment = AppEnvironment()
    @AppStorage("aim.appearance") private var appearance = AIMAppearancePreference.system.rawValue
    @AppStorage("aim.interface-language") private var interfaceLanguage = defaultInterfaceLanguage
    @AppStorage("aim.typography") private var typography = AIMTypographyPreference.lora.rawValue

    var body: some Scene {
        WindowGroup {
            appContent
                .environment(environment)
                .environment(\.locale, selectedLanguage.locale)
                .environment(\.font, selectedTypography == .lora
                    ? .custom("Lora", size: 17, relativeTo: .body)
                    : .system(.body))
                .preferredColorScheme(uiTestColorScheme ?? selectedAppearance.colorScheme)
        }
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
        normalDebugContent
        #else
        RootView()
        #endif
    }

    #if DEBUG
    @ViewBuilder private var normalDebugContent: some View {
        if ProcessInfo.processInfo.environment["AIM_KEYBOARD_LAB"] == "1" {
            AIMKeyboardLab().ignoresSafeArea()
        } else {
            RootView()
                .modifier(AIMUITestTypeSizeOverride())
        }
    }
    #endif

    private var selectedAppearance: AIMAppearancePreference {
        AIMAppearancePreference(rawValue: appearance) ?? .system
    }

    private var selectedLanguage: AIMInterfaceLanguage {
        AIMInterfaceLanguage(rawValue: interfaceLanguage) ?? .english
    }

    private var selectedTypography: AIMTypographyPreference {
        AIMTypographyPreference(rawValue: typography) ?? .lora
    }

    private static var defaultInterfaceLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("fr") == true
            ? AIMInterfaceLanguage.french.rawValue
            : AIMInterfaceLanguage.english.rawValue
    }

    private var uiTestColorScheme: ColorScheme? {
        #if DEBUG
        ProcessInfo.processInfo.environment["AIM_UI_TEST_COLOR_SCHEME"] == "dark" ? .dark : nil
        #else
        nil
        #endif
    }
}

#if DEBUG
/// Test-only environment injection. Launch arguments naming UIKit defaults did
/// not reliably change the effective type size on a physical iPhone.
private struct AIMUITestTypeSizeOverride: ViewModifier {
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["AIM_UI_TEST_DYNAMIC_TYPE"] == "accessibility5",
           ProcessInfo.processInfo.environment["AIM_UI_TEST_SCENARIO"] != nil {
            content
                .overlay(alignment: .topLeading) { AIMUITestTypeSizeProbe() }
                .dynamicTypeSize(.accessibility5)
        } else {
            content
        }
    }
}

private struct AIMUITestTypeSizeProbe: View {
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        Text(String(describing: size))
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .accessibilityIdentifier("ui-test-swiftui-type-size")
            .allowsHitTesting(false)
    }
}
#endif
