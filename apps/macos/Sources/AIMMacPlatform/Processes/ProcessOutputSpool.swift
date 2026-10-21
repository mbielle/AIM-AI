import Darwin
import Foundation

/// Append-only, unlinked temporary files retain a command's output while its
/// run is alive. The files have mode 0600 and vanish even if AIM crashes.
/// Reads use byte offsets so a model can page output without losing chunks
/// when streaming snapshots are coalesced.
public final class ProcessOutputSpool: @unchecked Sendable {
    public struct Page: Sendable {
        public let bytes: Data
        public let nextOffset: Int64
        public let availableBytes: Int64
        public let limitReached: Bool
        public let storageError: Bool
    }

    private struct StreamState {
        let descriptor: Int32
        var written: Int64 = 0
        var limitReached = false
        var storageError = false
    }

    public static let maximumBytesPerStream: Int64 = 32 * 1_024 * 1_024
    private let lock = NSLock()
    private var stdout: StreamState
    private var stderr: StreamState

    public init() throws {
        let out = try Self.createTemporaryDescriptor()
        do {
            let err = try Self.createTemporaryDescriptor()
            stdout = StreamState(descriptor: out)
            stderr = StreamState(descriptor: err)
        } catch {
            Darwin.close(out)
            throw error
        }
    }

    deinit {
        Darwin.close(stdout.descriptor)
        Darwin.close(stderr.descriptor)
    }

    public func append(stream: Int32, bytes: UnsafeRawPointer, count: Int) {
        guard count > 0, stream == 1 || stream == 2 else { return }
        lock.lock()
        defer { lock.unlock() }
        if stream == 1 { Self.append(bytes, count: count, to: &stdout) }
        else { Self.append(bytes, count: count, to: &stderr) }
    }

    public func page(stream: Int32, offset: Int64, maximumBytes: Int = 16_384) throws -> Page {
        guard stream == 1 || stream == 2, offset >= 0, (1...65_536).contains(maximumBytes) else {
            throw ProcessExecutionError.invalidArgument
        }
        lock.lock()
        defer { lock.unlock() }
        let state = stream == 1 ? stdout : stderr
        guard offset <= state.written else { throw ProcessExecutionError.invalidArgument }
        let length = Int(min(Int64(maximumBytes), state.written - offset))
        var data = Data(count: length)
        var received = 0
        while received < length {
            let amount = data.withUnsafeMutableBytes { buffer in
                Darwin.pread(state.descriptor, buffer.baseAddress!.advanced(by: received),
                             length - received, off_t(offset + Int64(received)))
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw ProcessExecutionError.invalidArgument }
            received += amount
        }
        return Page(bytes: data, nextOffset: offset + Int64(received),
                    availableBytes: state.written, limitReached: state.limitReached,
                    storageError: state.storageError)
    }

    private static func createTemporaryDescriptor() throws -> Int32 {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-process-\(UUID().uuidString)").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.unlink(path) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private static func append(_ bytes: UnsafeRawPointer, count: Int, to state: inout StreamState) {
        if state.storageError { return }
        let room = max(0, maximumBytesPerStream - state.written)
        let allowed = min(count, Int(room))
        if allowed < count { state.limitReached = true }
        var offset = 0
        while offset < allowed {
            let amount = Darwin.pwrite(state.descriptor, bytes.advanced(by: offset),
                                       allowed - offset, off_t(state.written))
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { state.storageError = true; return }
            state.written += Int64(amount)
            offset += amount
        }
    }
}
