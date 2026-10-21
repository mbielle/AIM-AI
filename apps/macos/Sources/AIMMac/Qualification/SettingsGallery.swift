#if DEBUG
import AIMApplication
import AppKit
import Foundation

/// Debug-only visual check: `AIMMac --settings-gallery <folder> [--dark]` opens AIM on a
/// throwaway in-memory database (no user data, no keys), renders the sign-in screen and
/// every Settings page, saves one PNG per screen, then quits.
enum SettingsGallery {
    static func folder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--settings-gallery"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(into folder: URL, model: AppModel, dark: Bool) {
        // This unbundled debug binary has its own defaults domain, separate from the app's.
        UserDefaults.standard.set(dark ? "dark" : "light", forKey: AppearanceMode.storageKey)
        UserDefaults.standard.set(true, forKey: "aim.spend.onboardingShown")
        AuthenticatedUserSummary.galleryProfile = "Test"
        UserDefaults.standard.set(true, forKey: "aim.computerUse.onboardingShown")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // AIM_GALLERY_ONLY=chat,sidebar limits the run to some groups (all by default).
        let only = Set((ProcessInfo.processInfo.environment["AIM_GALLERY_ONLY"] ?? "").split(separator: ",").map(String.init))
        func wants(_ group: String) -> Bool { only.isEmpty || only.contains(group) }
        Task { @MainActor in
            AppearanceMode.apply()
            try? await Task.sleep(for: .seconds(3))
            let suffix = dark ? "-dark" : ""
            if wants("sidebar") { await GalleryFixtures.sidebar(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("profile") { await GalleryFixtures.profile(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("localsettings") { await GalleryFixtures.localSettings(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("customize") { await GalleryFixtures.customize(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("switching") { await GalleryFixtures.switching(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("chat") { await GalleryFixtures.chat(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("timeline") { await GalleryFixtures.timeline(model: model, folder: folder, suffix: suffix, capture: screenCapture) }
            if wants("dictation") {
                model.settingsSection = nil
                model.selectNewConversationMode(.chat)
                model.selectedModelID = "mlx-community/Qwen3-8B-4bit"
                try? await Task.sleep(for: .milliseconds(800))
                screenCapture(folder.appendingPathComponent("dictation-idle\(suffix).png"))
                model.debugDictation = "recording"
                for frame in 0..<4 {
                    try? await Task.sleep(for: .milliseconds(70))
                    screenCapture(folder.appendingPathComponent("dictation-recording-\(frame)\(suffix).png"))
                }
                for state in ["transcribing", "retry", "idle", "menu"] {
                    model.debugDictation = state
                    try? await Task.sleep(for: .milliseconds(state == "menu" ? 900 : 600))
                    screenCapture(folder.appendingPathComponent("dictation-\(state)\(suffix).png"))
                }
                model.debugDictation = "idle"
                try? await Task.sleep(for: .milliseconds(300))
            }
            if wants("media") {
                model.settingsSection = nil
                model.selectNewConversationMode(.chat)
                UserDefaults.standard.set(#"["openrouter:black-forest-labs/flux-3-image","openrouter:black-forest-labs/flux-3-video"]"#, forKey: "aim.models.added")
                model.connectedProviders.insert(.openRouter)
                model.showModelPicker = true
                try? await Task.sleep(for: .seconds(6))
                screenCapture(folder.appendingPathComponent("media-picker\(suffix).png"))
                model.debugOpenMenu = "picker-scroll-bottom"
                try? await Task.sleep(for: .seconds(1))
                screenCapture(folder.appendingPathComponent("media-picker-bottom\(suffix).png"))
                model.debugOpenMenu = nil
                model.openMediaCreator(preset: "black-forest-labs/flux-3-video")
                try? await Task.sleep(for: .seconds(3))
                screenCapture(folder.appendingPathComponent("media-create-video\(suffix).png"))
                model.showMediaCreator = false
                try? await Task.sleep(for: .milliseconds(600))
                model.openMediaCreator(preset: "black-forest-labs/flux-3-image")
                try? await Task.sleep(for: .seconds(2))
                screenCapture(folder.appendingPathComponent("media-create-image\(suffix).png"))
                model.showMediaCreator = false
                try? await Task.sleep(for: .milliseconds(600))
            }
            if wants("settings") {
            model.debugAccessOverride = .signInRequired
            try? await Task.sleep(for: .seconds(1))
            capture(folder.appendingPathComponent("signin\(suffix).png"))
            model.debugAccessOverride = nil
            for section in SettingsSection.allCases {
                model.settingsSection = section
                try? await Task.sleep(for: .milliseconds(1_200))
                capture(folder.appendingPathComponent("\(section.rawValue.replacingOccurrences(of: " ", with: "-"))\(suffix).png"))
            }
            logTopBarHitTest(folder)
            }
            if wants("home") {
            // The main screen and its menus (menus are separate panels: captured from the screen).
            model.settingsSection = nil
            model.selectNewConversationMode(.agent)
            try? await Task.sleep(for: .milliseconds(1_200))
            screenCapture(folder.appendingPathComponent("home-agent\(suffix).png"))
            model.selectNewConversationMode(.chat)
            try? await Task.sleep(for: .milliseconds(900))
            screenCapture(folder.appendingPathComponent("home-chat\(suffix).png"))
            model.selectNewConversationMode(.agent)
            try? await Task.sleep(for: .milliseconds(900))
            for menu in ["policies", "folders", "add", "spaces", "profile"] {
                model.debugOpenMenu = menu
                try? await Task.sleep(for: .milliseconds(900))
                screenCapture(folder.appendingPathComponent("menu-\(menu)\(suffix).png"))
                let panels = NSApp.windows.filter { $0.parent != nil }
                try? "\(panels.map { "\($0.windowNumber) visible=\($0.isVisible) \($0.frame)" })".write(to: folder.appendingPathComponent("panels-\(menu).txt"), atomically: true, encoding: .utf8)
                // Leaves time for an outside `screencapture -l <id>` of the menu panel alone.
                if menu == "policies" { try? await Task.sleep(for: .seconds(4)) }
                model.debugOpenMenu = nil
                try? await Task.sleep(for: .milliseconds(400))
            }
            model.composerText = "Plan my week from my calendar"
            try? await Task.sleep(for: .milliseconds(700))
            screenCapture(folder.appendingPathComponent("composer-text\(suffix).png"))
            model.composerText = ""
            }
            if wants("picker") {
            // OpenRouter's catalog is public, so the picker has real models without any key.
            model.connectedProviders.insert(.openRouter)
            model.showModelPicker = true
            try? await Task.sleep(for: .seconds(6))
            screenCapture(folder.appendingPathComponent("model-picker\(suffix).png"))
            for step in ["picker-add", "picker-detail", "section-providers", "section-uptime", "picker-local"] {
                model.debugOpenMenu = step
                try? await Task.sleep(for: .seconds(step == "picker-local" || step == "section-providers" ? 5 : 2))
                screenCapture(folder.appendingPathComponent("\(step)\(suffix).png"))
                model.debugOpenMenu = nil
            }
            model.showModelPicker = false
            }
            // The quit confirmation can hold a normal quit (and the main thread with it); this
            // throwaway debug run has nothing to save, so a background timer ends it regardless.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
            NSApp.terminate(nil)
        }
    }

    /// Which view receives a click on the top bar's sidebar button (it must not be the title bar).
    @MainActor
    private static func logTopBarHitTest(_ folder: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let frameView = window.contentView?.superview else { return }
        var lines: [String] = []
        for x in [30.0, 112, 169, 260] {
            let point = NSPoint(x: x, y: window.frame.height - 24)
            let hit = frameView.hitTest(frameView.convert(point, from: nil))
            lines.append("x=\(Int(x)): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("hittest.txt"), atomically: true, encoding: .utf8)
    }

    /// Draws the window and its child panels (menus, tooltips) into one image, from AIM's own
    /// views only: nothing else on the screen can end up in the file.
    @MainActor
    private static func screenCapture(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && $0.parent == nil }),
              let view = window.contentView?.superview else { return }
        let scale = window.backingScaleFactor
        let size = window.frame.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func draw(_ source: NSView, at origin: NSPoint) {
            guard let image = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return }
            source.cacheDisplay(in: source.bounds, to: image)
            image.draw(in: NSRect(origin: origin, size: source.bounds.size))
        }
        draw(view, at: .zero)
        var panels = window.childWindows ?? []
        if let sheet = window.attachedSheet { panels.append(sheet) }
        for child in panels where child.isVisible {
            guard let content = child.contentView else { continue }
            draw(content, at: NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    private static func capture(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
