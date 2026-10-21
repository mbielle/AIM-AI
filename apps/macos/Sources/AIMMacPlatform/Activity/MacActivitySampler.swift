import AIMApplication
import AppKit
import Foundation
import ApplicationServices

public struct ActivitySample: Sendable {
    public var application: String
    public var title: String
    public var url: String?
    public var isPrivate: Bool

    public init(application: String, title: String, url: String?, isPrivate: Bool) {
        self.application = application
        self.title = title
        self.url = url
        self.isPrivate = isPrivate
    }
}

public protocol ActivitySampling: Sendable {
    func sample(settings: ActivitySettings) async -> ActivitySample?
}

public actor MacActivitySampler: ActivitySampling {
    public init() {}

    public func sample(settings: ActivitySettings) -> ActivitySample? {
        guard settings.isEnabled, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        // A browser's private mode cannot be inferred reliably from window titles.
        // Until we have a verified browser-specific signal, record no browser session.
        guard Self.permitsApplication(bundleIdentifier: app.bundleIdentifier, name: application) else { return nil }
        // Read metadata only from the current focused window when AX is already
        // allowed. Never traverse fields, capture pixels or prompt for access here.
        let metadata = Self.focusedMetadata(pid: app.processIdentifier)
        let title = metadata.title
        let url: String? = metadata.document
        let isPrivate = false
        guard !ActivityPrivacyPolicy.shouldExclude(
            application: application,
            title: title,
            url: url,
            isPrivate: isPrivate,
            settings: settings
        ) else { return nil }
        return ActivitySample(application: application, title: title, url: url, isPrivate: isPrivate)
    }
    private static func focusedMetadata(pid: pid_t) -> (title: String, document: String?) {
        guard AXIsProcessTrusted() else { return ("", nil) }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return ("", nil) }
        let window = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.2)
        var title: CFTypeRef?, document: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        _ = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document)
        let name = (title as? String).map { String($0.prefix(512)) } ?? ""
        let source = document as? String
        return (name, source.flatMap { $0.utf8.count <= 2048 ? $0 : nil })
    }

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.canary", "com.brave.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "company.thebrowser.Browser",
    ]
    private static let browserNames: Set<String> = [
        "safari", "safari technology preview", "google chrome", "google chrome canary",
        "brave browser", "firefox", "microsoft edge", "arc", "opera", "vivaldi", "tor browser",
    ]

    public static func permitsApplication(bundleIdentifier: String?, name: String) -> Bool {
        !browserBundleIDs.contains(bundleIdentifier ?? "") && !browserNames.contains(name.lowercased())
    }
}

public actor ActivityTracker {
    private let sampler: any ActivitySampling
    private let repository: any ActivityRepository
    private var current: (sample: ActivitySample, startedAt: Date, lastSeenAt: Date)?

    public init(sampler: any ActivitySampling, repository: any ActivityRepository) {
        self.sampler = sampler
        self.repository = repository
    }

    public func tick(settings: ActivitySettings, now: Date = .now) async throws {
        guard settings.isEnabled else { discard(); return }
        if let current, ActivityPrivacyPolicy.shouldExclude(application: current.sample.application,
            title: current.sample.title, url: current.sample.url, isPrivate: current.sample.isPrivate, settings: settings) {
            discard()
        }
        guard let sample = await sampler.sample(settings: settings),
              !ActivityPrivacyPolicy.shouldExclude(
                application: sample.application, title: sample.title, url: sample.url,
                isPrivate: sample.isPrivate, settings: settings
              ) else {
            try Task.checkCancellation()
            try await flush(now: now)
            return
        }
        try Task.checkCancellation()
        if let current,
           current.sample.application == sample.application,
           current.sample.title == sample.title,
           current.sample.url == sample.url {
            self.current?.lastSeenAt = now
            return
        }
        try await flush(now: now)
        current = (sample, now, now)
    }

    public func stop(now: Date = .now) async throws { try await flush(now: now) }
    public func discard() { current = nil }

    private func flush(now: Date) async throws {
        guard let current else { return }
        self.current = nil
        guard current.lastSeenAt.timeIntervalSince(current.startedAt) >= 5 else { return }
        try await repository.record(ActivityEntry(
            application: current.sample.application,
            title: current.sample.title,
            url: current.sample.url,
            startedAt: current.startedAt,
            endedAt: max(current.lastSeenAt, now)
        ))
    }
}
