import AppKit
import AIMApplication
import CoreText
import SwiftUI

/// Values taken from the active light/dark tokens of AIM AI 1.0.289.
/// Keeping the palette here prevents each screen from drifting as it is ported.
enum AIMTheme {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.078, green: 0.078, blue: 0.078) : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        muted(scheme)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.173, green: 0.173, blue: 0.173) : Color(red: 0.953, green: 0.953, blue: 0.953)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    static func foreground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.96) : Color(red: 0.09, green: 0.09, blue: 0.09)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.58)
    }

    static func inputBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.19) : Color.black.opacity(0.13)
    }
}

enum AIMTypography {
    static func conversation(_ appearance: ConversationAppearance, size: Int? = nil, weight: Font.Weight = .regular) -> Font {
        let points = CGFloat(size ?? appearance.textSize)
        return appearance.typeface == .lora ? title(points, weight: weight) : .system(size: points, weight: weight)
    }
    static func registerBundledFonts() {
        // SwiftPM's .process rule flattens the Fonts directory in the bundle.
        guard let url = Bundle.module.url(forResource: "Lora-Variable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func title(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Lora", size: size).weight(weight)
    }
}

struct AIMLogoView: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: "aimai-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct StatusPill: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(AIMTheme.muted(scheme), in: Capsule())
    }
}
