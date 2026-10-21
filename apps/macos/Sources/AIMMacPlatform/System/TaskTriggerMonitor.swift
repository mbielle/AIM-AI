import AIMApplication
import AppKit
import Foundation

/// Event triggers for scheduled tasks: a watched folder's entries change, a
/// given application launches, new mail arrives, a person's AppleScript returns
/// a new result, or the task's loopback webhook is called. Each fire is
/// debounced per task; the scheduler itself prevents overlap.
@MainActor
public final class TaskTriggerMonitor {
    public typealias Fire = @Sendable (_ taskID: UUID, _ reason: String, _ payload: String?) -> Void
    public typealias ScriptRunner = @Sendable (_ source: String) async -> String?
    public typealias PersistObservation = @Sendable (UUID, String, String, Bool) async -> Void

    private let fire: Fire
    private let debounce: TimeInterval
    private let runScript: ScriptRunner
    private let webhookPort: UInt16
    private let pollUnit: Duration
    private let persistObservation: PersistObservation?
    private var folderSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var launchTasks: [UUID: String] = [:]
    private var lastFired: [UUID: Date] = [:]
    private var workspaceObserver: NSObjectProtocol?
    private var polls: [UUID: Task<Void, Never>] = [:]
    private var webhookHashes: [UUID: String] = [:]
    private var webhookServer: LocalWebhookServer?

    /// `pollUnit` is one second in the app; tests shorten it.
    public init(debounce: TimeInterval = 30, webhookPort: UInt16 = LocalWebhookServer.defaultPort, pollUnit: Duration = .seconds(1),
                runScript: @escaping ScriptRunner = { source in
                    try? await AgentAppleScriptToolService.run(source, timeoutSeconds: 30).get() },
                persistObservation: PersistObservation? = nil, fire: @escaping Fire) {
        self.debounce = debounce
        self.webhookPort = webhookPort
        self.pollUnit = pollUnit
        self.runScript = runScript
        self.fire = fire
        self.persistObservation = persistObservation
    }

    /// Mail's newest unread inbox message as "id<TAB>sender<TAB>subject", checked
    /// only while Mail is already running (never launches it).
    static let newMailScript = """
    if application id "com.apple.mail" is running then
        tell application id "com.apple.mail"
            set unreadMessages to (messages of inbox whose read status is false)
            if (count of unreadMessages) is 0 then return ""
            set newest to item 1 of unreadMessages
            return ((id of newest) as text) & tab & (sender of newest) & tab & (subject of newest)
        end tell
    end if
    return ""
    """

    /// Replaces all watches with those of the given enabled tasks.
    public func update(_ tasks: [ScheduledTask]) {
        stopAll()
        for task in tasks where task.state == .enabled {
            switch task.spec?.trigger {
            case .folderChanged(let path)?:
                watchFolder(path, taskID: task.id)
            case .applicationLaunched(let bundleID)?:
                launchTasks[task.id] = bundleID
            case .newMail?:
                poll(task.id, source: Self.newMailScript, every: 60, newMail: true)
            case .scriptResultChanged(let source, let interval)?:
                poll(task.id, source: source, every: interval, newMail: false)
            case .webhook(let hash)?:
                webhookHashes[task.id] = hash
            case nil:
                break
            }
        }
        if !webhookHashes.isEmpty { startWebhooks() }
        if !launchTasks.isEmpty {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.applicationLaunched(bundleID) }
            }
        }
    }

    public func stopAll() {
        for source in folderSources.values { source.cancel() }
        folderSources.removeAll()
        launchTasks.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        for task in polls.values { task.cancel() }
        polls.removeAll()
        webhookHashes.removeAll()
        webhookServer?.stop()
        webhookServer = nil
    }

    /// Polls a script; the first non-empty result is the baseline, later new ones fire.
    /// For new mail, only a higher message id fires (reading mail must not).
    private func poll(_ taskID: UUID, source: String, every seconds: Int, newMail: Bool) {
        let runScript = self.runScript
        let unit = pollUnit
        let persistObservation = self.persistObservation
        polls[taskID] = Task { [weak self] in
            var baseline: String?
            var highestMailID = Int.min
            while !Task.isCancelled {
                if let output = await runScript(source)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    if let persistObservation {
                        await persistObservation(taskID, source, output, newMail)
                    } else if newMail {
                        let fields = output.components(separatedBy: "\t")
                        if let id = Int(fields[0]) {
                            if highestMailID != .min, id > highestMailID {
                                let detail = fields.dropFirst().joined(separator: " — ")
                                self?.trigger(taskID, reason: "new mail", payload: "From/subject: \(detail)")
                            }
                            highestMailID = max(highestMailID, id)
                        }
                    } else {
                        if let baseline, baseline != output {
                            self?.trigger(taskID, reason: "its AppleScript result changed", payload: String(output.prefix(8_000)))
                        }
                        baseline = output
                    }
                }
                try? await Task.sleep(for: unit * max(seconds, 30))
            }
        }
    }

    private func startWebhooks() {
        guard webhookServer == nil else { return }
        let server = LocalWebhookServer(port: webhookPort) { [weak self] taskID, token, body in
            await self?.webhookCalled(taskID, token: token, body: body) ?? 404
        }
        try? server.start()
        webhookServer = server
    }

    private func webhookCalled(_ taskID: UUID, token: String, body: String) -> Int {
        guard let hash = webhookHashes[taskID] else { return 404 }
        guard LocalWebhookServer.matches(token, hash: hash) else { return 401 }
        return trigger(taskID, reason: "its webhook", payload: body.isEmpty ? nil : body) ? 202 : 429
    }

    private func watchFolder(_ path: String, taskID: UUID) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.trigger(taskID, reason: "folder changed") }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderSources[taskID] = source
    }

    private func applicationLaunched(_ bundleID: String) {
        for (taskID, expected) in launchTasks where expected == bundleID {
            trigger(taskID, reason: "\(bundleID) launched")
        }
    }

    @discardableResult
    private func trigger(_ taskID: UUID, reason: String, payload: String? = nil) -> Bool {
        let now = Date.now
        if let last = lastFired[taskID], now.timeIntervalSince(last) < debounce { return false }
        lastFired[taskID] = now
        fire(taskID, reason, payload)
        return true
    }
}
