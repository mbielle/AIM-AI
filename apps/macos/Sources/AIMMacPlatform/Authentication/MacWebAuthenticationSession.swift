import AIMCore
import AIMApplication
import AppKit
import AuthenticationServices
import Foundation

public enum MacWebAuthenticationError: Error, Equatable, Sendable {
    case cancelled
    case alreadyInProgress
    case couldNotStart
    case missingCallback
}

@MainActor
public protocol MacWebAuthenticating: AnyObject {
    func authenticate(at url: URL, callbackScheme: String) async throws -> URL
}

/// The system browser owns OAuth credentials; AIM receives only the callback.
@MainActor
public final class MacWebAuthenticationSession: NSObject, MacWebAuthenticating {
    private var currentSession: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?
    private var privacyTask: Task<Void, Never>?

    public override init() {
        super.init()
        let changes = RuntimePrivacyPolicy.globalChanges()
        privacyTask = Task { [weak self] in
            for await enabled in changes where enabled {
                self?.currentSession?.cancel()
                self?.finish(.failure(RuntimePrivacyError.externalAccessDisabled))
            }
        }
    }

    public func authenticate(at url: URL, callbackScheme: String) async throws -> URL {
        try RuntimePrivacyPolicy.requireApplicationNetwork()
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              callbackScheme == "aimmac" else { throw MacWebAuthenticationError.couldNotStart }
        guard pending == nil else { throw MacWebAuthenticationError.alreadyInProgress }
        guard !Task.isCancelled else { throw MacWebAuthenticationError.cancelled }
        let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("system OAuth browser session")
        defer { withExtendedLifetime(privacyLease) {} }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                    Task { @MainActor in
                        if let error = error as? ASWebAuthenticationSessionError,
                           error.code == .canceledLogin {
                            self?.finish(.failure(MacWebAuthenticationError.cancelled))
                        } else if error != nil {
                            self?.finish(.failure(MacWebAuthenticationError.couldNotStart))
                        } else if let callbackURL {
                            guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else {
                                self?.finish(.failure(RuntimePrivacyError.externalAccessDisabled)); return
                            }
                            self?.finish(.success(callbackURL))
                        } else {
                            self?.finish(.failure(MacWebAuthenticationError.missingCallback))
                        }
                    }
                }
                let session: ASWebAuthenticationSession
                if #available(macOS 14.4, *) {
                    session = ASWebAuthenticationSession(
                        url: url,
                        callback: .customScheme(callbackScheme),
                        completionHandler: completion
                    )
                } else {
                    session = ASWebAuthenticationSession(
                        url: url,
                        callbackURLScheme: callbackScheme,
                        completionHandler: completion
                    )
                }
                session.presentationContextProvider = self
                currentSession = session
                if Task.isCancelled {
                    finish(.failure(MacWebAuthenticationError.cancelled))
                } else if !session.start() {
                    finish(.failure(MacWebAuthenticationError.couldNotStart))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.currentSession?.cancel()
                self?.finish(.failure(MacWebAuthenticationError.cancelled))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let pending else { return }
        self.pending = nil
        currentSession = nil
        pending.resume(with: result)
    }
    isolated deinit { privacyTask?.cancel() }
}

extension MacWebAuthenticationSession: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}
