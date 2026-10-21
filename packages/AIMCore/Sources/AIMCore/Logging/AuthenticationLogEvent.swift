/// Closed, non-sensitive authentication events. Free-form values are intentionally excluded so
/// tokens, email addresses and provider responses cannot be written to logs accidentally.
public enum AuthenticationLogEvent: String, Sendable {
    case restorationStarted
    case restorationFinished
    case signedIn
    case signedOut
    case callbackRejected
}
