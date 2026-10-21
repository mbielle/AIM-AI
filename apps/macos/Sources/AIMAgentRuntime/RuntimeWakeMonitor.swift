import AIMApplication
import AIMMacPlatform
import AppKit
import CryptoKit
import Foundation
import Network

package enum WakeFingerprint {
    package static func fileSystem(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var digest = SHA256()
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try child.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                digest.update(data: Data("\(child.lastPathComponent)\0\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)\0\(values.fileSize ?? 0)\n".utf8))
            }
        } else if attributes[.type] as? FileAttributeType == .typeRegular {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            while let data = try handle.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
        } else { throw ExecutionStoreError.invalidTransition }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @MainActor package static func process(_ key: String) -> String? {
        guard let pid = Int32(key), pid > 0, let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated, let date = application.launchDate else { return nil }
        return String(date.timeIntervalSince1970)
    }
}

/// Read-only observations wake existing authority, never create it.
package actor RuntimeWakeMonitor {
    let coordinator: RunCoordinator
    let repository: SQLiteAgentExecutionRepository
    let owner: UUID
    let scheduler: SQLiteSchedulerRepository?
    private let network = NWPathMonitor()
    private var online = false
    private var stopped = false
    package init(coordinator: RunCoordinator, repository: SQLiteAgentExecutionRepository, owner: UUID, scheduler: SQLiteSchedulerRepository? = nil) {
        self.coordinator = coordinator; self.repository = repository; self.owner = owner
        self.scheduler = scheduler
    }
    package func start() {
        network.pathUpdateHandler = { [weak self] path in Task { await self?.setOnline(path.status == .satisfied) } }
        network.start(queue: DispatchQueue(label: "com.aimai.continuity.network", qos: .utility))
    }
    private func setOnline(_ value: Bool) { online = value }
    package func stop() { stopped = true; network.cancel() }
    package func tick() async throws {
        guard !stopped else { return }
        for condition in try await repository.wakeConditions() {
            guard let _ = try? await coordinator.snapshot(condition.executionID) else { continue }
            let signal: String?
            switch condition.kind {
            case .folder:
                guard let baseline = condition.baseline else { continue }
                let current = try? await Task.detached(priority: .utility) { try WakeFingerprint.fileSystem(condition.key) }.value
                signal = current == nil ? "file_unavailable" : current == baseline ? nil : current
            case .process:
                guard let baseline = condition.baseline else { continue }
                if baseline == "durable_handle", let id = UUID(uuidString: condition.key) {
                    let process = try await repository.processes(executionID: condition.executionID).first { $0.id == id }
                    signal = process?.state != "running" ? "durable_process_receipt_available" : nil
                } else {
                    let current = await WakeFingerprint.process(condition.key)
                    signal = current == baseline ? nil : "process_exited_or_replaced"
                }
            case .desktop: signal = ScreenLockState.isLocked ? nil : "desktop_unlocked"
            case .network: signal = online ? "network_available" : nil
            case .script, .webhook, .mail:
                guard let task = UUID(uuidString: condition.key), let raw = condition.baseline.flatMap(Double.init) else { continue }
                let reason = condition.kind == .mail ? "new mail" : condition.kind == .script ? "its AppleScript result changed" : "its webhook"
                signal = try await scheduler?.latestRuntimeEvent(taskID: task, reason: reason, after: Date(timeIntervalSince1970: raw))
            default: signal = nil
            }
            if let signal {
                _ = try await repository.enqueueWake(executionID: condition.executionID,
                    dedupKey: "source:\(condition.id)", payload: Data(signal.utf8), owner: owner)
            }
        }
    }
}
