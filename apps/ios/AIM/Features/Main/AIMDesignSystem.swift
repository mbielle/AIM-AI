import AIMCore
import Observation
import SwiftUI
import UIKit
import OSLog

enum AIMComposerTrace {
    static let enabled = ProcessInfo.processInfo.environment["AIM_COMPOSER_TRACE"] == "1" || ProcessInfo.processInfo.arguments.contains("-aimComposerTrace")
    private static let logger = Logger(subsystem: "com.aimai.continuity", category: "composer")
    static func geometry(_ value: String) { if enabled { logger.info("\(value, privacy: .public)") } }
}

@MainActor final class AIMDrawerMotionState {
    var displayedOffset: () -> CGFloat = { 0 }
    var restingOffset: CGFloat = 0
}

/// One UIKit transaction owns the card and keyboard movement. Neither follows
/// an already rendered frame of the other.
struct AIMMovingConversation<Content: View>: UIViewControllerRepresentable {
    var offset: CGFloat
    var motion: AIMDrawerMotionState
    var open: Bool
    var close: () -> Void
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        // Forward presentation preferences, not the representable's complete
        // environment: its inherited accessibility identity hides this child
        // hosting controller's elements on device.
        let root = AnyView(content()
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.locale, context.environment.locale)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
            .environment(\.layoutDirection, context.environment.layoutDirection)
            .environment(\.font, context.environment.font))
        controller.updateRoot(root, offset: offset, animated: context.transaction.animation != nil)
        motion.restingOffset = open ? offset : 0
        motion.displayedOffset = { [weak controller] in controller?.displayedOffset ?? 0 }
        controller.close = close
        controller.changed = changed
        controller.ended = ended
        controller.move(to: offset, open: open,
                        animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stopMotion(); controller.resetKeyboard() }

    final class Controller: UIViewController {
        private final class PassthroughView: UIView {
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let hit = super.hitTest(point, with: event)
                return hit === self ? nil : hit
            }
        }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let cardContainer = UIView()
        private var animator: UIViewPropertyAnimator?
        private weak var keyboard: UIWindow?
        private var original = CATransform3DIdentity
        private var target: CGFloat = 0
        private var lastMoveTime: CFTimeInterval = 0
        private var dragVelocity: CGFloat = 0
        func updateRoot(_ root: AnyView, offset: CGFloat, animated: Bool) {
            // Keep the existing tree mounted during frame-by-frame dragging.
            // Returning to rest also commits a new destination. Without this,
            // a nonanimated reset can leave the previous hosting tree on screen.
            if animated || abs(offset) < 0.01 || abs(offset - target) < 0.01 { host.rootView = root }
        }
        var displayedOffset: CGFloat { cardContainer.layer.presentation()?.affineTransform().tx ?? cardContainer.transform.tx }
        private var shield: UIView?
        var close: () -> Void = {}
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat, CGFloat) -> Void = { _, _ in }

        override func loadView() { view = PassthroughView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            cardContainer.backgroundColor = .clear
            cardContainer.layer.shadowColor = UIColor.black.cgColor
            cardContainer.layer.shadowRadius = 24
            cardContainer.layer.shadowOffset = CGSize(width: 8, height: 0)
            host.view.layer.cornerCurve = .continuous
            host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            host.view.clipsToBounds = true
            view.addSubview(cardContainer)
            addChild(host); cardContainer.addSubview(host.view); host.didMove(toParent: self)
            NotificationCenter.default.addObserver(self, selector: #selector(resetKeyboard), name: UIApplication.willResignActiveNotification, object: nil)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            cardContainer.bounds = view.bounds
            cardContainer.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            host.view.frame = cardContainer.bounds
        }
        func stopMotion() { animator?.stopAnimation(true); animator = nil }
        @objc func resetKeyboard() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            keyboard?.layer.removeAnimation(forKey: "aim.drawer")
            keyboard?.layer.sublayerTransform = original
            CATransaction.commit()
            shield?.removeFromSuperview(); shield = nil; keyboard = nil
        }
        func move(to x: CGFloat, open: Bool, animated: Bool) {
            loadViewIfNeeded()
            if AIMExperimentalKeyboardHost.enabled,
               keyboard !== AIMExperimentalKeyboardHost.shared.window {
                resetKeyboard()
                if let candidate = AIMExperimentalKeyboardHost.shared.window, !candidate.isHidden {
                    keyboard = candidate; original = candidate.layer.sublayerTransform
                }
            }
            let changedTarget = abs(target - x) > 0.01
            guard changedTarget else { return }
            let now = CACurrentMediaTime()
            if !animated, lastMoveTime > 0, now - lastMoveTime < 0.1 {
                dragVelocity = (x - target) / max(0.001, now - lastMoveTime)
            }
            lastMoveTime = now
            let from = cardContainer.layer.presentation()?.affineTransform() ?? cardContainer.transform
            let previousShadow = cardContainer.layer.presentation()?.shadowOpacity ?? cardContainer.layer.shadowOpacity
            let keyboardFrom = keyboard?.layer.presentation()?.sublayerTransform ?? keyboard?.layer.sublayerTransform ?? original
            // Freeze the displayed frame before accepting a reversal. Model-layer
            // geometry is never used as the starting point of an interrupted pan.
            animator?.stopAnimation(true)
            animator = nil
            cardContainer.transform = from
            cardContainer.layer.shadowOpacity = previousShadow
            keyboard?.layer.removeAnimation(forKey: "aim.drawer")
            keyboard?.layer.sublayerTransform = keyboardFrom
            host.view.layer.cornerRadius = (x > 0 || from.tx > 0) ? AIMDesign.contentLeadingRadius : 0
            let apply = { [weak self] in
                guard let self else { return }
                self.cardContainer.transform = CGAffineTransform(translationX: x, y: 0)
                self.cardContainer.layer.shadowOpacity = x > 0 ? 0.25 : 0
                self.keyboard?.layer.sublayerTransform = CATransform3DTranslate(self.original, x, 0, 0)
            }
            if animated && !UIAccessibility.isReduceMotionEnabled {
                let distance = x - from.tx
                let velocity = abs(distance) > 1 ? max(-8, min(8, dragVelocity / distance)) : 0
                let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: velocity, dy: 0))
                let animation = UIViewPropertyAnimator(duration: 0.32, timingParameters: timing)
                animation.addAnimations(apply)
                dragVelocity = 0
                animation.addCompletion { [weak self] position in
                    guard let self, position == .end else { return }
                    self.animator = nil
                    if abs(self.target) < 0.01 { self.host.view.layer.cornerRadius = 0 }
                }
                animator = animation
                animation.startAnimation()
            } else {
                UIView.performWithoutAnimation(apply)
                if x == 0 { host.view.layer.cornerRadius = 0 }
            }
            target = x
            if open, shield == nil, let keyboard {
                let cover = UIView(frame: keyboard.bounds)
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
                cover.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
                keyboard.addSubview(cover); shield = cover
            } else if !open { shield?.removeFromSuperview(); shield = nil }
        }
        @objc private func tapped() { close() }
        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let x = pan.translation(in: keyboard).x
            switch pan.state {
            case .changed: changed(x)
            case .ended: ended(x, x + pan.velocity(in: keyboard).x * 0.15)
            case .cancelled, .failed: ended(0, 0)
            default: break
            }
        }
    }
}

// MARK: - Development keyboard continuity bridge

/// Uses an undocumented system window hierarchy. Enabled in Release at the
/// user's explicit request; this is not an App Store compatibility guarantee.
@MainActor
final class AIMExperimentalKeyboardHost: NSObject {
    static let shared = AIMExperimentalKeyboardHost()
    static var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AIMKeyboardContinuityEnabled") as? Bool ?? true
    }
    private(set) weak var window: UIWindow?
    private override init() {
        super.init()
        guard Self.enabled else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(visible(_:)),
            name: UIWindow.didBecomeVisibleNotification, object: nil)
    }
    @objc private func visible(_ notification: Notification) {
        guard let candidate = notification.object as? UIWindow,
              String(describing: type(of: candidate)).contains("UIRemoteKeyboardWindow") else { return }
        window = candidate
    }
}


enum AIMModelNamePresentation {
    static func displayName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "remote.new.model_unavailable") }

        return trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { token in
                let lowercased = token.lowercased()
                if ["gpt", "ai", "llm"].contains(lowercased) { return lowercased.uppercased() }
                return lowercased.prefix(1).uppercased() + String(lowercased.dropFirst())
            }
            .joined(separator: " ")
    }
}

private struct AIMSidebarPresentedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AIMKeyboardOverlapEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Lets transient content owned by the active page disappear before the
    /// native drawer is revealed. Popovers otherwise live in a presentation
    /// layer above the drawer and visually leak across both surfaces.
    var aimSidebarPresented: Bool {
        get { self[AIMSidebarPresentedEnvironmentKey.self] }
        set { self[AIMSidebarPresentedEnvironmentKey.self] = newValue }
    }

    /// The portion of the app window covered by the system keyboard. The
    /// value is derived from `UIKeyboardLayoutGuide`, so it follows docked,
    /// floating and interactively dismissed keyboards without resizing the
    /// page hierarchy.
    var aimKeyboardOverlap: CGFloat {
        get { self[AIMKeyboardOverlapEnvironmentKey.self] }
        set { self[AIMKeyboardOverlapEnvironmentKey.self] = newValue }
    }
}

struct AIMKeyboardLayoutObserver: UIViewRepresentable {
    @Binding var overlap: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KeyboardProbeView {
        let view = KeyboardProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.report = { value in
            guard abs(overlap - value) > 0.5 else { return }
            DispatchQueue.main.async { overlap = value }
        }
        context.coordinator.install(for: view)
        return view
    }

    func updateUIView(_ view: KeyboardProbeView, context: Context) {
        view.report = { value in
            guard abs(overlap - value) > 0.5 else { return }
            DispatchQueue.main.async { overlap = value }
        }
        view.reportCurrentOverlap()
    }

    static func dismantleUIView(_ view: KeyboardProbeView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: @unchecked Sendable {
        private weak var view: KeyboardProbeView?
        private var observers: [NSObjectProtocol] = []

        func install(for view: KeyboardProbeView) {
            self.view = view
            let center = NotificationCenter.default
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let view = self?.view else { return }
                        view.setNeedsLayout()
                        view.reportCurrentOverlap()
                    }
                })
            }
        }

        func uninstall() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        deinit { uninstall() }
    }

    final class KeyboardProbeView: UIView {
        var reportRevision = 0
        var report: (CGFloat) -> Void = { _ in }
        private let keyboardTopMarker = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            keyboardTopMarker.translatesAutoresizingMaskIntoConstraints = false
            keyboardTopMarker.isUserInteractionEnabled = false
            keyboardTopMarker.isHidden = true
            addSubview(keyboardTopMarker)
            NSLayoutConstraint.activate([
                keyboardTopMarker.leadingAnchor.constraint(equalTo: leadingAnchor),
                keyboardTopMarker.widthAnchor.constraint(equalToConstant: 1),
                keyboardTopMarker.heightAnchor.constraint(equalToConstant: 1),
                keyboardTopMarker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportCurrentOverlap()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportCurrentOverlap()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportCurrentOverlap()
        }

        func reportCurrentOverlap() {
            guard window != nil else {
                report(0)
                return
            }
            layoutIfNeeded()
            let keyboardFrame = keyboardLayoutGuide.layoutFrame
            guard !keyboardFrame.isNull,
                  !keyboardFrame.isInfinite,
                  keyboardFrame.minY.isFinite,
                  keyboardFrame.maxY.isFinite
            else {
                report(0)
                return
            }
            let hiddenTop = bounds.maxY - safeAreaInsets.bottom
            let isVisible = keyboardFrame.width > 1
                && keyboardFrame.height > safeAreaInsets.bottom + 1
                && keyboardFrame.minY < hiddenTop - 1
            report(isVisible ? max(0, bounds.maxY - keyboardFrame.minY) : 0)
        }
    }
}

@MainActor
@Observable
final class AIMUniversalPanelCoordinator<Route: Hashable> {
    private(set) var routes: [Route] = []
    var isPresented: Bool { !routes.isEmpty }
    var current: Route? { routes.last }
    var canGoBack: Bool { routes.count > 1 }

    func present(_ route: Route) { routes = [route] }
    func push(_ route: Route) {
        guard routes.last != route else { return }
        routes.append(route)
    }
    @discardableResult func goBack() -> Route? {
        guard routes.count > 1 else { close(); return nil }
        routes.removeLast()
        return routes.last
    }
    func close() { routes.removeAll() }
}

enum AIMDesign {
    static let drawerMaximumWidth: CGFloat = 352
    static let drawerRelativeWidth: CGFloat = 0.88
    static let contentLeadingRadius: CGFloat = 40
    static let standardTouchTarget: CGFloat = 44
    static let composerRadius: CGFloat = 32
    static let universalPanelRadius: CGFloat = 40
    static let universalPanelMargin: CGFloat = 8
    static let contextChipHeight: CGFloat = 40

    static let drawerAnimation = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.3)

    static func sidebarBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 44 / 255)
            : Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255)
    }

    static func userMessageBackground(for colorScheme: ColorScheme) -> Color {
        sidebarBackground(for: colorScheme)
    }

    static func titleFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(size: size, weight: weight, relativeTo: .title)
    }

    static func bodyFont(size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        font(size: size, weight: weight, relativeTo: .body)
    }

    static func controlFont(size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        font(size: size, weight: weight, relativeTo: .callout)
    }

    static func captionFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        font(size: size, weight: weight, relativeTo: .caption)
    }

    private static func font(
        size: CGFloat,
        weight: Font.Weight,
        relativeTo textStyle: Font.TextStyle
    ) -> Font {
        let raw = UserDefaults.standard.string(forKey: "aim.typography")
        let preference = AIMTypographyPreference(rawValue: raw ?? "") ?? .lora
        if preference == .lora {
            return .custom("Lora", size: size, relativeTo: textStyle).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

/// A single vocabulary for the tactile feedback used throughout AIM. Keeping
/// these calls centralized avoids different screens inventing incompatible
/// intensities for the same interaction.
@MainActor
enum AIMHaptics {
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard UserDefaults.standard.object(forKey: "aim.haptics") as? Bool != false else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func success() { notification(.success) }
    static func warning() { notification(.warning) }
    static func error() { notification(.error) }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

struct AIMComposerBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous).stroke(Color.primary.opacity(0.16), lineWidth: 0.8) }
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.16)).interactive(),
                    in: RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.50), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 14, y: 5)
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous))
                .background(
                    (colorScheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.70) : Color.white.opacity(0.82)),
                    in: RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AIMDesign.composerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.12), radius: 14, y: 5)
        }
    }
}

struct AIMGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 0.8) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(colorScheme == .dark ? Color.white.opacity(0.025) : Color.white.opacity(0.12)).interactive(),
                in: Capsule()
            )
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.70), in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.8) }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.07), radius: 9, y: 3)
        }
    }
}

struct AIMTintedGlassCapsule: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                // A small coloured substrate keeps the control legible over
                // white photo thumbnails while the system Liquid Glass still
                // owns refraction, highlights and interaction.
                .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                .glassEffect(
                    .regular.tint(tint.opacity(colorScheme == .dark ? 0.34 : 0.28)).interactive(),
                    in: Capsule()
                )
                .overlay { Capsule().stroke(tint.opacity(colorScheme == .dark ? 0.38 : 0.30), lineWidth: 0.8) }
                .shadow(color: tint.opacity(0.12), radius: 10, y: 3)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                .overlay { Capsule().stroke(tint.opacity(0.28), lineWidth: 0.8) }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.07), radius: 9, y: 3)
        }
    }
}

struct AIMGlassCircle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.16), lineWidth: 0.8) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(colorScheme == .dark ? Color.white.opacity(0.025) : Color.white.opacity(0.10)).interactive(),
                in: Circle()
            )
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .background(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.72), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.8) }
        }
    }
}

struct AIMTranslucentHeaderBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Keep headers visually continuous with the page. The material
                // remains underneath so moving content is still perceptible,
                // while this wash prevents iOS from turning an empty header grey.
                Rectangle().fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.80)
                        : Color.white.opacity(0.88)
                )
            }
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.055))
                    .frame(height: 0.5)
            }
            }
    }
}

/// Headers hosted by the universal panel must visually continue the panel
/// surface, including in Dark Mode. A generic black material creates a visible
/// seam against the dark grey sheet, so this modifier uses the exact panel
/// colour as its wash while retaining a small amount of translucency.
struct AIMUniversalPanelHeaderBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let panelColor = colorScheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color.white

        content
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(panelColor.opacity(colorScheme == .dark ? 0.94 : 0.90))
                }
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.055))
                        .frame(height: 0.5)
                }
            }
    }
}

/// A narrow status-bar veil for immersive conversations. Unlike the regular
/// header this never paints an opaque navigation band: messages remain visible
/// while progressively fading underneath the system clock and indicators.
struct AIMStatusBarFade: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.82 : 0.76),
                    Color(uiColor: .systemBackground).opacity(0.42),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .mask {
            LinearGradient(
                colors: [.black, .black.opacity(0.72), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AIMGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10, content: content)
        } else {
            content()
        }
    }
}

struct AIMCreationModeSelector: View {
    let selection: RemoteMode
    let select: (RemoteMode) -> Void

    var body: some View {
        AIMGlassGroup {
            HStack(spacing: 2) {
                modeButton(.chat, title: "Chat")
                modeButton(.code, title: "Code")
                modeButton(.agent, title: "Agent")
            }
            .padding(3)
            .aimGlassCapsule()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("creation-mode-selector")
    }

    private func modeButton(_ mode: RemoteMode, title: LocalizedStringKey) -> some View {
        Button {
            guard mode != selection else { return }
            AIMHaptics.selection()
            select(mode)
        } label: {
            Text(title)
                .font(AIMDesign.controlFont(size: 14, weight: .semibold))
                .frame(minWidth: 54)
                .frame(height: 38)
                .contentShape(Capsule())
                .modifier(AIMSelectedModeSurface(selected: mode == selection))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == selection ? .isSelected : [])
        .accessibilityIdentifier("creation-mode-\(mode.rawValue)")
    }
}

private struct AIMSelectedModeSurface: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content.background(AIMDesign.sidebarBackground(for: colorScheme), in: Capsule())
        } else {
            content
        }
    }
}

/// Recognizes a downward swipe anywhere in the composer, including the native
/// text editor and its buttons, without competing with horizontal drawer pans.
struct AIMComposerDismissSwipe: UIViewRepresentable {
    let dismiss: () -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.dismiss = dismiss }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.uninstall() }
    final class Probe: UIView, UIGestureRecognizerDelegate {
        var dismiss: () -> Void = {}
        private var swipe: UISwipeGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            uninstall()
            guard let window else { return }
            let gesture = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            gesture.direction = .down
            gesture.delegate = self
            gesture.cancelsTouchesInView = false
            window.addGestureRecognizer(gesture)
            swipe = gesture
        }
        func uninstall() { if let swipe { swipe.view?.removeGestureRecognizer(swipe) }; swipe = nil }
        @objc private func swiped() { dismiss() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self)) && window != nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

/// Runs a row action only when the finger was released as a genuine tap.
/// SwiftUI buttons embedded in a full-screen interactive drawer can otherwise
/// receive their action at the end of a horizontal pan. Tracking the complete
/// touch keeps taps, long presses and swipes distinct while still allowing the
/// parent scroll and drawer gestures to run simultaneously.
private struct AIMSwipeSafeTapModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // SwiftUI's tap recognizer is cancelled by a pan once the system
            // scroll view crosses its movement threshold. This keeps rows
            // selectable without installing a zero-distance drag recognizer
            // that starves vertical scrolling in the sidebar.
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// Resolves user-supplied model artwork from the bundled `ModelLogos` folder.
/// A model-specific slug wins, then the provider slug, with a deterministic
/// typographic fallback so an incomplete logo set never breaks the picker.
struct AIMModelLogo: View {
    let modelID: String
    let provider: String
    let displayName: String
    var size: CGFloat = 46
    private var identity: String {
        if modelID.contains("/") { return String(modelID.split(separator: "/")[0]) }
        let lower = modelID.lowercased()
        if lower.hasPrefix("claude") { return "anthropic" }
        if lower.hasPrefix("gemini") { return "google" }
        if lower.hasPrefix("flux") { return "black-forest-labs" }
        if lower.hasPrefix("gpt") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return "openai" }
        return provider
    }
    var body: some View { AIMBrandLogo(identity: identity, size: size) }
}

private struct AIMUniversalPanelSurface: ViewModifier {
    var background: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let panelColor = background ?? (colorScheme == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : Color.white)

        content
            .background(panelColor)
            // The presentation controller already owns the panel geometry.
            // Padding and clipping the content here created a second white card
            // inside the real sheet, visible as the grey "panel in a panel".
            .presentationBackground(panelColor)
            .presentationCornerRadius(AIMDesign.universalPanelRadius)
            .presentationContentInteraction(.scrolls)
    }
}

extension View {
    func aimComposerBackground() -> some View {
        modifier(AIMComposerBackground())
    }

    func aimGlassCapsule() -> some View { modifier(AIMGlassCapsule()) }
    func aimGlassCapsule(tint: Color) -> some View { modifier(AIMTintedGlassCapsule(tint: tint)) }
    func aimGlassCircle() -> some View { modifier(AIMGlassCircle()) }
    func aimTranslucentHeader() -> some View { modifier(AIMTranslucentHeaderBackground()) }
    func aimUniversalPanelHeader() -> some View { modifier(AIMUniversalPanelHeaderBackground()) }
    func aimUniversalPanelSurface(background: Color? = nil) -> some View { modifier(AIMUniversalPanelSurface(background: background)) }
    func aimSwipeSafeTap(action: @escaping () -> Void) -> some View {
        modifier(AIMSwipeSafeTapModifier(action: action))
    }
}

// MARK: - Shared immersive conversation surface

@MainActor @Observable
final class AIMPanelPresentationState {
    var activePresentations: Set<UUID> = []
    var blocksBackground: Bool { !activePresentations.isEmpty }
}
private struct AIMPanelPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: AIMPanelPresentationState? = nil
}
private struct AIMComposerDockedEnvironmentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aimPanelPresentationState: AIMPanelPresentationState? {
        get { self[AIMPanelPresentationEnvironmentKey.self] }
        set { self[AIMPanelPresentationEnvironmentKey.self] = newValue }
    }
    var aimComposerDocked: Bool {
        get { self[AIMComposerDockedEnvironmentKey.self] }
        set { self[AIMComposerDockedEnvironmentKey.self] = newValue }
    }
}
private struct AIMBackgroundInteractionBlock: ViewModifier {
    let active: Bool
    @Environment(\.aimPanelPresentationState) private var presentations
    @State private var identifier = UUID()
    func body(content: Content) -> some View {
        content.onAppear { update(active) }.onChange(of: active) { _, value in update(value) }
            .onDisappear { update(false) }
    }
    private func update(_ active: Bool) {
        if active { presentations?.activePresentations.insert(identifier) }
        else { presentations?.activePresentations.remove(identifier) }
    }
}
extension View {
    func aimBlocksBackgroundInteractions(_ active: Bool) -> some View {
        modifier(AIMBackgroundInteractionBlock(active: active))
    }
}

/// Messages occupy the whole surface. Only the controls carry glass; neither
/// the header nor the keyboard dock paints an opaque full-width substrate.
struct AIMConversationScaffold<Content: View, Header: View, Composer: View>: View {
    let safeTop: CGFloat
    let safeBottom: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var composer: () -> Composer
    @State private var bottomOcclusion: CGFloat = 120
    var body: some View {
        ZStack {
            content(bottomOcclusion)
            AIMConversationKeyboardDock(safeBottom: safeBottom, occlusion: $bottomOcclusion) {
                composer().environment(\.aimComposerDocked, true)
            }
            VStack(spacing: 0) {
                AIMStatusBarFade().frame(height: safeTop + 22)
                Spacer(minLength: 0)
            }.allowsHitTesting(false)
            VStack(spacing: 0) { header(); Spacer(minLength: 0) }
        }.background(Color(uiColor: .systemBackground))
    }
}

/// Auto Layout follows the system keyboard guide in the keyboard's own
/// transaction. SwiftUI never animates an asynchronously sampled keyboard inset.
struct AIMConversationKeyboardDock<Content: View>: UIViewControllerRepresentable {
    let safeBottom: CGFloat
    @Binding var occlusion: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.aimSidebarPresented) private var sidebar
    @Environment(\.aimPanelPresentationState) private var presentations
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.loadViewIfNeeded()
        controller.host.rootView = AnyView(content()
            .environment(\.colorScheme, colorScheme).environment(\.locale, locale)
            .environment(\.dynamicTypeSize, dynamicType).environment(\.aimSidebarPresented, sidebar)
            .environment(\.aimPanelPresentationState, presentations))
        controller.bottom.constant = -(safeBottom + 8)
        controller.reportRevision += 1
        let revision = controller.reportRevision
        controller.report = { [weak controller] value in
            guard value.isFinite, value > 0, abs(value - occlusion) > 0.5 else { return }
            DispatchQueue.main.async {
                guard controller?.reportRevision == revision else { return }
                occlusion = value
            }
        }
        controller.resize(animated: context.transaction.animation != nil)
    }
    final class Controller: UIViewController {
        private final class Passthrough: UIView {
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let hit = super.hitTest(point, with: event)
                return hit === self ? nil : hit
            }
        }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        var bottom: NSLayoutConstraint!
        private var height: NSLayoutConstraint!
        var reportRevision = 0
        var report: (CGFloat) -> Void = { _ in }
        override func loadView() { view = Passthrough() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            host.sizingOptions = []
            addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            bottom = host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            bottom.priority = .defaultHigh
            height = host.view.heightAnchor.constraint(equalToConstant: 60)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
                host.view.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -4),
                bottom, height,
            ])
        }
        func resize(animated: Bool) {
            guard view.bounds.width > 0 else { view.setNeedsLayout(); return }
            let size = host.sizeThatFits(in: CGSize(width: view.bounds.width, height: 10_000))
            guard size.height.isFinite, size.height > 0, abs(height.constant - size.height) > 0.5 else { return }
            AIMComposerTrace.geometry("dock width=\(view.bounds.width) height=\(size.height) keyboardY=\(view.keyboardLayoutGuide.layoutFrame.minY) anchorY=\(host.view.frame.minY)")
            height.constant = size.height
            if animated && !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
            } else { view.setNeedsLayout() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            resize(animated: false)
            report(max(0, view.bounds.maxY - host.view.frame.minY))
        }
    }
}

private struct AIMConversationTailPositionKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Follow a streaming answer only while the reader is at the tail. A manual
/// scroll upward must never be undone by a token arriving or the keyboard.
struct AIMConversationTimeline<Rows: View>: View {
    let identity: String
    let revision: String
    let safeTop: CGFloat
    let bottomOcclusion: CGFloat
    @ViewBuilder var rows: () -> Rows
    @State private var followsTail = true
    @State private var initialized = false
    @State private var dragging = false
    @State private var tailUpdate: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        rows()
                        Color.clear.frame(height: bottomOcclusion + 16).id("immersive-conversation-tail")
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: AIMConversationTailPositionKey.self,
                                    value: marker.frame(in: .named("immersive-conversation-scroll")).maxY)
                            })
                    }
                    .padding(.horizontal, 16).padding(.top, safeTop + 80)

                }
                .coordinateSpace(name: "immersive-conversation-scroll")
                .modifier(AIMConversationScrollAnchor())
                .accessibilityIdentifier("immersive-conversation-scroll")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in dragging = true }
                    .onEnded { _ in dragging = false })
                .onPreferenceChange(AIMConversationTailPositionKey.self) { position in
                    if dragging { followsTail = position <= viewport.size.height + 70 }
                    else if initialized && followsTail && abs(position - viewport.size.height) > 1 {
                        // Delayed streaming presentation and keyboard layout can
                        // change row height after the model revision was handled.
                        scheduleTail(proxy)
                    }
                }
                .onChange(of: revision) { _, _ in
                    scheduleTail(proxy)
                }
                .onChange(of: bottomOcclusion) { _, _ in
                    // SwiftUI must first lay out the new spacer. Scrolling in the
                    // old transaction leaves the transcript at its keyboard-up offset.
                    tailUpdate?.cancel(); tailUpdate = nil
                    scheduleTail(proxy, delay: 50)
                }
                .onChange(of: identity, initial: true) { _, _ in
                    followsTail = true
                    initialized = false
                    tailUpdate?.cancel(); tailUpdate = nil
                    Task { @MainActor in
                        await Task.yield()
                        guard !initialized else { return }
                        proxy.scrollTo("immersive-conversation-tail", anchor: .bottom)
                        initialized = true
                    }
                }
                .onDisappear { tailUpdate?.cancel(); tailUpdate = nil }
            }
        }
    }

    private func scheduleTail(_ proxy: ScrollViewProxy, delay: Int = 33) {
        guard followsTail, !dragging, tailUpdate == nil else { return }
        tailUpdate = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard followsTail, !dragging else { tailUpdate = nil; return }
            if reduceMotion { proxy.scrollTo("immersive-conversation-tail", anchor: .bottom) }
            else { withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo("immersive-conversation-tail", anchor: .bottom) } }
            tailUpdate = nil
        }
    }
}

private struct AIMConversationScrollAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment)
        } else {
            // Tail following is explicit; an underfilled transcript must remain top aligned.
            content.defaultScrollAnchor(.top)
        }
    }
}
