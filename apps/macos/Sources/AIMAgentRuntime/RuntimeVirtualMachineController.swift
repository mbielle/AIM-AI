import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import CryptoKit
import Foundation

/// Runtime ownership only. The UI sends explicit management commands through its
/// existing authenticated host connection; importing a configuration never boots.
package actor RuntimeVirtualMachineController {
    private struct Receipt: Codable {
        var version = 1
        var configurationID: UUID
        var accountID: UUID
        var state: String
        var observedAt: Date
        var configurationDigest: String
        var qualified = false
    }
    private let directory: URL
    private let accountID: @Sendable () async -> UUID?
    private var source: LinuxVirtualMachineConfiguration?
    private let hostTask = Task { @MainActor in LinuxVirtualMachineHost() }
    private var diskLease: RuntimeLease?
    private var operating = false
    private var stopping = false
    private var shutdownRequested = false
    private var commands = 0
    private var sshVerified = false
    private var loadFailure: String?
    private let runner = MacProcessRunner()
    package init(directory: URL, accountID: @escaping @Sendable () async -> UUID?) throws {
        self.directory = directory; self.accountID = accountID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw LocalVirtualMachineError.invalidConfiguration }
        let file = directory.appendingPathComponent("vm-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else { throw LocalVirtualMachineError.invalidConfiguration }
                let config = try JSONDecoder().decode(LinuxVirtualMachineConfiguration.self, from: Data(contentsOf: file))
                guard config.version == 1 else { throw LocalVirtualMachineError.invalidConfiguration }
                source = config
            } catch { loadFailure = "vm_configuration_unavailable" }
        }
        // No recovery auto-start: a previous receipt is evidence, never permission
        // to replay work or overwrite the operator's mutable disk after a crash.
    }
    private func backend() async -> LinuxVirtualMachineHost {
        await hostTask.value
    }
    private func authorized(_ config: LinuxVirtualMachineConfiguration) async -> Bool {
        await accountID() == config.accountID
    }
    private func journal(_ config: LinuxVirtualMachineConfiguration, state: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(config)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let receipt = Receipt(configurationID: config.id, accountID: config.accountID, state: state,
            observedAt: .now, configurationDigest: digest)
        let file = directory.appendingPathComponent("vm-receipt-" + config.id.uuidString + "-" + UUID().uuidString + ".json")
        try encoder.encode(receipt).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    package func previewConfiguration(_ data: Data) async throws -> LocalVirtualMachineStatus {
        guard data.count <= 65_536 else { throw LocalVirtualMachineError.invalidConfiguration }
        let config = try JSONDecoder().decode(LinuxVirtualMachineConfiguration.self, from: data)
        guard config.version == 1, await authorized(config) else { throw LocalVirtualMachineError.unauthorized }
        return await backend().preview(config)
    }
    package func importConfiguration(_ data: Data) async throws -> LocalVirtualMachineStatus {
        guard !operating, !stopping, commands == 0 else { throw LocalVirtualMachineError.busy }
        operating = true; defer { operating = false }
        let backend = await backend()
        let current = await backend.status()
        guard ["not_configured", "configured", "stopped", "error"].contains(current.state) else { throw LocalVirtualMachineError.busy }
        let preview = try await previewConfiguration(data)
        // Missing entitlement/image is shown during preview and prevents activation.
        guard preview.configurationValid else { throw LocalVirtualMachineError.invalidConfiguration }
        let config = try JSONDecoder().decode(LinuxVirtualMachineConfiguration.self, from: data)
        guard await authorized(config) else { throw LocalVirtualMachineError.unauthorized }
        let file = directory.appendingPathComponent("vm-v1.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        source = config; loadFailure = nil; sshVerified = false
        try journal(config, state: "configured")
        return preview
    }
    package func status() async -> LocalVirtualMachineStatus {
        let backend = await backend()
        guard let source, await authorized(source) else {
            let capability = await backend.status()
            return LocalVirtualMachineStatus(state: "not_configured", hardwareSupported: capability.hardwareSupported,
                entitled: capability.entitled, configurationValid: false, diagnostic: loadFailure)
        }
        var current = await backend.status()
        if ["not_configured", "configured", "stopped", "error"].contains(current.state) { current = await backend.preview(source) }
        current.sshVerified = sshVerified && current.state == "running" && !shutdownRequested
        if shutdownRequested, ["running", "starting", "stopping"].contains(current.state) { current.diagnostic = "guest_stop_requested_awaiting_actual_stop" }
        return current
    }
    package func start() async throws -> LocalVirtualMachineStatus {
        guard !operating, !stopping, commands == 0, let config = source, config.enabled else { throw LocalVirtualMachineError.unauthorized }
        operating = true; defer { operating = false }
        guard await authorized(config) else { throw LocalVirtualMachineError.unauthorized }
        shutdownRequested = false
        if config.network == .nat { try RuntimePrivacyPolicy.requireNetwork() }
        let backend = await backend()
        let current = await backend.status()
        guard ["not_configured", "configured", "stopped", "error"].contains(current.state) else { throw LocalVirtualMachineError.busy }
        diskLease = nil // the observed prior guest is stopped/error, so release its old lease.
        let digest = SHA256.hash(data: Data(config.diskPath.utf8)).map { String(format: "%02x", $0) }.joined()
        let lease = try RuntimeLease(url: directory.appendingPathComponent("disk-" + digest + ".lock"))
        diskLease = lease; sshVerified = false
        do {
            try journal(config, state: "starting")
            _ = try await backend.start(config)
            try Task.checkCancellation()
            guard !shutdownRequested, !stopping, await authorized(config), config.network != .nat || !RuntimePrivacyPolicy.isEnabled else { throw LocalVirtualMachineError.unauthorized }
            try journal(config, state: "running")
            return await status()
        } catch {
            // Once VZ has started, lack of permission/cancel/storage proof must not
            // leave an unowned networking guest running in the background.
            _ = try? await backend.stop(force: true)
            let state = await backend.status()
            if ["not_configured", "configured", "stopped", "error"].contains(state.state) { diskLease = nil }
            try? journal(config, state: "start_failed")
            throw error
        }
    }
    package func stop(force: Bool = false) async throws -> LocalVirtualMachineStatus {
        guard !operating, !stopping, let config = source else { throw LocalVirtualMachineError.unauthorized }
        guard force || commands == 0 else { throw LocalVirtualMachineError.busy }
        stopping = true; defer { stopping = false }
        guard await authorized(config) else { throw LocalVirtualMachineError.unauthorized }
        shutdownRequested = true
        if force { await runner.terminateAll() }
        let backend = await backend()
        try journal(config, state: force ? "force_stop_requested" : "guest_stop_requested")
        _ = try await backend.stop(force: force)
        let status = await backend.status()
        if ["configured", "stopped", "error", "not_configured"].contains(status.state) { diskLease = nil; sshVerified = false }
        try journal(config, state: status.state)
        return status
    }
    package func tick() async {
        guard let config = source else { return }
        if !(await authorized(config)) || (config.network == .nat && RuntimePrivacyPolicy.isEnabled) { await shutdown() }
        else {
            let state = await backend().status()
            if ["stopped", "error"].contains(state.state) { diskLease = nil; sshVerified = false }
        }
    }
    package func privacyQuiesce() async throws -> LocalVirtualMachineStatus {
        if source?.network == .nat { await shutdown() }
        let current = await status()
        guard source?.network != .nat || !["running", "starting", "stopping"].contains(current.state) else { throw LocalVirtualMachineError.notRunning }
        return current
    }
    package func shutdown() async {
        // Logout/runtime termination applies to the owned guest, not another VM.
        shutdownRequested = true
        stopping = true; defer { stopping = false }
        await runner.terminateAll()
        guard !operating else { return } // start rechecks account/privacy afterwards.
        let host = await backend()
        _ = try? await host.stop(force: true)
        let state = await host.status()
        if ["configured", "stopped", "error", "not_configured"].contains(state.state) { diskLease = nil }
        sshVerified = false
        if let source { try? journal(source, state: "runtime_shutdown_requested") }
    }
    package nonisolated func makeRunner() -> any ProcessRunning { RuntimeVMProcessRunner(controller: self) }
    package func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        guard !operating, !stopping, !shutdownRequested, let config = source, config.enabled, let target = config.ssh else { throw LocalVirtualMachineError.notRunning }
        commands += 1; defer { commands -= 1 }
        guard await authorized(config), await backend().status().state == "running" else { throw LocalVirtualMachineError.notRunning }
        try RuntimePrivacyPolicy.requireNetwork()
        guard command.executable.path == "/bin/zsh", command.arguments.count == 3,
              command.arguments[0] == "-f", command.arguments[1] == "-c", let cwd = command.workingDirectory,
              !command.acceptsStandardInput else { throw LocalVirtualMachineError.unsupportedCommand }
        let path = cwd.standardizedFileURL.path
        guard path == cwd.resolvingSymlinksInPath().path, path == target.workspaceRoot || path.hasPrefix(target.workspaceRoot + "/") else { throw LocalVirtualMachineError.unauthorized }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func ssh(_ script: String, timeout: Duration?) -> ProcessCommand {
            ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-F", "/dev/null", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                "-o", "PermitLocalCommand=no", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=" + target.knownHostsFile,
                "-i", target.identityFile, "-p", String(target.port), "--", target.user + "@" + target.host, script],
                environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, inheritsEnvironment: false)
        }
        _ = try LinuxVirtualMachineConfiguration.file(target.identityFile)
        _ = try LinuxVirtualMachineConfiguration.file(target.knownHostsFile)
        let identity = try await runner.run(ssh("cat -- /etc/aim-vm-id", timeout: .seconds(10)))
        guard identity.exitCode == 0, !identity.wasTruncated,
              identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == config.id.uuidString.lowercased() else { throw LocalVirtualMachineError.guestIdentityMismatch }
        guard !stopping, !shutdownRequested, await authorized(config), !RuntimePrivacyPolicy.isEnabled, await backend().status().state == "running" else { throw LocalVirtualMachineError.unauthorized }
        sshVerified = true
        let relative = path == target.workspaceRoot ? "" : String(path.dropFirst(target.workspaceRoot.count + 1))
        let remote = relative.isEmpty ? target.guestDirectory : target.guestDirectory + "/" + relative
        // Existing workspace tool approvals/scopes must be preserved by the caller.
        // This adapter grants no authority and shares no host directory into VZ.
        return try await runner.run(ssh("cd -- " + quote(remote) + " && /bin/sh -c " + quote(command.arguments[2]), timeout: command.timeout))
    }
    package func terminateCommands() async { await runner.terminateAll() }
}
package actor RuntimeVMProcessRunner: ProcessRunning {
    private let controller: RuntimeVirtualMachineController
    package init(controller: RuntimeVirtualMachineController) { self.controller = controller }
    package func run(_ command: ProcessCommand) async throws -> ProcessOutput { try await controller.run(command) }
    package func terminateAll() async { await controller.terminateCommands() }
}
