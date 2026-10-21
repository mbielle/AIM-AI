import CryptoKit
import Darwin
import Foundation

public struct LinuxVirtualMachineConfiguration: Codable, Sendable, Equatable {
    public enum Architecture: String, Codable, Sendable { case arm64, x86_64 }
    public enum Network: String, Codable, Sendable { case disabled, nat }
    public struct SSH: Codable, Sendable, Equatable {
        public var host: String
        public var port: Int
        public var user: String
        public var identityFile: String
        public var knownHostsFile: String
        public var workspaceRoot: String
        public var guestDirectory: String
    }
    public var version: Int
    public var enabled: Bool
    public var id: UUID
    public var accountID: UUID
    public var architecture: Architecture
    public var kernelPath: String
    public var kernelSHA256: String
    public var initrdPath: String?
    public var initrdSHA256: String?
    public var diskPath: String
    public var diskReadOnly: Bool
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var kernelCommandLine: String
    public var network: Network
    public var macAddress: String?
    public var ssh: SSH?
    public static var hostArchitecture: Architecture {
        var arm: Int32 = 0; var length = MemoryLayout.size(ofValue: arm)
        return sysctlbyname("hw.optional.arm64", &arm, &length, nil, 0) == 0 && arm == 1 ? .arm64 : .x86_64
    }
    public static func file(_ raw: String, writable: Bool = false) throws -> URL {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { throw LocalVirtualMachineError.invalidConfiguration }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, url.path == raw,
              url.resolvingSymlinksInPath().path == url.path, FileManager.default.isReadableFile(atPath: raw),
              !writable || FileManager.default.isWritableFile(atPath: raw) else { throw LocalVirtualMachineError.imageUnavailable }
        return url
    }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func validateFiles() throws {
        guard version == 1, architecture == Self.hostArchitecture, cpuCount >= 1,
              cpuCount <= max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
              memoryMiB > 0, memoryMiB <= ProcessInfo.processInfo.physicalMemory / (2 * 1_048_576),
              kernelCommandLine.utf8.count <= 16_384, !kernelCommandLine.contains("\0"),
              kernelSHA256.count == 64, kernelSHA256.allSatisfy(\.isHexDigit) else { throw LocalVirtualMachineError.invalidConfiguration }
        guard try Self.hash(Self.file(kernelPath)) == kernelSHA256.lowercased() else { throw LocalVirtualMachineError.imageIdentityChanged }
        if let path = initrdPath {
            guard let hash = initrdSHA256, hash.count == 64, hash.allSatisfy(\.isHexDigit),
                  try Self.hash(Self.file(path)) == hash.lowercased() else { throw LocalVirtualMachineError.imageIdentityChanged }
        } else if initrdSHA256 != nil { throw LocalVirtualMachineError.invalidConfiguration }
        let disk = try Self.file(diskPath, writable: !diskReadOnly)
        let size = try disk.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var identity = stat()
        guard lstat(disk.path, &identity) == 0, identity.st_nlink == 1 else { throw LocalVirtualMachineError.invalidConfiguration }
        guard size > 0, size % 512 == 0 else { throw LocalVirtualMachineError.invalidConfiguration }
        if network == .nat {
            guard let macAddress, macAddress.count == 17 else { throw LocalVirtualMachineError.invalidConfiguration }
        } else if ssh != nil { throw LocalVirtualMachineError.networkUnavailable }
        if let ssh {
            // Literal RFC1918 guest address; no DNS/provider or implicit tunnel.
            let pieces = ssh.host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
            let privateAddress = pieces.count == 4 && (pieces[0] == 10 || (pieces[0] == 172 && (16...31).contains(pieces[1])) || (pieces[0] == 192 && pieces[1] == 168))
            guard privateAddress, (1...65535).contains(ssh.port), !ssh.user.isEmpty, !ssh.user.hasPrefix("-"),
                  ssh.user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
                  ssh.guestDirectory.hasPrefix("/"), !ssh.guestDirectory.contains("\0"),
                  !ssh.guestDirectory.split(separator: "/").contains(".."), ssh.workspaceRoot.hasPrefix("/") else { throw LocalVirtualMachineError.invalidConfiguration }
            _ = try Self.file(ssh.identityFile); _ = try Self.file(ssh.knownHostsFile)
            let root = URL(fileURLWithPath: ssh.workspaceRoot).standardizedFileURL
            guard root.path == ssh.workspaceRoot, root.resolvingSymlinksInPath().path == root.path,
                  try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalVirtualMachineError.invalidConfiguration }
            let attributes = try FileManager.default.attributesOfItem(atPath: ssh.identityFile)
            guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw LocalVirtualMachineError.invalidConfiguration }
        }
    }
}
public struct LocalVirtualMachineStatus: Codable, Sendable {
    public var version = 1
    public var id: UUID?
    public var state: String
    public var hardwareSupported: Bool
    public var entitled: Bool
    public var configurationValid: Bool
    public var qualified = false
    public var diagnostic: String?
    public var network: LinuxVirtualMachineConfiguration.Network?
    public var sshConfigured: Bool
    public var sshVerified = false
    public init(id: UUID? = nil, state: String, hardwareSupported: Bool, entitled: Bool,
        configurationValid: Bool, diagnostic: String? = nil, network: LinuxVirtualMachineConfiguration.Network? = nil,
        sshConfigured: Bool = false, sshVerified: Bool = false) {
        self.id = id; self.state = state; self.hardwareSupported = hardwareSupported; self.entitled = entitled
        self.configurationValid = configurationValid; self.diagnostic = diagnostic; self.network = network
        self.sshConfigured = sshConfigured; self.sshVerified = sshVerified
    }
}
public enum LocalVirtualMachineError: String, Error, Sendable {
    case invalidConfiguration, imageUnavailable, imageIdentityChanged, unsupportedHardware, missingEntitlement,
         networkUnavailable, notRunning, busy, unauthorized, sshUnavailable, guestIdentityMismatch, unsupportedCommand, stopFailed
}
