import Foundation
import OSLog

public struct RedactedLogger: Sendable {
    private let logger: Logger
    private let logFile: URL

    public init(category: String, logDirectory: URL) {
        logger = Logger(subsystem: "com.aimai.macos", category: category)
        logFile = logDirectory.appending(path: "aim.log")
    }

    public func info(_ message: String, metadata: [String: String] = [:]) { write("INFO", message, metadata: metadata) }
    public func error(_ message: String, metadata: [String: String] = [:]) { write("ERROR", message, metadata: metadata) }

    public func preview(maximumBytes: Int = 200_000) -> String {
        guard let data = try? Data(contentsOf: logFile), !data.isEmpty else { return "" }
        return String(decoding: data.suffix(maximumBytes), as: UTF8.self)
    }

    private func write(_ level: String, _ message: String, metadata: [String: String]) {
        let redactedMessage = Self.redact(message)
        let safeMetadata = metadata.mapValues(Self.redact)
        logger.log("\(level, privacy: .public) \(redactedMessage, privacy: .public)")
        let payload = "\(ISO8601DateFormatter().string(from: .now)) \(level) \(redactedMessage) \(safeMetadata)\n"
        guard let data = payload.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    public static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(authorization:\s*bearer\s+)[^\s]+"#,
            #"(?i)(api[_-]?key[=: ]+)[^\s,;]+"#,
            #"(?i)(token[=: ]+)[^\s,;]+"#,
            #"(?i)(secret[=: ]+)[^\s,;]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1<redacted>", options: .regularExpression)
        }
        return result
    }
}
