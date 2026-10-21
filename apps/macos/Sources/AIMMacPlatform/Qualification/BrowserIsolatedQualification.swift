#if DEBUG
import AIMAgentKit
import Foundation
import Network

/// Real-browser qualification of AIM's browser tools on a local fixture page,
/// in an isolated headless Chrome: navigation, observation leases, click, typing,
/// dialog, file upload, console, network, screenshot and stale references.
public enum BrowserIsolatedQualification {
    static let page = """
    <!doctype html>
    <html lang="fr"><meta charset="utf-8"><title>AIM fixture</title>
    <body><h1>Fixture locale AIM</h1>
    <label>Texte <input id="text" value=""></label>
    <button id="increment" type="button">Incrémenter</button><output id="count">0</output>
    <button type="button" id="dialog">Ouvrir un dialogue</button>
    <label>Pièce jointe locale <input id="file" type="file"></label>
    <script>
    let count = 0;
    console.log('AIM console marker');
    document.querySelector('#increment').onclick = () => {
      document.querySelector('#count').textContent = String(++count);
      document.title = 'Count ' + count;
    };
    document.querySelector('#text').oninput = (e) => { document.title = 'Text ' + e.target.value; };
    document.querySelector('#dialog').onclick = () => { alert('Dialogue de test AIM'); document.title = 'Dialog closed'; };
    document.querySelector('#file').onchange = (e) => { document.title = 'File ' + (e.target.files[0]?.name ?? ''); };
    </script>
    </body></html>
    """

    /// `extensionMode` runs the same cases in the person's Chrome through the
    /// Playwright extension (token from the Keychain), in a dedicated new tab
    /// that is closed at the end; the person's other tabs are not touched.
    public static func run(into report: QualificationReport, extensionMode: Bool = false) async {
        let token = extensionMode ? (try? AgentBrowserPreferences.readToken()) ?? nil : nil
        if extensionMode && token == nil {
            report.set("conclusion", "No Playwright extension token in the Keychain; enter it in AIM's Computer Use window.")
            return
        }
        let server: FixtureHTTPServer
        do { server = try await FixtureHTTPServer.start(page: page) } catch {
            report.set("conclusion", "Local fixture server failed: \(error)")
            return
        }
        defer { server.stop() }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-browser-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let upload = workspace.appendingPathComponent("upload.txt")
        try? "AIM upload fixture\n".write(to: upload, atomically: true, encoding: .utf8)
        let sessionDirectory = extensionMode ? nil : AgentBrowserPreferences.sessionDirectory()
        let service = AgentBrowserToolService(configuration: extensionMode
            ? AgentBrowserConfiguration(mode: .extensionConnected, extensionToken: token, workspace: workspace)
            : AgentBrowserConfiguration(mode: .isolated, outputDirectory: sessionDirectory, workspace: workspace, headless: true))
        let url = "http://127.0.0.1:\(server.port)/fixture.html"
        var cases: [String: Bool] = [:]
        var notes: [String: String] = [:]

        func call(_ name: String, _ arguments: [String: String], risk: ToolRisk = .computerAction) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: risk, workspacePath: workspace.path))
        }
        func snapshot() async -> (id: String?, text: String) {
            let result = await call("browser_snapshot", [:], risk: .computerRead)
            return (result.metadata["observation_id"], result.content)
        }
        func ref(_ role: String, _ name: String, in text: String) -> String? {
            let pattern = "\(role) \"\(NSRegularExpression.escapedPattern(for: name))\"[^\\n]*\\[ref=([a-z0-9]+)\\]"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        func title(_ text: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("- Page Title: ") }.map { String($0.dropFirst(14)) }
        }

        if extensionMode {
            report.set("token_shape", AgentBrowserPreferences.tokenShape())
            let opened = await call("browser_tabs", ["action": "new", "url": url])
            cases["extension_connected_new_tab"] = !opened.isError
            notes["new_tab"] = String(opened.content.prefix(300))
            if opened.metadata["browser_connection_failed"] == "true" {
                // Do not open the connect page again for every remaining case.
                await service.closeSession()
                report.set("cases", cases)
                report.set("notes", notes)
                report.set("conclusion", "failed: the Chrome extension did not accept the connection (see notes.new_tab and token_shape)")
                return
            }
        }
        let navigated = await call("browser_navigate", ["url": url])
        cases["navigate"] = !navigated.isError
        notes["navigate"] = String(navigated.content.prefix(300))
        var observed = await snapshot()
        cases["snapshot_has_observation"] = observed.id != nil && observed.text.contains("Fixture locale AIM")
        notes["snapshot_excerpt"] = String(observed.text.prefix(1_200))

        if let id = observed.id, let button = ref("button", "Incrémenter", in: observed.text) {
            let clicked = await call("browser_click", ["target": button, "observation_id": id, "element": "Incrémenter"])
            observed = await snapshot()
            cases["click_effect"] = !clicked.isError && title(observed.text) == "Count 1"
            // The observation used for the click was retired by the action.
            let stale = await call("browser_click", ["target": button, "observation_id": id])
            cases["stale_observation_refused"] = stale.isError && stale.metadata["stale_browser_target"] == "true"
        }
        if let id = observed.id, let field = ref("textbox", "Texte", in: observed.text) {
            let typed = await call("browser_type", ["target": field, "text": "é à 日本語", "observation_id": id])
            observed = await snapshot()
            cases["type_effect"] = !typed.isError && title(observed.text) == "Text é à 日本語"
        }
        if let id = observed.id, let button = ref("button", "Ouvrir un dialogue", in: observed.text) {
            let opened = await call("browser_click", ["target": button, "observation_id": id])
            let handled = await call("browser_handle_dialog", ["accept": "true"])
            observed = await snapshot()
            cases["dialog_handled"] = (opened.content.contains("dialog") || !opened.isError) && !handled.isError &&
                title(observed.text) == "Dialog closed"
            notes["dialog"] = String(handled.content.prefix(300))
        }
        if let id = observed.id, let chooser = ref("button", "Pièce jointe locale", in: observed.text) ??
            ref("button", "Choose File", in: observed.text) ?? ref("button", "Choisir un fichier", in: observed.text) {
            _ = await call("browser_click", ["target": chooser, "observation_id": id])
            let uploaded = await call("browser_file_upload", ["paths": "[\"\(upload.path)\"]"])
            notes["upload"] = String(uploaded.content.prefix(300))
            if uploaded.isError {
                // Leave no chooser open: it would block every following case.
                let cancelled = await call("browser_file_upload", [:])
                cases["file_chooser_cancelled"] = !cancelled.isError
            }
            observed = await snapshot()
            if extensionMode && uploaded.isError && uploaded.content.contains("Not allowed") {
                // Chrome refuses file input to an extension without "Allow access to file URLs".
                report.set("limitations", ["file_upload": "needs the Playwright extension's \"Allow access to file URLs\" setting in chrome://extensions"])
            } else {
                cases["file_upload"] = !uploaded.isError && title(observed.text) == "File upload.txt"
            }
        } else {
            cases["file_upload"] = false
            notes["upload"] = "file chooser reference not found"
        }
        let outside = await call("browser_file_upload", ["paths": "[\"/etc/hosts\"]"])
        cases["upload_outside_workspace_refused"] = outside.isError
        let console = await call("browser_console_messages", ["level": "info"], risk: .sensitiveRead)
        cases["console"] = !console.isError && console.content.contains("AIM console marker")
        notes["console"] = String(console.content.prefix(800))
        let network = await call("browser_network_requests", ["static": "true"], risk: .sensitiveRead)
        cases["network"] = !network.isError && network.content.contains("/fixture.html")
        notes["network"] = String(network.content.prefix(800))
        let screenshot = await call("browser_take_screenshot", [:], risk: .computerRead)
        cases["screenshot_pixels"] = !screenshot.isError && screenshot.imagePNG != nil
        let blocked = await call("browser_navigate", ["url": "file:///etc/hosts"])
        cases["file_url_refused"] = blocked.isError
        if extensionMode {
            // Close only the dedicated fixture tab.
            let listing = await call("browser_tabs", ["action": "list"], risk: .computerRead)
            let line = listing.content.split(separator: "\n").first { $0.contains("127.0.0.1:\(server.port)") }
            let index = line.flatMap { text in text.range(of: #"\d+"#, options: .regularExpression).map { String(text[$0]) } }
            if let index {
                let closed = await call("browser_tabs", ["action": "close", "index": index])
                cases["dedicated_tab_closed"] = !closed.isError
            } else {
                cases["dedicated_tab_closed"] = false
                notes["tab_listing"] = String(listing.content.prefix(600))
            }
        }
        await service.closeSession()
        if let sessionDirectory {
            let recorded = (try? FileManager.default.subpathsOfDirectory(atPath: sessionDirectory.path)) ?? []
            notes["session_records"] = "\(recorded.count) files"
        }
        report.set("cases", cases)
        report.set("notes", notes)
        let failed = cases.filter { !$0.value }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all browser cases passed (\(cases.count))" :
            "failed: \(failed.joined(separator: ", "))")
    }
}

/// Minimal loopback HTTP server for the fixture page (GET only, no file access).
final class FixtureHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(page: String) async throws -> FixtureHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let body = Data(page.utf8)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let found = request.hasPrefix("GET /fixture.html")
                let payload = found ? body : Data("not found".utf8)
                var header = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\n"
                header += "Content-Type: \(found ? "text/html; charset=utf-8" : "text/plain")\r\n"
                header += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return FixtureHTTPServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() -> Bool { lock.withLock { if value { return false }; value = true; return true } }
}
#endif
