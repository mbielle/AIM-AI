import AppKit

/// Dedicated, disposable UI for desktop-driver qualification. No user documents,
/// network calls or persistent user data. Its state file is ground truth that is
/// independent of both AIM's accessibility reads and the driver's own claims.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let commandNotification = Notification.Name("com.aimai.macos.agent-fixture.command")

    private var windows: [NSWindow] = []
    private let countLabel = NSTextField(labelWithString: "Count: 0")
    private let field = NSTextField(string: "Fixture text — é à 日本語")
    private let secure = NSSecureTextField(string: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let keyView = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var count = 0
    private var activations = 0
    private var keyWindowChanges = 0
    private var deminiaturizations = 0
    private var unhides = 0
    private let statePath: URL

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--state-file"), index + 1 < arguments.count {
            statePath = URL(fileURLWithPath: arguments[index + 1])
        } else {
            statePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("aim-agent-fixture", isDirectory: true)
                .appendingPathComponent("state.json")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let first = makeWindow(frame: NSRect(x: 160, y: 200, width: 560, height: 520))
        field.setAccessibilityIdentifier("fixture.text")
        field.setAccessibilityLabel("Fixture editable text")
        field.target = self
        field.action = #selector(textChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged),
            name: NSControl.textDidChangeNotification, object: field)
        secure.setAccessibilityIdentifier("fixture.secure")
        secure.setAccessibilityLabel("Fixture secure field")
        secure.placeholderString = "Secure field (agents must refuse)"
        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.setAccessibilityIdentifier("fixture.increment")
        countLabel.setAccessibilityIdentifier("fixture.count")
        slider.setAccessibilityIdentifier("fixture.slider")
        slider.setAccessibilityLabel("Fixture slider")
        slider.target = self
        slider.action = #selector(sliderChanged)
        keyView.setAccessibilityIdentifier("fixture.keys")
        keyView.onKey = { [weak self] key in self?.writeState(lastKey: key) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.title = "Row"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("fixture.list")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityIdentifier("fixture.scroll")
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        let note = NSTextField(wrappingLabelWithString: "Disposable AIM agent fixture. Both large windows share the same title. No action here affects user documents.")
        let stack = NSStackView(views: [note, field, secure, button, countLabel, slider, keyView, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        first.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: first.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: first.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: first.contentView!.topAnchor, constant: 24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let second = makeWindow(frame: NSRect(x: 760, y: 200, width: 320, height: 200))
        second.contentView = NSTextField(wrappingLabelWithString: "Second window, same title. The agent must distinguish it by identity and geometry.")
        let tiny = NSWindow(contentRect: NSRect(x: 160, y: 760, width: 70, height: 45),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        tiny.title = "Tiny fixture"
        tiny.isReleasedWhenClosed = false
        tiny.contentView = NSTextField(labelWithString: "Small")
        windows.append(tiny)
        // Qualification runs while the user keeps working on any Space; AX only
        // lists windows on the current Space, so the fixture joins all of them.
        if ProcessInfo.processInfo.arguments.contains("--all-spaces") { setAllSpaces(true) }
        for window in windows { window.orderFront(nil) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(unhid), name: NSApplication.didUnhideNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(deminiaturized), name: NSWindow.didDeminiaturizeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(command(_:)),
            name: Self.commandNotification, object: nil, suspensionBehavior: .deliverImmediately)
        writeState()
    }

    private func setAllSpaces(_ enabled: Bool) {
        for window in windows {
            if enabled {
                window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            } else {
                window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            }
        }
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AIM Agent Fixture"
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 100 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "Row \(row)")
    }

    @objc private func increment() {
        count += 1
        countLabel.stringValue = "Count: \(count)"
        writeState()
    }

    @objc private func textChanged() { writeState() }
    @objc private func sliderChanged() { writeState() }
    @objc private func scrolled() { writeState() }
    @objc private func activated() { activations += 1; writeState() }
    @objc private func unhid() { unhides += 1; writeState() }
    @objc private func deminiaturized() { deminiaturizations += 1; writeState() }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.didBecomeKeyNotification { keyWindowChanges += 1 }
        writeState()
    }

    /// Qualification commands; the fixture only changes its own windows.
    @objc private func command(_ notification: Notification) {
        guard let command = notification.userInfo?["command"] as? String else { return }
        let main = windows.first
        switch command {
        case "minimize": main?.miniaturize(nil)
        case "unminimize": main?.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhide(nil)
        case "offscreen": main?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        case "onscreen": main?.setFrameOrigin(NSPoint(x: 160, y: 200))
        case "fullscreen": main?.toggleFullScreen(nil)
        case "overlap": windows.dropFirst().first?.setFrameOrigin(main?.frame.origin ?? .zero)
        case "front": for window in windows { window.orderFront(nil) }
        // One eligible window lets process-scoped key events be attributed exactly.
        case "solo": for window in windows.dropFirst() { window.orderOut(nil) }
        case "all-spaces-on": setAllSpaces(true)
        case "all-spaces-off": setAllSpaces(false)
        case "reset":
            count = 0
            countLabel.stringValue = "Count: 0"
            field.stringValue = "Fixture text — é à 日本語"
            secure.stringValue = ""
            slider.doubleValue = 0
            table.scrollRowToVisible(0)
            activations = 0; keyWindowChanges = 0; deminiaturizations = 0; unhides = 0
            keyView.lastKey = ""
        default: return
        }
        writeState()
    }

    private func writeState(lastKey: String? = nil) {
        if let lastKey { keyView.lastKey = lastKey }
        let firstVisibleRow = table.rows(in: scroll.contentView.bounds).location
        let state: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "count": count,
            "text": field.stringValue,
            "secure_length": secure.stringValue.count,
            "slider": slider.doubleValue,
            "first_visible_row": firstVisibleRow,
            "last_key": keyView.lastKey,
            "activations": activations,
            "key_window_changes": keyWindowChanges,
            "deminiaturizations": deminiaturizations,
            "unhides": unhides,
            "is_active": NSApp.isActive,
            "is_hidden": NSApp.isHidden,
            "windows": windows.map { window in
                ["number": window.windowNumber, "title": window.title,
                 "x": window.frame.origin.x, "y": window.frame.origin.y,
                 "width": window.frame.width, "height": window.frame.height,
                 "visible": window.isVisible, "miniaturized": window.isMiniaturized,
                 "on_active_space": window.isOnActiveSpace, "key": window.isKeyWindow] as [String: Any]
            },
            "written_at": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: statePath, options: [.atomic])
    }
}

/// Records the last key it receives so key delivery can be verified.
final class KeyCaptureView: NSView {
    var lastKey = ""
    var onKey: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        lastKey = event.charactersIgnoringModifiers ?? ""
        onKey?(lastKey)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondarySystemFill.setFill()
        bounds.fill()
        ("Key capture: " + lastKey as NSString).draw(at: NSPoint(x: 6, y: 6), withAttributes: nil)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Fixture key capture" }
    override func accessibilityValue() -> Any? { lastKey }
}

@main
struct AgentFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
