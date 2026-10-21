import AIMCore
import AIMApplication
import AppKit
import CryptoKit
import Foundation

/// Observes mission success predicates on the host. The model never supplies
/// the observation; only a digest and a short summary are stored.
public struct MissionHostCheckRunner: MissionHostCheckRunning {
    public init() {}

    public func observe(_ check: MissionHostCheck, workspacePath: String?) async throws -> MissionCheckObservation {
        guard check.isValid else { throw AgentMissionError.invalidInput }
        switch check.kind {
        case .command: return try await command(check, workspacePath: workspacePath)
        case .web: return try await web(check)
        case .desktop: return try await desktop(check)
        }
    }

    // MARK: Command (argv, no shell, workspace directory, bounded time and output)

    private func command(_ check: MissionHostCheck, workspacePath: String?) async throws -> MissionCheckObservation {
        try RuntimePrivacyPolicy.requireNetwork()
        let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("mission verification command")
        defer { withExtendedLifetime(privacyLease) {} }
        guard let executable = check.executable, let workspacePath,
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentMissionError.invalidInput
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = check.arguments ?? []
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"].contains(key)
        }
        let collected = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        process.terminationHandler = { [privacyLease] _ in privacyLease.finish() }
        try process.run()
        let timeout = Double(check.timeoutSeconds ?? 120)
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date.now > deadline {
                process.terminate()
                output.fileHandleForReading.readabilityHandler = nil
                if Task.isCancelled { throw CancellationError() }
                return MissionCheckObservation(satisfied: false, digest: Self.digest("timeout"),
                    summary: "The command did not finish within \(Int(timeout)) seconds.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: collected.data, as: UTF8.self)
        let expected = check.expectedExitCode ?? 0
        let exitMatches = process.terminationReason == .exit && Int(process.terminationStatus) == expected
        let textMatches = check.requiredText.map { text.contains($0) } ?? true
        return MissionCheckObservation(satisfied: exitMatches && textMatches,
            digest: Self.digest("\(process.terminationStatus)\u{0}\(text)"),
            summary: "Exit status \(process.terminationStatus) (expected \(expected))" +
                (check.requiredText.map { textMatches ? "; output contains “\($0)”" : "; output lacks “\($0)”" } ?? "") +
                (collected.truncated ? "; output exceeded 1 MiB and was truncated" : ""))
    }

    // MARK: Web (no cookies, credentials or redirects)

    private func web(_ check: MissionHostCheck) async throws -> MissionCheckObservation {
        guard let raw = check.url, let url = URL(string: raw), let required = check.requiredText else {
            throw AgentMissionError.invalidInput
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Double(check.timeoutSeconds ?? 30)
        let delegate = NoRedirects()
        let session = RuntimeManagedNetworkSession.make(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentMissionError.invalidInput }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 1_048_576 { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        let found = (200..<300).contains(http.statusCode) && text.contains(required)
        return MissionCheckObservation(satisfied: found, digest: Self.digest("\(http.statusCode)\u{0}\(text)"),
            summary: "HTTP \(http.statusCode); page \(found ? "contains" : "does not contain") “\(required)”")
    }

    // MARK: Desktop (accessible text of one running application)

    private func desktop(_ check: MissionHostCheck) async throws -> MissionCheckObservation {
        guard let bundleID = check.bundleID, let required = check.requiredText else { throw AgentMissionError.invalidInput }
        guard let pid = await MainActor.run(body: {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }?.processIdentifier
        }) else {
            return MissionCheckObservation(satisfied: false, digest: Self.digest("not-running"),
                summary: "\(bundleID) is not running.")
        }
        let service = MacAccessibilityService()
        let nodes = try await service.readApplication(pid: pid, maximumNodes: 2_000)
        // Secure fields are redacted by the reader and never contribute text.
        let texts = nodes.filter { !$0.isSecure }.flatMap { [$0.title, $0.value].compactMap { $0 } }
        let windowOK: Bool
        if let fragment = check.windowTitleContains {
            windowOK = nodes.contains { $0.role == "AXWindow" && ($0.title ?? "").localizedCaseInsensitiveContains(fragment) }
        } else {
            windowOK = true
        }
        let found = windowOK && texts.contains { $0.contains(required) }
        return MissionCheckObservation(satisfied: found, digest: Self.digest(texts.joined(separator: "\u{0}")),
            summary: "\(bundleID): \(found ? "shows" : "does not show") “\(required)”" +
                (windowOK ? "" : " (no matching window)") + " in \(nodes.count) accessible nodes")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var overflow = false

    func append(_ data: Data) {
        lock.withLock {
            guard !data.isEmpty else { return }
            let room = 1_048_576 - buffer.count
            if room <= 0 { overflow = true; return }
            buffer.append(data.prefix(room))
            if data.count > room { overflow = true }
        }
    }

    var data: Data { lock.withLock { buffer } }
    var truncated: Bool { lock.withLock { overflow } }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
