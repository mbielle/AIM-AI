import AuthenticationServices
import UIKit
import SwiftUI

enum WebAuthenticationError: LocalizedError, Equatable {
    case cancelled
    case couldNotStart
    case missingCallback

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled. You can try again."
        case .couldNotStart: return "The sign-in browser could not open. Keep AIM in the foreground and try again."
        case .missingCallback: return "The sign-in response was missing or invalid. Please start sign-in again."
        }
    }
}

@MainActor
protocol WebAuthenticationServicing: AnyObject {
    func authenticate(
        at url: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL
}

@MainActor
final class ASWebAuthenticationSessionClient: NSObject, WebAuthenticationServicing {
    private var currentSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestID: UUID?
    private weak var initiatingWindow: UIWindow?
    private var activeWindow: UIWindow?

    /// Capture the actual presenting page's window, rather than another scene's key window.
    func setPresentationWindow(_ window: UIWindow?) {
        initiatingWindow = window
    }

    @available(iOS 17.4, *)
    func authenticateHTTPS(at url: URL, host: String, path: String) async throws -> URL {
        let callback = try await authenticateSession {
            ASWebAuthenticationSession(url: url, callback: .https(host: host, path: path), completionHandler: $0)
        }
        guard callback.scheme == "https", callback.host == host, callback.path == path,
              callback.user == nil, callback.password == nil else { throw WebAuthenticationError.missingCallback }
        return callback
    }

    func authenticate(at url: URL, callbackScheme: String, prefersEphemeralSession: Bool) async throws -> URL {
        try await authenticateSession { completion in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            return session
        }
    }

    private func authenticateSession(
        makeSession: (@escaping ASWebAuthenticationSession.CompletionHandler) -> ASWebAuthenticationSession
    ) async throws -> URL {
        guard currentSession == nil else { throw WebAuthenticationError.couldNotStart }
        try Task.checkCancellation()
        guard let window = initiatingWindow ?? Self.foregroundPresentationWindow() else {
            throw WebAuthenticationError.couldNotStart
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                requestID = id
                activeWindow = window
                let session = makeSession { [weak self] callback, error in
                    Task { @MainActor in
                        self?.finish(id: id, result: Self.authenticationResult(callback: callback, error: error))
                    }
                }
                session.presentationContextProvider = self
                currentSession = session
                if !session.start() { finish(id: id, result: .failure(WebAuthenticationError.couldNotStart)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id else { return }
                self.currentSession?.cancel()
                self.finish(id: id, result: .failure(WebAuthenticationError.cancelled))
            }
        }
    }

    /// Cancellation, start failure and a missing callback are different user-visible states.
    static func authenticationResult(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let authenticationError = error as? ASWebAuthenticationSessionError,
           authenticationError.code == .canceledLogin {
            return .failure(WebAuthenticationError.cancelled)
        }
        if error != nil { return .failure(WebAuthenticationError.couldNotStart) }
        if let callback { return .success(callback) }
        return .failure(WebAuthenticationError.missingCallback)
    }

    private func finish(id: UUID, result: Result<URL, Error>) {
        guard requestID == id, let continuation else { return }
        self.continuation = nil
        requestID = nil
        currentSession = nil
        activeWindow = nil
        continuation.resume(with: result)
    }

    private static func foregroundPresentationWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow && !$0.isHidden }
    }
}

extension ASWebAuthenticationSessionClient: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A session is never started without its real window, held for the session lifetime.
        precondition(activeWindow != nil, "Authentication requires an active presentation window")
        return activeWindow!
    }
}

private struct WebAuthenticationWindowReader: UIViewRepresentable {
    let client: ASWebAuthenticationSessionClient
    final class WindowView: UIView {
        weak var client: ASWebAuthenticationSessionClient?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { client?.setPresentationWindow(window) }
        }
    }
    func makeUIView(context: Context) -> WindowView {
        let view = WindowView()
        view.isUserInteractionEnabled = false
        view.client = client
        return view
    }
    func updateUIView(_ view: WindowView, context: Context) {
        view.client = client
        if let window = view.window { client.setPresentationWindow(window) }
    }
}

extension View {
    func webAuthenticationPresentationAnchor(_ client: ASWebAuthenticationSessionClient) -> some View {
        background(WebAuthenticationWindowReader(client: client).frame(width: 0, height: 0))
    }
}
