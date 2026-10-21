import Foundation

enum NetworkErrorClassifier {
    static func isConnectivityFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }
}
