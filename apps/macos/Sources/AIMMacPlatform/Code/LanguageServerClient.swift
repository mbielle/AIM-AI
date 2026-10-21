import AIMCore
import AIMApplication
import Foundation
import Darwin

/// Minimal Language Server Protocol client over stdio (JSON-RPC with
/// Content-Length framing): requests with timeouts, and the diagnostics the
/// server publishes per document.
final class LanguageServerClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case launch(String), timeout(String), server(String), closed
        var errorDescription: String? {
            switch self {
            case .launch(let detail): "The language server could not start: \(detail)"
            case .timeout(let method): "The language server did not answer \(method) in time."
            case .server(let message): "The language server reported: \(message)"
            case .closed: "The language server stopped."
            }
        }
    }

    private let process = Process()
    private var privacyLease: AIMNetworkPrivacyLease?
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var diagnostics: [String: [[String: Any]]] = [:]
    private var diagnosticWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var closed = false

    init(command: [String], workspace: URL) throws {
        try RuntimePrivacyPolicy.requireNetwork()
        privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("language server stdio helper")
        guard let executable = command.first else { throw ClientError.launch("no command") }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        // A server may close stdin before termination/EOF reaches our callbacks.
        // Protect this descriptor, not the process-wide signal disposition.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClientError.launch("could not configure server input")
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.finish(); return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self, privacyLease] _ in
            privacyLease?.finish()
            self?.finish()
            self?.lock.withLock { self?.privacyLease = nil }
        }
        do { try process.run() } catch { throw ClientError.launch(error.localizedDescription) }
    }

    deinit { stop() }

    func stop() {
        lock.withLock { closed = true }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        finish()
    }

    // MARK: Requests

    func request(_ method: String, _ params: Any, timeout: Duration = .seconds(30)) async throws -> Any {
        let id: Int = lock.withLock { defer { nextID += 1 }; return nextID }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.fail(id, ClientError.timeout(method))
        }
        defer { timeoutTask.cancel() }
        // Results cross threads as JSON bytes (Sendable), decoded here.
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock { () -> Bool in
                if closed { return true }
                pending[id] = continuation
                return false
            }
            if isClosed { continuation.resume(throwing: ClientError.closed); return }
            do { try send(message) } catch { fail(id, error) }
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] ?? NSNull()
    }

    func notify(_ method: String, _ params: Any) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Waits for the next diagnostics the server publishes for `uri`, or returns the last ones.
    func diagnostics(for uri: String, waitingUpTo timeout: Duration) async -> [[String: Any]] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { diagnosticWaiters[uri, default: []].append(continuation) }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.releaseWaiters(uri)
            }
        }
        return lock.withLock { diagnostics[uri] ?? [] }
    }

    func clearDiagnostics(for uri: String) { lock.withLock { diagnostics[uri] = nil } }

    // MARK: Wire

    private func send(_ message: [String: Any]) throws {
        try RuntimePrivacyPolicy.requireNetwork()
        let body = try JSONSerialization.data(withJSONObject: message)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try writeLock.withLock {
            guard !lock.withLock({ closed }) else { throw ClientError.closed }
            try input.fileHandleForWriting.write(contentsOf: frame)
        }
    }

    private func receive(_ data: Data) {
        var messages: [[String: Any]] = []
        lock.withLock {
            buffer.append(data)
            while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else {
                    buffer.removeAll(); return
                }
                let start = headerEnd.upperBound
                guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return }
                let end = buffer.index(start, offsetBy: length)
                if let object = try? JSONSerialization.jsonObject(with: buffer[start..<end]) as? [String: Any] { messages.append(object) }
                buffer.removeSubrange(buffer.startIndex..<end)
                if buffer.count > 16 * 1_024 * 1_024 { buffer.removeAll() }
            }
        }
        for message in messages { handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if let error = message["error"] as? [String: Any] {
                continuation?.resume(throwing: ClientError.server(error["message"] as? String ?? "error"))
            } else {
                let wrapped = (try? JSONSerialization.data(withJSONObject: ["result": message["result"] ?? NSNull()])) ?? Data("{}".utf8)
                continuation?.resume(returning: wrapped)
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        if method == "textDocument/publishDiagnostics", let params = message["params"] as? [String: Any],
           let uri = params["uri"] as? String {
            lock.withLock { diagnostics[uri] = params["diagnostics"] as? [[String: Any]] ?? [] }
            releaseWaiters(uri)
        } else if let id = message["id"] {
            // A server request (e.g. workspace/configuration or progress): answer with null.
            try? send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
        }
    }

    private func releaseWaiters(_ uri: String) {
        let waiters = lock.withLock { diagnosticWaiters.removeValue(forKey: uri) ?? [] }
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ id: Int, _ error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }

    private func finish() {
        let (requests, waiters) = lock.withLock { () -> ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Never>]) in
            closed = true
            defer { pending.removeAll(); diagnosticWaiters.removeAll() }
            return (Array(pending.values), diagnosticWaiters.values.flatMap { $0 })
        }
        for request in requests { request.resume(throwing: ClientError.closed) }
        for waiter in waiters { waiter.resume() }
    }
}
