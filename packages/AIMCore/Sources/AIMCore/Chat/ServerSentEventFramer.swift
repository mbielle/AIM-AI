import Foundation

/// Frames SSE from bytes: AsyncBytes.lines intentionally omits empty lines,
/// although those lines delimit SSE events. UTF-8 and CRLF may span chunks.
public struct ServerSentEventFramer: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var skipLineFeed = false
    private var firstLine = true
    private let maximumBytes: Int

    public init(maximumBytes: Int = 2_097_152) { self.maximumBytes = maximumBytes }

    public mutating func append(_ byte: UInt8) throws -> String? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLineFeed = byte == 13
            return try completeLine()
        }
        guard line.count < maximumBytes else { throw ChatServiceError.invalidResponse }
        line.append(byte)
        return nil
    }

    private mutating func completeLine() throws -> String? {
        guard var value = String(bytes: line, encoding: .utf8) else { throw ChatServiceError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        if value.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true); eventBytes = 0
            return event
        }
        guard !value.hasPrefix(":") else { return nil }
        let field: Substring, content: Substring
        if let colon = value.firstIndex(of: ":") {
            field = value[..<colon]
            let suffix = value[value.index(after: colon)...]
            content = suffix.hasPrefix(" ") ? suffix.dropFirst() : suffix
        } else { field = Substring(value); content = "" }
        guard field == "data" else { return nil }
        eventBytes += content.utf8.count + (dataLines.isEmpty ? 0 : 1)
        guard eventBytes <= maximumBytes else { throw ChatServiceError.invalidResponse }
        dataLines.append(String(content))
        return nil
    }
}
