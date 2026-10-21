import AIMAgentRuntime
import AIMMacPlatform
import AppKit
import SwiftUI

struct VirtualMachineSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: LocalVirtualMachineStatus?
    @State private var staged: Data?
    @State private var configuration: LinuxVirtualMachineConfiguration?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        SettingsGroup("Local Linux virtual machine", description: "Use your own preprovisioned kernel, initrd and disk image. Importing never starts the VM. Guest commands use the explicitly configured SSH identity; native Mac file and desktop tools keep their existing scope.") {
            SettingsRow("Configuration") {
                Button("Import and review…") { select() }.buttonStyle(.settings).disabled(busy)
                Button("Refresh status") { Task { await control(.status) } }.buttonStyle(.settings).disabled(busy)
            }
            if let status {
                SettingsRow("Runtime state", description: status.state + (status.diagnostic.map { " · " + $0 } ?? ""))
                SettingsRow("Capabilities", description: "Hardware: \(status.hardwareSupported ? "available" : "unavailable") · entitlement: \(status.entitled ? "present" : "missing") · guest SSH: \(status.sshVerified ? "observed" : "not verified")")
            }
            if let configuration {
                SettingsRow("Identity", description: "VM \(configuration.id.uuidString) · Account \(configuration.accountID.uuidString)")
                SettingsRow("Boot images", description: configuration.kernelPath + " · SHA256 " + configuration.kernelSHA256 + " · " + (configuration.initrdPath ?? "no initrd"))
                SettingsRow("Disk", description: configuration.diskPath + (configuration.diskReadOnly ? " · read only" : " · writable"))
                SettingsRow("Resources", description: "\(configuration.cpuCount) CPUs · \(configuration.memoryMiB) MiB · network \(configuration.network.rawValue)")
                if let ssh = configuration.ssh { SettingsRow("Guest commands", description: "\(ssh.user)@\(ssh.host):\(ssh.port) · \(ssh.guestDirectory) · host workspace \(ssh.workspaceRoot) · host keys \(ssh.knownHostsFile)") }
            }
            if staged != nil {
                SettingsRow("Apply reviewed configuration") {
                    Button("Cancel") { staged = nil; configuration = nil }.buttonStyle(.settings)
                    Button("Apply") { Task { await apply() } }.buttonStyle(.settingsPrimary).disabled(busy)
                }
            } else {
                SettingsRow("Guest lifecycle", description: "Start and stop are separate from importing or selecting the shell backend. Stopping can interrupt guest work.") {
                    Button("Start") { Task { await control(.start) } }.buttonStyle(.settings).disabled(busy)
                    Button("Stop") { Task { await control(.stop) } }.buttonStyle(.settings).disabled(busy)
                }
                if let ssh = configuration?.ssh {
                    SettingsRow("Workspace commands") {
                        Button("Use this VM") {
                            do {
                                var value = WorkspaceExecutionEnvironment(); value.backend = .virtualMachine; value.workspaceRoot = ssh.workspaceRoot
                                try WorkspaceExecutionEnvironment.save(value); error = nil
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.settings).disabled(busy)
                    }
                }
            }
            if let error { SettingsNotice(error, tone: .error) }
        }
    }
    private func select() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 65_536 else { throw LocalVirtualMachineError.invalidConfiguration }
            let data = try Data(contentsOf: file)
            let config = try JSONDecoder().decode(LinuxVirtualMachineConfiguration.self, from: data)
            Task {
                busy = true; defer { busy = false }
                do { status = try await model.virtualMachineControl(.init(action: .preview, configuration: data)); staged = data; configuration = config; error = nil }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func apply() async {
        guard let staged else { return }
        busy = true; defer { busy = false }
        do { status = try await model.virtualMachineControl(.init(action: .apply, configuration: staged)); self.staged = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func control(_ action: RuntimeVirtualMachineControl.Action) async {
        busy = true; defer { busy = false }
        do { status = try await model.virtualMachineControl(.init(action: action)); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
