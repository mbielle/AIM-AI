import SwiftUI

// The Settings design kit: a centered page, titled groups of rounded cards, rows with a
// title, a short description and the control on the right. Every Settings page uses it so
// spacing, type and controls stay identical from one page to the next.

enum SettingsMetrics {
    static let pageWidth: CGFloat = 760
    static let cardRadius: CGFloat = 14
    static let rowHorizontal: CGFloat = 18
    static let rowVertical: CGFloat = 14
    static let controlRadius: CGFloat = 9
}

extension AIMTheme {
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.118) : .white
    }
    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.075)
    }
    static func rowDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }
    /// The accent of switches, selections and links (Settings › Appearance › Accent).
    static var toggleOn: Color { AppearancePreferences.color(AppearancePreferences.accent) }
}

struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 34) { content }.padding(.top, 34)
            }
            .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 52).padding(.bottom, 56)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A titled card. Its direct children become rows separated by hairlines.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var description: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, description: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .padding(.bottom, description == nil ? 12 : 4)
            }
            if let description {
                Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            SettingsCard { content }
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8).padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(DividedRows(scheme: scheme)) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

private struct DividedRows: _VariadicView_UnaryViewRoot {
    let scheme: ColorScheme

    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle().fill(AIMTheme.rowDivider(scheme)).frame(height: 1)
                        .padding(.horizontal, SettingsMetrics.rowHorizontal)
                }
            }
        }
    }
}

/// Title and description on the left, the control on the right.
struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    var description: String?
    var titleColor: Color?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(titleColor ?? .primary)
                if let description, !description.isEmpty {
                    Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.vertical, SettingsMetrics.rowVertical)
        .frame(minHeight: 52)
    }
}

extension SettingsRow where Leading == EmptyView {
    init(_ title: String, description: String? = nil, titleColor: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, description: description, titleColor: titleColor, leading: { EmptyView() }, trailing: trailing)
    }
}

extension SettingsRow where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: String, description: String? = nil, titleColor: Color? = nil) {
        self.init(title: title, description: description, titleColor: titleColor, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct SettingsToggleRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, description: description) { SettingsSwitch(isOn: $isOn, label: title) }
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var label = ""

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(AIMTheme.toggleOn).controlSize(.regular)
    }
}

/// Free content inside a card (lists, previews, editors) with the row padding.
struct SettingsBlock<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.vertical, SettingsMetrics.rowVertical)
    }
}

/// A compact bordered pop-up: “Value ⌄”.
struct SettingsMenu<Value: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var placeholder = "Choose"

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? placeholder)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(AIMTheme.inputBorder(scheme)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct SettingsMenuRow<Value: Hashable>: View {
    let title: String
    var description: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    init(_ title: String, description: String? = nil, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title
        self.description = description
        _selection = selection
        self.options = options
    }

    var body: some View {
        SettingsRow(title, description: description) { SettingsMenu(selection: $selection, options: options) }
    }
}

struct SettingsTextFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var scheme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 13)).focusEffectDisabled()
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(AIMTheme.inputBorder(scheme)))
    }
}

extension TextFieldStyle where Self == SettingsTextFieldStyle {
    static var settings: SettingsTextFieldStyle { SettingsTextFieldStyle() }
}

enum SettingsButtonKind { case secondary, primary, destructive }

struct SettingsButtonStyle: ButtonStyle {
    var kind: SettingsButtonKind = .secondary
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .secondary: .primary
        case .primary: scheme == .dark ? .black : .white
        case .destructive: .red
        }
    }

    private var background: Color {
        switch kind {
        case .secondary: Color.primary.opacity(scheme == .dark ? 0.10 : 0.055)
        case .primary: scheme == .dark ? .white : Color(red: 0.09, green: 0.09, blue: 0.09)
        case .destructive: Color.red.opacity(0.09)
        }
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(kind: .primary) }
    static var settingsDestructive: SettingsButtonStyle { SettingsButtonStyle(kind: .destructive) }
}

/// A square icon button, e.g. the red trash of a removable row.
struct SettingsIconButton: View {
    let systemImage: String
    var destructive = false
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(destructive ? Color.red : Color.secondary)
                .background(destructive ? Color.red.opacity(0.08) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

enum SettingsTone { case info, success, warning, error }

struct SettingsNotice: View {
    let text: String
    var tone: SettingsTone = .info

    init(_ text: String, tone: SettingsTone = .info) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(tone == .info ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(tone == .info ? 0.06 : 0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var icon: String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// “Advanced ›”: secondary options folded under the main ones.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var expanded = false

    init(_ title: String = "Advanced", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { VStack(alignment: .leading, spacing: 34) { content } }
        }
    }
}

/// A status dot with a short label, e.g. “● Connected”.
struct SettingsStatus: View {
    let text: String
    var color: Color = .green

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}
