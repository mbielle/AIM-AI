import AIMCore
import AIMApplication
import AIMMacPlatform
import Observation
import WebKit

@MainActor @Observable
final class BrowserPreviewSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var address = "http://localhost:3000"
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var errorMessage: String?
    private var privacyTask: Task<Void, Never>?
    private var privacyLease: AIMNativeNetworkLifetime?
    private var opaquePreviewToken: UUID?
    private var localPreviewTask: Task<Void, Never>?
    private var clearingNavigation: WKNavigation?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = !RuntimePrivacyPolicy.isApplicationNetworkBlocked
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        let changes = RuntimePrivacyPolicy.globalChanges()
        privacyTask = Task { [weak self] in
            for await enabled in changes where enabled {
                guard let self else { return }
                self.stop()
                self.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                self.clearingNavigation = self.webView.loadHTMLString(Self.offlineHTML(""), baseURL: nil)
                self.errorMessage = "Application private mode blocks web previews."
            }
        }
    }

    func loadAddress() {
        if RuntimePrivacyPolicy.isApplicationNetworkBlocked {
            guard let file = URL(string: address), file.isFileURL else {
                errorMessage = "Remote previews are disabled in application private mode. A local file URL can be rendered offline."; return
            }
            localPreviewTask?.cancel()
            localPreviewTask = Task { [weak self] in
                do {
                    let content = try await Task.detached {
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
                        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
                    }.value
                    guard !Task.isCancelled else { return }
                    self?.loadPrivatePreview(html: content)
                } catch { self?.errorMessage = "The local preview file could not be read (maximum 1 MiB)." }
            }
            return
        }
        guard let url = PreviewAddress.parse(address) else {
            errorMessage = "Enter an HTTP/HTTPS address or a localhost port (1–65535), without embedded credentials."
            return
        }
        if privacyLease == nil {
            do {
                privacyLease = try AIMNativeNetworkLifetime("WebKit preview NetworkProcess: native socket closure is not publicly acknowledged")
                opaquePreviewToken = privacyLease?.attach()
            }
            catch { errorMessage = error.localizedDescription; return }
        }
        errorMessage = nil
        address = url.absoluteString
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView.load(URLRequest(url: url))
    }

    func stop() { webView.stopLoading(); isLoading = false }

    /// Host-provided local text only: no remote fetch, base URL, JS, CSS URL,
    /// iframe or WebSocket can be started by this offline rendering.
    func loadPrivatePreview(html: String) {
        guard RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return }
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        clearingNavigation = webView.loadHTMLString(Self.offlineHTML(html), baseURL: nil)
    }
    private static func offlineHTML(_ content: String) -> String {
        "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"></head><body>" + content + "</body></html>"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if clearingNavigation != nil, navigationAction.request.url?.absoluteString == "about:blank" { return .allow }
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return .cancel }
        guard let url = navigationAction.request.url else { return .cancel }
        // Inline blank frames are common in development previews; never open them as a page.
        if url.absoluteString == "about:blank", navigationAction.targetFrame?.isMainFrame == false { return .allow }
        guard PreviewAddress.allows(url), !navigationAction.shouldPerformDownload else {
            errorMessage = "This preview only opens HTTP/HTTPS pages. External apps, local files and downloads are not opened automatically."
            return .cancel
        }
        if navigationAction.targetFrame == nil {
            if navigationAction.navigationType == .linkActivated {
                webView.load(navigationAction.request)
            } else { errorMessage = "This page requested a new window. Automatic pop-up windows are not opened." }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if clearingNavigation != nil, navigationResponse.response.url?.absoluteString == "about:blank" { return .allow }
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return .cancel }
        guard let url = navigationResponse.response.url, PreviewAddress.allows(url), navigationResponse.canShowMIMEType else {
            errorMessage = "This resource cannot be displayed in the preview. No download was started."
            isLoading = false
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true; errorMessage = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateNavigation() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false; updateNavigation()
        if let clearingNavigation, navigation === clearingNavigation, webView.url?.absoluteString == "about:blank" {
            self.clearingNavigation = nil
            // A blank page is not a native NetworkProcess socket close receipt.
            // Neither view disposal nor WebContent termination acknowledges the
            // separate NetworkProcess. Its lease remains held for this process.
            errorMessage = "This process used an opaque WebKit network preview. AIM cannot acknowledge its socket closure; private-mode commit is refused. Restart AIM before enabling private mode, and use local offline previews."
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        clearingNavigation = nil
        errorMessage = "The web preview process stopped. Reload the page to try again."
    }

    private func failed(_ error: Error) {
        isLoading = false; updateNavigation()
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        errorMessage = "The page could not be loaded. Check the address, network connection and whether the local development server is running."
    }
    private func updateNavigation() {
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if let url = webView.url, PreviewAddress.allows(url) { address = url.absoluteString }
    }
    isolated deinit { privacyTask?.cancel(); localPreviewTask?.cancel() }
}
