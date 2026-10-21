import AIMApplication
import Foundation
import Security
import Virtualization

/// The framework requires all calls and delegates on its selected serial queue.
/// This host consistently uses the default main queue, including in the helper.
@MainActor public final class LinuxVirtualMachineHost: NSObject, VZVirtualMachineDelegate {
    private var machine: VZVirtualMachine?
    private var configuration: LinuxVirtualMachineConfiguration?
    private var valid = false
    private var diagnostic: String?
    private var operating = false
    public override init() { super.init() }
    public static var entitled: Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.virtualization"] as? Bool == true
    }
    private func make(_ source: LinuxVirtualMachineConfiguration) throws -> VZVirtualMachineConfiguration {
        guard VZVirtualMachine.isSupported else { throw LocalVirtualMachineError.unsupportedHardware }
        guard Self.entitled else { throw LocalVirtualMachineError.missingEntitlement }
        try source.validateFiles()
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        guard source.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
              source.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              source.memoryMiB <= UInt64.max / 1_048_576 else { throw LocalVirtualMachineError.invalidConfiguration }
        let memory = source.memoryMiB * 1_048_576
        guard memory >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
              memory <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else { throw LocalVirtualMachineError.invalidConfiguration }
        config.cpuCount = source.cpuCount; config.memorySize = memory
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: source.kernelPath))
        boot.initialRamdiskURL = source.initrdPath.map { URL(fileURLWithPath: $0) }
        boot.commandLine = source.kernelCommandLine; config.bootLoader = boot
        let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: source.diskPath), readOnly: source.diskReadOnly,
            cachingMode: .automatic, synchronizationMode: .full)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // Guest output is discarded, never interpreted as a command or authority.
        // An operator must provision a bootable disk and SSH without console login.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: FileHandle.nullDevice)
        config.serialPorts = [serial]
        if source.network == .nat {
            try RuntimePrivacyPolicy.requireNetwork()
            guard let raw = source.macAddress, let mac = VZMACAddress(string: raw), !mac.isMulticastAddress else { throw LocalVirtualMachineError.invalidConfiguration }
            let network = VZVirtioNetworkDeviceConfiguration()
            network.macAddress = mac; network.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [network]
        }
        try config.validate()
        return config
    }
    public func preview(_ source: LinuxVirtualMachineConfiguration) -> LocalVirtualMachineStatus {
        do { _ = try make(source); return status(source: source, valid: true, diagnostic: nil) }
        catch { return status(source: source, valid: false, diagnostic: Self.code(error)) }
    }
    private static func code(_ error: Error) -> String {
        (error as? LocalVirtualMachineError)?.rawValue ?? "virtualization_configuration_or_operation_failed"
    }
    private func status(source: LinuxVirtualMachineConfiguration?, valid: Bool, diagnostic: String?) -> LocalVirtualMachineStatus {
        let state: String
        if let machine {
            switch machine.state {
            case .stopped: state = "stopped"
            case .running: state = "running"
            case .paused: state = "paused"
            case .starting: state = "starting"
            case .stopping: state = "stopping"
            case .pausing: state = "pausing"
            case .resuming: state = "resuming"
            case .error: state = "error"
            @unknown default: state = "unknown"
            }
        } else { state = source == nil ? "not_configured" : "configured" }
        return LocalVirtualMachineStatus(id: source?.id, state: state, hardwareSupported: VZVirtualMachine.isSupported,
            entitled: Self.entitled, configurationValid: valid, diagnostic: diagnostic, network: source?.network, sshConfigured: source?.ssh != nil)
    }
    public func status() -> LocalVirtualMachineStatus { status(source: configuration, valid: valid, diagnostic: diagnostic) }
    public func start(_ source: LinuxVirtualMachineConfiguration) async throws -> LocalVirtualMachineStatus {
        guard !operating, machine == nil || machine?.state == .stopped || machine?.state == .error else { throw LocalVirtualMachineError.busy }
        operating = true; defer { operating = false }
        let config: VZVirtualMachineConfiguration
        do { config = try make(source) } catch { valid = false; diagnostic = Self.code(error); throw error }
        let vm = VZVirtualMachine(configuration: config); vm.delegate = self
        machine = vm; configuration = source; valid = true; diagnostic = nil
        do { try await vm.start() }
        catch { diagnostic = Self.code(error); throw error }
        return status()
    }
    public func stop(force: Bool) async throws -> LocalVirtualMachineStatus {
        guard !operating else { throw LocalVirtualMachineError.busy }
        guard let vm = machine else { return status() }
        operating = true; defer { operating = false }
        if vm.state == .stopped || vm.state == .error { machine = nil; return status() }
        if !force {
            guard vm.canRequestStop else { throw LocalVirtualMachineError.stopFailed }
            try vm.requestStop()
            // A request is not proof of stop; report actual state to the operator.
            return status()
        }
        guard vm.canStop else { throw LocalVirtualMachineError.stopFailed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        machine = nil
        return status()
    }
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let instance = ObjectIdentifier(virtualMachine)
        Task { @MainActor [weak self] in
            guard let self, self.machine.map(ObjectIdentifier.init) == instance else { return }
            self.diagnostic = nil
        }
    }
    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let instance = ObjectIdentifier(virtualMachine)
        Task { @MainActor [weak self] in
            guard let self, self.machine.map(ObjectIdentifier.init) == instance else { return }
            self.diagnostic = "virtual_machine_guest_stopped_with_error"
        }
    }
}
