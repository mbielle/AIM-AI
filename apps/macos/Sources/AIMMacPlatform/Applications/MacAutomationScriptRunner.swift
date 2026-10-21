import Foundation

/// Serializes all in-process AppleScript use across typed app adapters.
/// The model never supplies either the script or its helper definitions.
protocol MacAutomationScriptRunning: Sendable {
    func run(_ script: String, helpers: String, timeoutSeconds: Int) async throws -> [[String]]
}

actor SystemMacAutomationScriptRunner: MacAutomationScriptRunning {
    static let shared = SystemMacAutomationScriptRunner()

    func run(_ script: String, helpers: String, timeoutSeconds: Int) throws -> [[String]] {
        guard (5...120).contains(timeoutSeconds), script.utf8.count <= 200_000,
              helpers.utf8.count <= 20_000 else { throw MacAutomationScriptError.invalidScript }
        let source = "\(helpers)\nwith timeout of \(timeoutSeconds) seconds\n\(script)\nend timeout"
        guard let compiled = NSAppleScript(source: source) else { throw MacAutomationScriptError.invalidScript }
        var error: NSDictionary?
        let descriptor = compiled.executeAndReturnError(&error) as NSAppleEventDescriptor?
        if let error {
            let message = (error["NSAppleScriptErrorMessage"] as? String) ?? "Apple Events failed"
            throw MacAutomationScriptError.execution(String(message.prefix(1_000)))
        }
        guard let descriptor, descriptor.numberOfItems <= 201 else {
            throw MacAutomationScriptError.invalidReply
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        var rows: [[String]] = []
        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index), (1...16).contains(row.numberOfItems) else {
                throw MacAutomationScriptError.invalidReply
            }
            var values: [String] = []
            for field in 1...row.numberOfItems {
                guard let value = row.atIndex(field)?.stringValue,
                      value.utf8.count <= 1_000_000 else { throw MacAutomationScriptError.invalidReply }
                values.append(value)
            }
            rows.append(values)
        }
        return rows
    }
}

enum MacAutomationScriptError: LocalizedError {
    case invalidScript, invalidReply, execution(String)

    var errorDescription: String? {
        switch self {
        case .invalidScript: "AIM could not prepare the fixed macOS Automation operation."
        case .invalidReply: "The automated macOS app returned an unexpected result. Inspect it before retrying a mutation."
        case let .execution(message):
            "macOS Automation failed: \(message). Check Privacy & Security → Automation for the signed AIM app."
        }
    }
}
