import AIMCore
import SwiftUI
import UIKit

enum SettingsDestination: Hashable {
    case page(AIMSettingsPage)
    case provider(ChatProvider)
    case sessions
    case pairComputer
    case account
    case profileActivity([UUID], String, String)
    case activityImport
    case memorySummary
    case dictationHistory
    case deleteAccount
    case connector(PortableConnector)
    case connectorAccount(UUID)
    case bflProvider
    case webAccountConnectors
    case webAccount(String)
    case newConnector
    case connectorPermissions
    case connectorTool(UUID, String)
}

private struct AIMSettingsSurfaceKey: EnvironmentKey {
    static let defaultValue = Color(uiColor: .secondarySystemBackground)
}
extension EnvironmentValues {
    var aimSettingsSurface: Color {
        get { self[AIMSettingsSurfaceKey.self] }
        set { self[AIMSettingsSurfaceKey.self] = newValue }
    }
}

/// All settings destinations share the same measured floating header geometry.
private struct AIMSettingsHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat { 68 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct AIMSettingsPageContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var headerHeight: CGFloat = 68
    var body: some View {
        AIMSettingsOverlayLayout { content() }
            .contentMargins(.top, headerHeight + 8, for: .scrollContent)
            .onPreferenceChange(AIMSettingsHeaderHeight.self) { headerHeight = $0 }
    }
}
private struct AIMSettingsOverlayLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let header = subviews.first else { return }
        let headerSize = header.sizeThatFits(.init(width: bounds.width, height: nil))
        // The scroll viewport covers the page; its content margins, rather than
        // a resized viewport, keep the first row accessible behind the glass.
        for body in subviews.dropFirst() { body.place(at: bounds.origin, proposal: .init(bounds.size)) }
        header.place(at: bounds.origin, proposal: .init(width: bounds.width, height: headerSize.height))
    }
}
private struct AIMSettingsHeaderSurface: ViewModifier {
    @Environment(\.aimSettingsSurface) private var surface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in Color.clear.preference(key: AIMSettingsHeaderHeight.self, value: geometry.size.height) })
            .background(alignment: .top) {
                LinearGradient(stops: [
                    .init(color: surface.opacity(reduceTransparency ? 1 : 0.97), location: 0),
                    .init(color: surface.opacity(0.9), location: 0.45),
                    .init(color: surface.opacity(0.45), location: 0.75),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -36).ignoresSafeArea(edges: .top)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .zIndex(2)
    }
}
extension View { func aimSettingsHeader() -> some View { modifier(AIMSettingsHeaderSurface()) } }

/// Settings use their own typography and tint, independently of the chat font.
struct AIMSettingsForm<Content: View>: View {
    @Environment(\.aimSettingsSurface) private var surface
    @ViewBuilder let content: () -> Content
    var body: some View {
        Form {
            content().listRowBackground(Color(uiColor: .systemBackground))
        }
            .scrollContentBackground(.hidden)
            .background(surface)
            .font(.system(.body))
            .tint(.primary)
            .environment(\.defaultMinListRowHeight, 52)
            .accessibilityIdentifier("settings-page-form")
    }
}

struct AIMSettingsAction: View {
    let title: String
    var icon: String? = nil
    var value: String? = nil
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).font(.system(size: 18)).frame(width: 24) }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).foregroundStyle(.primary)
                        if let value { Text(value).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct AIMSettingsEditor: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.subheadline, weight: .medium))
            TextEditor(text: $text)
                .font(.system(.body)).frame(minHeight: 140)
                .scrollContentBackground(.hidden).padding(8)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.16)))
                .accessibilityLabel(title)
        }.padding(.vertical, 8)
    }
}

struct AIMSettingsMessage: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.system(.footnote)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AIMSettingsTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(title, text: $text, prompt: Text(prompt))
                .padding(12)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.16)))
                .accessibilityLabel(title)
        }.padding(.vertical, 6)
    }
}

/// A draft supplies the same leave route used by its visible Back button.
private final class SettingsBackProtection: Equatable {
    let onAttempt: () -> Void
    init(onAttempt: @escaping () -> Void) { self.onAttempt = onAttempt }
    static func == (lhs: SettingsBackProtection, rhs: SettingsBackProtection) -> Bool { lhs === rhs }
}
private struct SettingsBackProtectionKey: PreferenceKey {
    static var defaultValue: SettingsBackProtection? { nil }
    static func reduce(value: inout SettingsBackProtection?, nextValue: () -> SettingsBackProtection?) {
        if let next = nextValue() { value = next }
    }
}

/// Preserve UIKit's interactive transition while supplying a delegate for the hidden navigation bar.
/// This lives on each destination, so a cancelled swipe keeps its hosting view and scroll position.
private struct SettingsPopGestureBridge: UIViewControllerRepresentable {
    let protection: SettingsBackProtection?
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.protection = protection
        controller.installIfVisible()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var protection: SettingsBackProtection?
        private weak var recognizer: UIGestureRecognizer?
        private weak var originalDelegate: UIGestureRecognizerDelegate?
        override func viewDidLoad() { super.viewDidLoad(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); installIfVisible() }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); restore() }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // SwiftUI attaches its destination hosting controller after inserting this child.
            DispatchQueue.main.async { [weak self] in self?.installIfVisible() }
        }
        func installIfVisible() {
            guard let navigation = navigationController, let gesture = navigation.interactivePopGestureRecognizer else { return }
            var host: UIViewController = self
            while let parent = host.parent, parent !== navigation { host = parent }
            guard navigation.topViewController === host else { return }
            if gesture.delegate !== self {
                originalDelegate = gesture.delegate
                recognizer = gesture
                gesture.delegate = self
            }
            gesture.isEnabled = navigation.viewControllers.count > 1
        }
        func restore() {
            if let recognizer, recognizer.delegate === self { recognizer.delegate = originalDelegate }
            recognizer = nil
            originalDelegate = nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigation = navigationController, navigation.viewControllers.count > 1,
                  navigation.transitionCoordinator == nil, navigation.presentedViewController == nil else { return false }
            if let protection {
                // Do not start a pop and then try to undo it: request the editor's confirmation first.
                DispatchQueue.main.async { protection.onAttempt() }
                return false
            }
            return true
        }
    }
}
extension View {
    func settingsDraftNavigationProtection(_ guarded: Bool, onBackAttempt: @escaping () -> Void) -> some View {
        preference(key: SettingsBackProtectionKey.self, value: guarded ? SettingsBackProtection(onAttempt: onBackAttempt) : nil)
    }
    func settingsBackNavigation() -> some View {
        backgroundPreferenceValue(SettingsBackProtectionKey.self) { protection in
            SettingsPopGestureBridge(protection: protection).frame(width: 0, height: 0)
        }
    }
}
