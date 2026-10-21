import AppKit
import SwiftUI

// AIM's shared interaction language: one hover treatment for every clickable surface,
// menus drawn by AIM (opaque cards, no Liquid Glass), and one segmented control.

extension AIMTheme {
    static func hover(_ scheme: ColorScheme) -> Color { Color.primary.opacity(scheme == .dark ? 0.09 : 0.055) }
    static func pressed(_ scheme: ColorScheme) -> Color { Color.primary.opacity(scheme == .dark ? 0.14 : 0.09) }
    static func menuSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.13) : .white
    }
}

/// Hover and press feedback: a soft rounded fill, never a zoom or a color jump.
struct AIMHoverStyle: ButtonStyle {
    var radius: CGFloat = 8
    var minSize: CGFloat = 0
    /// Keeps the fill while a menu or popover opened by this control is showing.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius, minSize: minSize, isActive: isActive)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        let radius: CGFloat
        let minSize: CGFloat
        let isActive: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            // A min-only frame would adopt a too-small proposed height (the composer's buttons
            // became 3 pt tall in Agent mode); the label keeps its own size unless a minimum is asked.
            configuration.label
                .frame(minWidth: minSize > 0 ? minSize : nil, minHeight: minSize > 0 ? minSize : nil)
                .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                // Settings › Appearance › Pointer cursors.
                .onHover { inside in
                    guard AppearancePreferences.pointerCursors, isEnabled else { return }
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if let path = ProcessInfo.processInfo.environment["AIM_DEBUG_HOVER_LOG"],
                       let handle = FileHandle(forWritingAtPath: path) {
                        handle.seekToEndOfFile()
                        handle.write(Data("\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\n".utf8))
                        try? handle.close()
                    }
                }
                #endif
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fill: Color {
            #if DEBUG
            // Visual check of every control's real hit area (AIM_DEBUG_SHOW_HOVER=1).
            if ProcessInfo.processInfo.environment["AIM_DEBUG_SHOW_HOVER"] == "1" { return Color.red.opacity(0.35) }
            #endif
            if configuration.isPressed { return AIMTheme.pressed(scheme) }
            return hovered || isActive ? AIMTheme.hover(scheme) : .clear
        }
    }
}

extension ButtonStyle where Self == AIMHoverStyle {
    static var aimHover: AIMHoverStyle { AIMHoverStyle() }
    static func aimHover(radius: CGFloat = 8, minSize: CGFloat = 0, active: Bool = false) -> AIMHoverStyle {
        AIMHoverStyle(radius: radius, minSize: minSize, isActive: active)
    }
}

// MARK: - Menus

private struct AIMMenuDismissKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable () -> Void = {} }

extension EnvironmentValues {
    /// Closes the AIM menu that contains the view.
    var aimMenuDismiss: @MainActor @Sendable () -> Void {
        get { self[AIMMenuDismissKey.self] }
        set { self[AIMMenuDismissKey.self] = newValue }
    }
}

extension View {
    /// Shows `menu` in an AIM menu card anchored to this view (below it, or above when there
    /// is no room). Closes on a click outside, Escape, or when a menu item is chosen.
    func aimMenu<Menu: View>(isPresented: Binding<Bool>, alignment: HorizontalAlignment = .leading,
                             maxWidth: CGFloat = 340, takesFocus: Bool = true,
                             @ViewBuilder menu: @escaping () -> Menu) -> some View {
        modifier(AIMMenuPresenter(isPresented: isPresented, alignment: alignment, maxWidth: maxWidth,
                                  takesFocus: takesFocus, menu: menu))
    }
}

private struct AIMMenuPresenter<Menu: View>: ViewModifier {
    @Binding var isPresented: Bool
    let alignment: HorizontalAlignment
    let maxWidth: CGFloat
    let takesFocus: Bool
    let menu: () -> Menu
    @Environment(AppModel.self) private var model: AppModel?

    func body(content: Content) -> some View {
        content.background(AIMMenuAnchor(isPresented: $isPresented, alignment: alignment, takesFocus: takesFocus) { dismiss in
            AnyView(AIMMenuCard(maxWidth: maxWidth) { menu() }
                .environment(\.aimMenuDismiss, dismiss)
                .environment(model))
        })
    }
}

/// The card every AIM menu is drawn in.
struct AIMMenuCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var maxWidth: CGFloat = 340
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content }
            .padding(6)
            .frame(minWidth: 200, maxWidth: maxWidth, alignment: .leading)
            .fixedSize()
            .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

/// One choice: optional icon, title, optional one-line explanation, check mark or shortcut.
struct AIMMenuItem: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var checked = false
    var shortcut: String?
    var destructive = false
    let action: () -> Void
    @Environment(\.aimMenuDismiss) private var dismiss

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, checked: Bool = false,
         shortcut: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.checked = checked
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                        .foregroundStyle(destructive ? Color.red : Color.secondary)
                        .padding(.top, subtitle == nil ? 0 : 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(destructive ? Color.red : Color.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .padding(.top, subtitle == nil ? 0 : 2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, subtitle == nil ? 7 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.aimHover(radius: 7))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

struct AIMMenuSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AIMMenuDivider: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(AIMTheme.rowDivider(scheme)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 4)
    }
}

/// Small explanatory text at the bottom of a menu.
struct AIMMenuNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 6)
    }
}

/// Hosts the menu in a borderless child panel so it can extend past the source view and
/// never picks up the system's translucent popover material.
struct AIMMenuAnchor: NSViewRepresentable {
    /// The panel hugs the card; its native window shadow follows the rounded shape.
    static let shadowMargin: CGFloat = 0
    @Binding var isPresented: Bool
    let alignment: HorizontalAlignment
    var takesFocus = true
    let content: (@escaping @MainActor @Sendable () -> Void) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { PassthroughView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { if isPresented { isPresented = false } }
        let dismiss: @MainActor @Sendable () -> Void = { coordinator.close() }
        if isPresented {
            if coordinator.panel == nil {
                DispatchQueue.main.async { coordinator.show(content(dismiss), from: view, alignment: alignment, takesFocus: takesFocus) }
            } else {
                coordinator.update(content(dismiss))
            }
        } else if coordinator.panel != nil {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor
    final class Coordinator {
        var panel: NSPanel?
        var onClose: () -> Void = {}
        private var host: NSHostingView<AnyView>?
        /// Opened under its control (grows downward) or above it (grows upward).
        private var opensBelow = true
        private var monitors: [Any] = []
        private var resignObserver: NSObjectProtocol?

        func show(_ root: AnyView, from anchor: NSView, alignment: HorizontalAlignment, takesFocus: Bool) {
            guard panel == nil, let parent = anchor.window else { return }
            let host = NSHostingView(rootView: measured(root))
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            // Rounded, clipped container: the window shadow takes the card's shape, no halo.
            let container = NSView(frame: host.frame)
            container.wantsLayer = true
            container.layer?.cornerRadius = 12
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
            container.addSubview(host)
            let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = parent.level
            panel.contentView = container
            panel.appearance = parent.effectiveAppearance
            panel.onEscape = { [weak self] in self?.close() }

            let source = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let margin = AIMMenuAnchor.shadowMargin
            // Menus stay inside the window, as in Claude and ChatGPT.
            let screen = parent.frame
            var x: CGFloat = switch alignment {
            case .trailing: source.maxX - size.width + margin
            case .center: source.midX - size.width / 2
            default: source.minX - margin
            }
            x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
            let below = source.minY - 6 - size.height + margin
            let above = source.maxY + 6 - margin
            _ = margin
            let openBelow = below >= screen.minY + 4 || above + size.height > screen.maxY - 4
            let y = openBelow ? max(below, screen.minY + 4) : above
            opensBelow = openBelow
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 0
            parent.addChildWindow(panel, ordered: .above)
            // Hover previews must not take keyboard focus from the composer.
            if takesFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
            let shift: CGFloat = openBelow ? 4 : -4
            panel.setFrameOrigin(NSPoint(x: x, y: y + shift))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(NSPoint(x: x, y: y))
            }
            self.panel = panel
            self.host = host

            // A click on the source control itself is left to its own toggle.
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak anchor] event in
                MainActor.assumeIsolated {
                    guard let self, event.window !== self.panel else { return }
                    if let anchor, event.window === anchor.window,
                       anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                    self.close()
                }
                return event
            } as Any)
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }) { monitors.append(global) }
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }

        func update(_ root: AnyView) {
            guard let host else { return }
            host.rootView = measured(root)
            resize(to: host.fittingSize)
        }

        /// The content at its natural size, reporting it when it changes (a section unfolding).
        private func measured(_ root: AnyView) -> AnyView {
            AnyView(root.fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                MainActor.assumeIsolated { self?.resize(to: size) }
            })
        }

        /// Keeps the edge next to the control in place: a menu above it grows upward.
        private func resize(to size: NSSize) {
            guard let panel, size.width > 0, size.height > 0, size != panel.frame.size else { return }
            var frame = panel.frame
            if opensBelow { frame.origin.y += frame.height - size.height }
            frame.size = size
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }

        func close() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            guard let panel else { return }
            self.panel = nil
            host = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            let onClose = onClose
            DispatchQueue.main.async { onClose() }
        }
    }

    private final class MenuPanel: NSPanel {
        var onEscape: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
        }
    }
}

// MARK: - Segmented control

/// Two or three exclusive choices in a rounded track (Chat / Agent, Online / Local).
struct AIMSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var compact = false
    var identifierPrefix = "segment-"
    @Environment(\.colorScheme) private var scheme
    @Namespace private var thumb
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { withAnimation(.snappy(duration: 0.22)) { selection = option.value } } label: {
                    // Under the pointer an unselected label darkens and grows a little (no box).
                    Text(option.label)
                        .font(.system(size: compact ? 12.5 : 14, weight: .medium))
                        .foregroundStyle(selected || hovered == option.value ? Color.primary : Color.secondary)
                        .scaleEffect(!selected && hovered == option.value ? 1.04 : 1)
                        .padding(.horizontal, compact ? 14 : 22).frame(height: compact ? 28 : 36)
                        .background {
                            if selected {
                                Capsule().fill(scheme == .dark ? Color.white.opacity(0.14) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = option.value } else if hovered == option.value { hovered = nil }
                }
                .animation(.easeOut(duration: 0.14), value: hovered)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(identifierPrefix + "\(option.value)")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
    }
}

/// Opaque card for in-window dialogs (spending limit, approvals…), never translucent.
struct AIMDialogCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

extension View {
    func aimDialogCard() -> some View { modifier(AIMDialogCard()) }
}

/// A layout-only AppKit view (menu, tooltip and window anchors): never takes clicks or hover
/// from the SwiftUI control it is attached to.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
