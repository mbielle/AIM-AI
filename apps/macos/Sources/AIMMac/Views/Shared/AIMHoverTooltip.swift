import SwiftUI
import AppKit

/// Compact tooltip for primary navigation and composer controls. It is drawn in a small
/// floating panel kept inside the window (below controls in the top bar, above the others).
struct AIMHoverTooltip: ViewModifier {
    let title: String
    let shortcut: String?
    @State private var visible = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(AIMTooltipAnchor(visible: visible, content: { AnyView(AIMTooltipBubble(title: title, shortcut: shortcut)) }))
            .onHover { inside in
                dismiss()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded { dismiss() })
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in dismiss() }
            .onDisappear { dismiss() }
            .accessibilityHint(title)
    }
    private func dismiss() { pending?.cancel(); pending = nil; visible = false }
}

private struct AIMTooltipBubble: View {
    let title: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
            if let shortcut {
                Text(shortcut).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .fixedSize()
        .padding(8)
    }
}

/// A tooltip with any content (several lines, figures), in the same dark bubble and panel.
struct AIMRichTooltip<Tip: View>: ViewModifier {
    let delay: Duration
    /// Shows it without hovering (debug gallery).
    var forced = false
    @ViewBuilder let tip: () -> Tip
    @State private var visible = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(AIMTooltipAnchor(visible: visible || forced, content: {
                AnyView(tip()
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                    .fixedSize()
                    .padding(8))
            }))
            .onHover { inside in
                dismiss()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in dismiss() }
            .onDisappear { dismiss() }
    }
    private func dismiss() { pending?.cancel(); pending = nil; visible = false }
}

private struct AIMTooltipAnchor: NSViewRepresentable {
    let visible: Bool
    let content: () -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { PassthroughView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        if visible { context.coordinator.show(content(), from: view) }
        else { context.coordinator.hide() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.hide() }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?

        func show(_ bubble: AnyView, from anchor: NSView) {
            guard panel == nil, let window = anchor.window else { return }
            let host = NSHostingView(rootView: bubble)
            let size = host.fittingSize
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = host
            let source = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let bounds = window.frame
            // Controls in the top bar get the tooltip below them, so it stays in the window.
            let below = source.maxY > bounds.maxY - 60
            var x = source.midX - size.width / 2
            x = min(max(x, bounds.minX + 2), bounds.maxX - size.width - 2)
            let y = below ? source.minY - size.height + 6 : source.maxY - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
            self.panel = panel
        }

        func hide() {
            guard let panel else { return }
            self.panel = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

extension View {
    func aimTooltip(_ title: String, shortcut: String? = nil) -> some View {
        modifier(AIMHoverTooltip(title: title, shortcut: shortcut))
    }

    func aimRichTooltip<Tip: View>(delay: Duration = .milliseconds(250), forced: Bool = false, @ViewBuilder _ tip: @escaping () -> Tip) -> some View {
        modifier(AIMRichTooltip(delay: delay, forced: forced, tip: tip))
    }
}

/// Kept for existing call sites; same feedback as every AIM control.
struct AIMIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AIMHoverStyle(radius: 9).makeBody(configuration: configuration)
    }
}
