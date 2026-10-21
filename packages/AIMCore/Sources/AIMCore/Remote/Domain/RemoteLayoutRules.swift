import Foundation

public enum RemoteMode: String, CaseIterable, Codable, Hashable, Sendable {
    case code
    case agent
    case chat

    public static func from(path: String) -> Self {
        if path.hasPrefix("/agent") { return .agent }
        if path == "/" || path.hasPrefix("/chat") { return .chat }
        return .code
    }
}

/// Pure geometry shared by the native drawer and its tests.
/// Values deliberately mirror the mobile web shell: `min(88vw, 22rem)`.
public enum RemoteDrawerRules {
    public static let relativeWidth = 0.88
    public static let maximumWidth = 352.0

    public static func width(containerWidth: Double) -> Double {
        min(maximumWidth, max(0, containerWidth) * relativeWidth)
    }

    public static func offset(
        isOpen: Bool,
        dragTranslation: Double,
        containerWidth: Double
    ) -> Double {
        let drawerWidth = width(containerWidth: containerWidth)
        let startingOffset = isOpen ? drawerWidth : 0
        return min(drawerWidth, max(0, startingOffset + dragTranslation))
    }

    public static func progress(offset: Double, containerWidth: Double) -> Double {
        let drawerWidth = width(containerWidth: containerWidth)
        guard drawerWidth > 0 else { return 0 }
        return min(1, max(0, offset / drawerWidth))
    }

    public static func shouldOpen(
        currentlyOpen: Bool,
        translation: Double,
        predictedTranslation: Double,
        containerWidth: Double
    ) -> Bool {
        let drawerWidth = width(containerWidth: containerWidth)
        if currentlyOpen {
            let closingTranslation = min(translation, predictedTranslation)
            return drawerWidth + closingTranslation >= drawerWidth * 0.5
        }
        let openingTranslation = max(translation, predictedTranslation)
        return openingTranslation >= drawerWidth * 0.25
    }
}

public enum RemoteSheetState: Sendable { case closed, compact, expanded }
public enum RemoteGestureAxis: Sendable { case undecided, vertical, horizontal }

public struct RemoteSheetBounds: Equatable, Sendable {
    public let expandedTop: Double
    public let compactTop: Double
    public let closedTop: Double

    public init(expandedTop: Double, compactTop: Double, closedTop: Double) {
        self.expandedTop = expandedTop
        self.compactTop = compactTop
        self.closedTop = closedTop
    }
}

public struct RemoteSheetGeometry: Equatable, Sendable {
    public let top: Double
    public let translationY: Double
    public let inset: Double
    public let bottom: Double
    public let bottomRadius: Double

    public init(top: Double, translationY: Double, inset: Double, bottom: Double, bottomRadius: Double) {
        self.top = top
        self.translationY = translationY
        self.inset = inset
        self.bottom = bottom
        self.bottomRadius = bottomRadius
    }
}

public struct RemoteSheetScrollState: Equatable, Sendable {
    public let top: Double
    public let scrollTop: Double

    public init(top: Double, scrollTop: Double) {
        self.top = top
        self.scrollTop = scrollTop
    }
}

public struct RemoteMotionPoint: Equatable, Sendable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

public enum RemoteSheetRules {
    public static let mobileMargin = 8.0

    public static func bottomMargin(safeBottom: Double = 0, mobile: Bool = false) -> Double {
        mobile ? mobileMargin : 16 + max(0, safeBottom.rounded())
    }

    public static func bounds(
        viewportHeight: Double,
        safeTop: Double = 0,
        bottomGap: Double = 16,
        compactRatio: Double = 0.44,
        contentHeight: Double? = nil
    ) -> RemoteSheetBounds {
        let expandedTop = max(0, safeTop.rounded())
        let maximumCompactHeight = (viewportHeight * compactRatio).rounded()
        let compactHeight = min(maximumCompactHeight, contentHeight?.rounded() ?? maximumCompactHeight)
        return .init(
            expandedTop: expandedTop,
            compactTop: max(expandedTop, viewportHeight - bottomGap - compactHeight),
            closedTop: viewportHeight + bottomGap
        )
    }

    public static func geometry(top: Double, bounds: RemoteSheetBounds) -> RemoteSheetGeometry {
        let distance = bounds.compactTop - bounds.expandedTop
        let progress = distance <= 0 ? 1 : min(1, max(0, (top - bounds.expandedTop) / distance))
        return .init(
            top: max(bounds.expandedTop, min(top, bounds.compactTop)),
            translationY: max(0, top - bounds.compactTop),
            inset: rounded(mobileMargin * progress),
            bottom: rounded(mobileMargin * progress),
            bottomRadius: rounded(32 * progress)
        )
    }

    public static func scrimOpacity(top: Double, bounds: RemoteSheetBounds, dark: Bool) -> Double {
        let compact = dark ? 0.18 : 0.06
        let expanded = dark ? 0.4 : 0.2
        if top >= bounds.compactTop {
            let distance = bounds.closedTop - bounds.compactTop
            let exit = distance <= 0 ? 1 : min(1, (top - bounds.compactTop) / distance)
            return rounded(compact * (1 - exit))
        }
        let distance = bounds.compactTop - bounds.expandedTop
        let progress = distance <= 0 ? 1 : min(1, max(0, (top - bounds.expandedTop) / distance))
        return rounded(expanded + (compact - expanded) * progress)
    }

    public static func axis(dx: Double, dy: Double, threshold: Double = 4) -> RemoteGestureAxis {
        if max(abs(dx), abs(dy)) < threshold { return .undecided }
        return abs(dx) > abs(dy) ? .horizontal : .vertical
    }

    public static func distribute(
        top: Double,
        scrollTop: Double,
        scrollMax: Double,
        delta: Double,
        bounds: RemoteSheetBounds
    ) -> RemoteSheetScrollState {
        let maximumScroll = max(0, scrollMax)
        if delta < 0 {
            let newTop = max(bounds.expandedTop, top + delta)
            let remainder = delta - (newTop - top)
            return .init(top: newTop, scrollTop: min(maximumScroll, scrollTop - remainder))
        }
        let consumed = min(max(0, scrollTop), delta)
        return .init(
            top: min(bounds.closedTop, top + delta - consumed),
            scrollTop: scrollTop - consumed
        )
    }

    public static func recentVelocity(
        points: [RemoteMotionPoint],
        now: Double,
        window: Double = 100,
        inactivity: Double = 50
    ) -> Double {
        guard let last = points.last, now - last.time <= inactivity else { return 0 }
        guard let first = points.first(where: { $0.time >= last.time - window }), first != last, first.time != last.time else { return 0 }
        return (last.value - first.value) / (last.time - first.time) * 1_000
    }

    public static func destination(top: Double, velocityY: Double, bounds: RemoteSheetBounds) -> RemoteSheetState {
        let projected = min(bounds.closedTop, max(bounds.expandedTop, top + velocityY * 0.14))
        if projected > (bounds.compactTop + bounds.closedTop) / 2 { return .closed }
        if projected < (bounds.expandedTop + bounds.compactTop) / 2 { return .expanded }
        return .compact
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}

public enum RemoteComposerState: Sendable { case compact, expanded }

public struct RemoteComposerInput: Equatable, Sendable {
    public let focused: Bool
    public let text: String
    public let hasAttachments: Bool
    public let hasActiveSecondaryState: Bool

    public init(focused: Bool, text: String, hasAttachments: Bool, hasActiveSecondaryState: Bool) {
        self.focused = focused
        self.text = text
        self.hasAttachments = hasAttachments
        self.hasActiveSecondaryState = hasActiveSecondaryState
    }
}

public struct RemoteNewSessionConfiguration: Equatable, Sendable {
    public let largePrompt: Bool
    public let initialLayout: Bool
    public let expandedAtRest: Bool

    public init(largePrompt: Bool, initialLayout: Bool, expandedAtRest: Bool) {
        self.largePrompt = largePrompt
        self.initialLayout = initialLayout
        self.expandedAtRest = expandedAtRest
    }
}

public enum RemoteComposerRules {
    public static let newSessionConfiguration = RemoteNewSessionConfiguration(
        largePrompt: false,
        initialLayout: true,
        expandedAtRest: true
    )

    public static func state(for input: RemoteComposerInput) -> RemoteComposerState {
        input.focused || !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.hasAttachments || input.hasActiveSecondaryState
            ? .expanded
            : .compact
    }
}

public enum RemoteSwipeAction: Sendable { case back, openSidebar, closeSidebar }

public enum RemoteSwipeRules {
    public static func returnPath(from path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts[0] == "code" || parts[0] == "agent" else { return nil }
        if parts[1] == "nouvelle" || (parts[1] == "session" && parts.count == 3) {
            return "/\(parts[0])"
        }
        return nil
    }

    public static func action(
        sidebarOpen: Bool,
        canGoBack: Bool,
        deltaX: Double,
        fast: Bool,
        threshold: Double
    ) -> RemoteSwipeAction? {
        if sidebarOpen { return deltaX < -threshold || (deltaX < -30 && fast) ? .closeSidebar : nil }
        guard deltaX > threshold || (deltaX > 30 && fast) else { return nil }
        return canGoBack ? .back : .openSidebar
    }
}

public enum RemoteCreationTitles {
    public static func keys(for mode: RemoteMode) -> [String] {
        let prefix = switch mode {
        case .code: "remoteNewTitleCode"
        case .agent: "remoteNewTitleAgent"
        case .chat: "remoteNewTitleChat"
        }
        return (1...5).map { "\(prefix)\($0)" }
    }

    public static func key(for mode: RemoteMode, draw: Double) -> String {
        let values = keys(for: mode)
        let index = min(values.count - 1, max(0, Int(floor(draw * Double(values.count)))))
        return values[index]
    }
}

public enum InterfaceLanguage: String, Sendable {
    case french = "fr"
    case english = "en"

    public static func defaultLanguage(preferred: [String]?) -> Self {
        for language in preferred ?? [] {
            let code = language.lowercased().split(separator: "-").first.map(String.init)
            if code == "fr" { return .french }
            if code == "en" { return .english }
        }
        return .english
    }
}
