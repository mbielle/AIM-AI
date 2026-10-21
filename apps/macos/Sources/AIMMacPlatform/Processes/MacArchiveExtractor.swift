import AIMAgentKit
import Foundation

public struct MacArchiveExtractor: RuntimeArchiveExtracting {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    public func extract(archive: URL, format: RuntimeArchiveFormat, destination: URL) async throws {
        let command: ProcessCommand
        switch format {
        case .zip:
            command = ProcessCommand(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, destination.path],
                timeout: .seconds(120)
            )
        case .tarGzip:
            command = ProcessCommand(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", archive.path, "-C", destination.path],
                timeout: .seconds(120)
            )
        case .rawExecutable:
            let target = destination.appending(path: archive.lastPathComponent)
            try FileManager.default.copyItem(at: archive, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return
        }
        let output = try await runner.run(command)
        guard output.exitCode == 0 else {
            throw ArchiveExtractionError.failed(output.stderr.isEmpty ? output.stdout : output.stderr)
        }
    }
}

public enum ArchiveExtractionError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case let .failed(message): "Archive extraction failed: \(message)" }
    }
}
