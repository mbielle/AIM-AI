import AIMAgentKit
import AIMApplication
import AIMCore
import Foundation

/// Any scriptable app through AppleScript (Otto's macos_osascript), for what the
/// dedicated tools do not cover. Always an exact approval showing the full
/// script; macOS also asks once per target app (Automation).
public actor AgentAppleScriptToolService: ToolExecutor, ToolReviewProviding {
    public nonisolated let supportedTools: Set<String> = ["run_applescript"]
    public init() {}

    public func review(_ request: ToolRequest) async throws -> ToolReview? {
        guard let script = request.arguments["script"] else { return nil }
        return ToolReview(path: "AppleScript (runs with AIM's permissions)", before: "", after: script)
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let script = request.arguments["script"], !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              script.utf8.count <= 50_000 else {
            return ToolResult(requestID: request.id, content: "Provide an AppleScript of at most 50 KB.", isError: true)
        }
        let timeout = min(max(Int(request.arguments["timeout_seconds"] ?? "") ?? 30, 5), 120)
        let outcome = await Self.run(script, timeoutSeconds: timeout)
        switch outcome {
        case .success(let text):
            var result = ToolResult(requestID: request.id, content: text.isEmpty ? "The script ran (no result)." : String(text.prefix(60_000)))
            result.actionOutcome = .unverified
            return result
        case .failure(let error):
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    /// Runs an AppleScript off the main thread and returns its result as text.
    public nonisolated static func run(_ script: String, timeoutSeconds: Int) async -> Result<String, Error> {
        let lease: AIMNetworkPrivacyLease
        do {
            try RuntimePrivacyPolicy.requireNetwork()
            lease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation()
        } catch { return .failure(error) }
        let source = "with timeout of \(timeoutSeconds) seconds\n\(script)\nend timeout"
        return await Task.detached(priority: .userInitiated) { [lease] () -> Result<String, Error> in
            defer { withExtendedLifetime(lease) {} }
            guard let compiled = NSAppleScript(source: source) else { return .failure(ScriptError.compile) }
            var error: NSDictionary?
            let descriptor = compiled.executeAndReturnError(&error)
            if let error {
                return .failure(ScriptError.execution((error["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript failed"))
            }
            return .success(Self.render(descriptor))
        }.value
    }

    nonisolated static func render(_ descriptor: NSAppleEventDescriptor) -> String {
        if descriptor.numberOfItems > 0 {
            return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0).map(render) }.joined(separator: "\n")
        }
        return descriptor.stringValue ?? ""
    }

    enum ScriptError: LocalizedError {
        case compile, execution(String)
        var errorDescription: String? {
            switch self {
            case .compile: "The AppleScript does not compile."
            case .execution(let message): "AppleScript error: \(message)"
            }
        }
    }
}
