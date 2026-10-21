import AIMCore
import Foundation

/// API endpoints are explicit. Never forward provider-specific credentials
/// through a redirect, including custom x-api-key headers.
private final class RejectAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderHTTPSession {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        return RuntimeManagedNetworkSession.make(configuration: configuration, delegate: RejectAPIRedirects(), delegateQueue: nil)
    }
}
