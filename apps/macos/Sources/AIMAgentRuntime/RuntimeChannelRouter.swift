import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import CryptoKit
import Darwin
import Foundation

package struct RuntimeChannelConfiguration: Codable, Sendable {
    package var version: Int
    package var enabled: Bool
    package var grants: [RuntimeChannelGrant]
}
package struct RuntimeChannelGrant: Codable, Sendable, Equatable {
    package enum Transport: String, Codable, Sendable { case file, webhook, telegram, plugin }
    package enum Scope: String, Codable, Sendable { case receiveWake, deliverResult }
    package var id: UUID
    package var accountID: UUID
    package var executionID: UUID
    package var transport: Transport
    package var scopes: Set<Scope>
    package var eventKey: String
    package var expiresAt: Date
    package var revoked: Bool
    package var inboxDirectory: String?
    package var outboxDirectory: String?
    package var endpoint: URL?
    package var credentialKey: String?
    package var receiverSupportsIdempotency: Bool?
    package var telegram: RuntimeTelegramGrant?
    package var plugin: RuntimePluginChannelGrant?
}
package struct RuntimeChannelEvent: Codable, Sendable {
    package var version: Int
    package var id: String
    package var executionID: UUID
    package var eventKey: String
    package var occurredAt: Date
    package var data: RemoteJSONValue
}
package enum RuntimeChannelError: Error, Sendable {
    case invalidConfiguration, invalidEvent, unauthorized, conflict, unsupportedVersion, missingCredential, deliveryUnconfirmed
}
private struct ChannelReceipt: Codable, Sendable {
    enum Direction: String, Codable, Sendable { case ingress, outbox }
    var version = 1
    var id: String
    var direction: Direction
    var grant: RuntimeChannelGrant
    var event: RuntimeChannelEvent
    var digest: String
    var state: String
    var attempts = 0
    var nextAttemptAt: Date = .now
    var deliveredAt: Date?
    var lastError: String?
    var telegramMessageID: Int64?
    var pluginReceiptID: String?
}
private final class ChannelHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// An explicit local routing grant is authority. Incoming contents are only data.
/// No listener is opened and no objective is created from a channel event.
package actor RuntimeChannelRouter {
    private let coordinator: RunCoordinator
    private let executions: SQLiteAgentExecutionRepository
    private let secureStore: any SecureStoring
    private let directory: URL
    private let accountID: @Sendable () async -> UUID?
    private var receipts: [String: ChannelReceipt] = [:]
    private var delivering: [String: Task<Void, Never>] = [:]
    private var running = false
    private struct Polling { var generation: UUID; var grant: RuntimeChannelGrant; var task: Task<Void, Never> }
    private var polling: [UUID: Polling] = [:]
    private var retiredPolling: [UUID: Task<Void, Never>] = [:]
    private var telegramConflicts: Set<UUID> = []
    private var telegramLeases: [Int64: RuntimeLease] = [:]
    private let telegramClient = RuntimeTelegramClient()
    private var pluginIngress: [String: RuntimePluginIngress] = [:]
    private var pluginPolling: [UUID: Polling] = [:]
    private var pluginSessions: [UUID: any AgentChannelSession] = [:]
    private var pluginStarting: [UUID: Task<any AgentChannelSession, Error>] = [:]
    private var pluginClosing: [UUID: Task<Void, Never>] = [:]
    private var pluginLeases: [UUID: RuntimeLease] = [:]
    private var pluginSuspended: Set<UUID> = []
    private var inboxFingerprints: [String: String] = [:]
    package private(set) var failure: String?
    private let session: URLSession
    package init(coordinator: RunCoordinator, executions: SQLiteAgentExecutionRepository, secureStore: any SecureStoring,
        directory: URL, accountID: @escaping @Sendable () async -> UUID?) throws {
        self.coordinator = coordinator; self.executions = executions; self.secureStore = secureStore
        self.directory = directory; self.accountID = accountID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RuntimeChannelError.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 40
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        session = AIMManagedNetworkSession.make(configuration: configuration, delegate: ChannelHTTPDelegate(), delegateQueue: nil)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            where file.lastPathComponent.hasPrefix("receipt-") && file.pathExtension == "json" {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink != true,
                  let data = try? Data(contentsOf: file), var receipt = try? Self.decoder().decode(ChannelReceipt.self, from: data), receipt.version == 1 else {
                throw RuntimeChannelError.unsupportedVersion
            }
            if [.telegram, .plugin].contains(receipt.grant.transport), receipt.state == "sending" {
                receipt.state = "outcome_unknown"; receipt.lastError = receipt.grant.transport == .telegram ? "telegram_delivery_outcome_unknown" : "plugin_delivery_outcome_unknown"
                try Self.encoder().encode(receipt).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            receipts[receipt.id] = receipt
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("plugin-ingress-") && file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_097_152 else { throw RuntimeChannelError.invalidConfiguration }
            let value = try Self.decoder().decode(RuntimePluginIngress.self, from: Data(contentsOf: file))
            guard value.version == 1 else { throw RuntimeChannelError.unsupportedVersion }
            pluginIngress[value.hostReceiptID] = value
        }
    }
    package func start() { running = true }
    package func stop() async {
        running = false
        let tasks = Array(delivering.values) + polling.values.map(\.task) + Array(retiredPolling.values) + pluginPolling.values.map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        let starts = Array(pluginStarting.values); starts.forEach { $0.cancel() }
        for task in starts { _ = try? await task.value }
        let pluginIDs = Set(pluginSessions.keys).union(pluginStarting.keys)
        for id in pluginIDs { await AgentPluginRegistry.shared.closeChannel(grantID: id) }
        for task in Array(pluginClosing.values) { await task.value }
        pluginStarting.removeAll(); pluginSessions.removeAll(); pluginClosing.removeAll(); pluginPolling.removeAll(); pluginLeases.removeAll(); pluginSuspended.removeAll()
        delivering.removeAll(); polling.removeAll(); retiredPolling.removeAll(); telegramConflicts.removeAll(); telegramLeases.removeAll()
    }
    private static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
    private func configuration() throws -> RuntimeChannelConfiguration {
        let file = directory.appendingPathComponent("grants-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(version: 1, enabled: false, grants: []) }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262_144 else { throw RuntimeChannelError.invalidConfiguration }
        return try Self.validatedConfiguration(Data(contentsOf: file))
    }
    private static func validatedConfiguration(_ data: Data) throws -> RuntimeChannelConfiguration {
        guard data.count <= 262_144 else { throw RuntimeChannelError.invalidConfiguration }
        let config = try Self.decoder().decode(RuntimeChannelConfiguration.self, from: data)
        guard config.version == 1, Set(config.grants.map(\.id)).count == config.grants.count else { throw RuntimeChannelError.invalidConfiguration }
        let bots = config.grants.filter { $0.transport == .telegram }
        guard bots.allSatisfy({ grant in
            guard let t = grant.telegram else { return false }
            return t.version == 1 && t.botID > 0 && t.botID < 9_007_199_254_740_992
                && t.chatID != 0 && t.chatID > -9_007_199_254_740_992 && t.chatID < 9_007_199_254_740_992 && !t.tokenKey.isEmpty
                && !t.senderIDs.isEmpty && t.senderIDs.allSatisfy({ $0 > 0 && $0 < 9_007_199_254_740_992 }) && t.reconciliation == "manual"
        }), Set(bots.compactMap { $0.telegram?.botID }).count == bots.count else { throw RuntimeChannelError.invalidConfiguration }
        for grant in config.grants where grant.transport == .plugin {
            guard let p = grant.plugin, p.version == 1, p.apiVersion == 1, !p.pluginID.isEmpty,
                  !p.pluginVersion.isEmpty, p.configuration.count <= 16_384 else { throw RuntimeChannelError.invalidConfiguration }
        }
        return config
    }
    /// Preview is read-only. Every enabled grant must already belong to this
    /// account and an existing mission; the UI must show targets/scopes before import.
    package func previewConfiguration(_ data: Data) async throws -> RuntimeChannelConfiguration {
        let config = try Self.validatedConfiguration(data)
        guard let account = await accountID() else { throw RuntimeChannelError.unauthorized }
        for grant in config.grants {
            guard grant.accountID == account, !grant.eventKey.isEmpty,
                  let mission = try await coordinator.snapshot(grant.executionID), mission.accountID == account else { throw RuntimeChannelError.unauthorized }
            if grant.scopes.contains(.receiveWake), config.enabled, !grant.revoked {
                guard try await executions.wakeConditions().contains(where: { $0.executionID == grant.executionID && $0.key == grant.eventKey && [.webhook, .mail].contains($0.kind) }) else { throw RuntimeChannelError.unauthorized }
            }
            switch grant.transport {
            case .file:
                if grant.scopes.contains(.receiveWake) { _ = try Self.folder(grant.inboxDirectory) }
                if grant.scopes.contains(.deliverResult) { _ = try Self.folder(grant.outboxDirectory) }
            case .webhook:
                guard let endpoint = grant.endpoint, endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil,
                      endpoint.password == nil, grant.credentialKey?.isEmpty == false else { throw RuntimeChannelError.invalidConfiguration }
                if grant.scopes.contains(.deliverResult), grant.receiverSupportsIdempotency != true { throw RuntimeChannelError.invalidConfiguration }
            case .plugin:
                _ = try sdkGrant(grant)
                if config.enabled, !grant.revoked { _ = try await AgentPluginRegistry.shared.validateChannel(grant: sdkGrant(grant)) }
            case .telegram:
                if config.enabled, !grant.revoked, let telegram = grant.telegram { _ = try RuntimeTelegramClient.token(telegram, store: secureStore) }
            }
        }
        return config
    }
    package func importConfiguration(_ data: Data) async throws {
        let config = try await previewConfiguration(data)
        let wasRunning = running
        await stop()
        defer { running = wasRunning }
        guard let account = await accountID(), config.grants.allSatisfy({ $0.accountID == account }) else { throw RuntimeChannelError.unauthorized }
        let file = directory.appendingPathComponent("grants-v1.json")
        try Self.encoder().encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    package func restartTelegram(grantID: UUID) async throws {
        guard let account = await accountID() else { throw RuntimeChannelError.unauthorized }
        let grant = try currentGrant(grantID, scope: .receiveWake, account: account)
        guard grant.transport == .telegram else { throw RuntimeChannelError.invalidConfiguration }
        if let poll = polling.removeValue(forKey: grantID) { poll.task.cancel(); await poll.task.value }
        telegramConflicts.remove(grantID)
    }
    private func currentGrant(_ id: UUID, scope: RuntimeChannelGrant.Scope, account: UUID) throws -> RuntimeChannelGrant {
        let config = try configuration()
        guard config.enabled, let grant = config.grants.first(where: { $0.id == id }), grant.accountID == account,
              !grant.revoked, grant.expiresAt > .now, grant.scopes.contains(scope), !grant.eventKey.isEmpty else { throw RuntimeChannelError.unauthorized }
        return grant
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func receiptID(grant: RuntimeChannelGrant, eventID: String, direction: ChannelReceipt.Direction) -> String {
        digest(Data((grant.accountID.uuidString + "/" + grant.id.uuidString + "/" + direction.rawValue + "/" + eventID).utf8))
    }
    private func save(_ receipt: ChannelReceipt) throws {
        let file = directory.appendingPathComponent("receipt-" + receipt.id + ".json")
        try Self.encoder().encode(receipt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        receipts[receipt.id] = receipt
    }
    private static func folder(_ raw: String?) throws -> URL {
        guard let raw, raw.hasPrefix("/") else { throw RuntimeChannelError.invalidConfiguration }
        let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RuntimeChannelError.invalidConfiguration }
        guard url.path == url.resolvingSymlinksInPath().path else { throw RuntimeChannelError.invalidConfiguration }
        return url
    }
    package func acceptWebhook(grantID: UUID, body: Data, signature: String) async throws {
        guard running, body.count <= 1_048_576, let account = await accountID() else { throw RuntimeChannelError.unauthorized }
        let grant = try currentGrant(grantID, scope: .receiveWake, account: account)
        guard grant.transport == .webhook, let keyName = grant.credentialKey,
              let key = try secureStore.readData(forKey: keyName), key.count >= 32,
              let bytes = Data(base64Encoded: signature), HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: body, using: SymmetricKey(data: key)) else {
            throw RuntimeChannelError.unauthorized
        }
        try await receive(body: body, grant: grant)
    }
    private func receive(body: Data, grant: RuntimeChannelGrant) async throws {
        guard body.count <= 1_048_576 else { throw RuntimeChannelError.invalidEvent }
        let event = try Self.decoder().decode(RuntimeChannelEvent.self, from: body)
        guard event.version == 1, !event.id.isEmpty, event.id.utf8.count <= 200,
              event.executionID == grant.executionID, event.eventKey == grant.eventKey else {
            throw RuntimeChannelError.invalidEvent
        }
        let id = Self.receiptID(grant: grant, eventID: event.id, direction: .ingress)
        let digest = Self.digest(try Self.encoder().encode(event))
        if let previous = receipts[id] {
            guard previous.digest == digest else { throw RuntimeChannelError.conflict }
            if previous.state == "accepted" { return }
        }
        guard let account = await accountID(), try currentGrant(grant.id, scope: .receiveWake, account: account) == grant,
              let record = try await coordinator.snapshot(grant.executionID), record.accountID == account else { throw RuntimeChannelError.unauthorized }
        let payload = try Self.encoder().encode(event)
        if let previous = receipts[id], previous.state == "received",
           let admitted = try await executions.wakePayload(executionID: grant.executionID, dedupKey: "channel:" + id) {
            guard admitted == payload else { throw RuntimeChannelError.conflict }
            var confirmed = previous; confirmed.state = "accepted"; confirmed.deliveredAt = .now
            try save(confirmed)
            return
        }
        guard event.occurredAt <= Date().addingTimeInterval(90), event.occurredAt >= Date().addingTimeInterval(-86_400) else { throw RuntimeChannelError.invalidEvent }
        guard record.state == .waitingEvent,
              try await executions.wakeConditions().contains(where: { $0.executionID == grant.executionID && $0.key == grant.eventKey && [.webhook, .mail].contains($0.kind) }) else {
            throw RuntimeChannelError.unauthorized
        }
        var receipt = ChannelReceipt(id: id, direction: .ingress, grant: grant, event: event, digest: digest, state: "received")
        try save(receipt)
        // No text is admitted as a new request/correction or used to expand scopes.
        try await coordinator.wake(grant.executionID, key: "channel:" + id, payload: payload)
        guard try await executions.wakePayload(executionID: grant.executionID, dedupKey: "channel:" + id) == payload else { throw RuntimeChannelError.unauthorized }
        receipt.state = "accepted"; receipt.deliveredAt = .now; try save(receipt)
    }
    package func tick() async throws {
        guard running else { return }
        guard let account = await accountID() else { cancelNetworkTasks(all: true); return }
        let config = try configuration()
        if RuntimePrivacyPolicy.isEnabled { cancelNetworkTasks() }
        else { synchronizeTelegram(config, account: account); synchronizePlugins(config, account: account) }
        guard config.enabled else { cancelNetworkTasks(all: true); return }
        for grant in config.grants where grant.accountID == account && !grant.revoked && grant.expiresAt > .now {
            if grant.scopes.contains(.receiveWake), grant.transport == .file {
                let inbox = try Self.folder(grant.inboxDirectory)
                guard inbox != directory.resolvingSymlinksInPath() else { throw RuntimeChannelError.invalidConfiguration }
                let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
                var processed = 0
                for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_048_576 else { continue }
                    let fingerprint = "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                    let key = grant.id.uuidString + ":" + file.path
                    guard inboxFingerprints[key] != fingerprint else { continue }
                    do { try await receive(body: Data(contentsOf: file), grant: grant) }
                    catch { failure = String(describing: error) }
                    inboxFingerprints[key] = fingerprint
                    processed += 1
                    if processed == 20 { break }
                }
            }
            if grant.scopes.contains(.deliverResult), let record = try await coordinator.snapshot(grant.executionID), record.accountID == account,
               let delivery = try await executions.latestDeliveryEnvelope(executionID: grant.executionID) {
                let event = RuntimeChannelEvent(version: 1, id: delivery.id.uuidString.lowercased(), executionID: grant.executionID,
                    eventKey: grant.eventKey, occurredAt: .now, data: .object(["kind": .string("result"), "state": .string(record.state.rawValue),
                        "content": .string(String(decoding: delivery.payload, as: UTF8.self))]))
                let id = Self.receiptID(grant: grant, eventID: event.id, direction: .outbox)
                if receipts[id] == nil {
                    try save(ChannelReceipt(id: id, direction: .outbox, grant: grant, event: event,
                        digest: Self.digest(try Self.encoder().encode(event)), state: "pending"))
                }
            }
        }
        for receipt in receipts.values.filter({ $0.direction == .outbox && ["pending", "sending"].contains($0.state)
            && (!RuntimePrivacyPolicy.isEnabled || $0.grant.transport == .file) && $0.nextAttemptAt <= .now })
            .sorted(by: { $0.nextAttemptAt < $1.nextAttemptAt }) where delivering.count < 2 && delivering[receipt.id] == nil {
            if receipt.grant.transport == .telegram {
                guard !telegramConflicts.contains(receipt.grant.id) else { continue }
                guard let botID = receipt.grant.telegram?.botID, let lease = telegramLeases[botID] else { continue }
                delivering[receipt.id] = Task { [weak self, lease] in
                    defer { withExtendedLifetime(lease) {} }
                    await self?.deliver(receipt.id)
                }
            } else if receipt.grant.transport == .plugin {
                guard !pluginSuspended.contains(receipt.grant.id), let lease = pluginLeases[receipt.grant.id] else { continue }
                delivering[receipt.id] = Task { [weak self, lease] in
                    defer { withExtendedLifetime(lease) {} }
                    await self?.deliver(receipt.id)
                }
            } else { delivering[receipt.id] = Task { [weak self] in await self?.deliver(receipt.id) } }
        }
    }
    private func cancelNetworkTasks(all: Bool = false) {
        for state in polling.values { state.task.cancel(); retiredPolling[state.generation] = state.task }
        polling.removeAll(); telegramLeases.removeAll()
        for receipt in receipts.values where all || receipt.grant.transport != .file { delivering[receipt.id]?.cancel() }
        for (id, state) in pluginPolling { state.task.cancel(); retiredPolling[state.generation] = state.task; closePlugin(id) }
        pluginPolling.removeAll()
        for id in Set(pluginSessions.keys).union(pluginStarting.keys) { closePlugin(id) }
        pluginLeases.removeAll()
    }
    private func telegramAuthorized(_ grant: RuntimeChannelGrant) async -> Bool {
        guard running, !RuntimePrivacyPolicy.isEnabled, let account = await accountID() else { return false }
        return (try? currentGrant(grant.id, scope: .receiveWake, account: account)) == grant
    }
    private func reportTelegram(_ grantID: UUID, _ message: String) {
        failure = message
        if ["telegram_conflicting_owner", "telegram_poll_stopped"].contains(message) { telegramConflicts.insert(grantID) }
    }
    private func synchronizeTelegram(_ config: RuntimeChannelConfiguration, account: UUID) {
        let allGrants = config.enabled ? config.grants.filter { $0.transport == .telegram && $0.accountID == account
            && !$0.revoked && $0.expiresAt > .now && !$0.scopes.isEmpty } : []
        let bots = Set(allGrants.compactMap { $0.telegram?.botID })
        for bot in telegramLeases.keys where !bots.contains(bot) { telegramLeases.removeValue(forKey: bot) }
        for bot in bots where telegramLeases[bot] == nil {
            do { telegramLeases[bot] = try RuntimeLease(url: directory.appendingPathComponent("telegram-" + String(bot) + ".lock")) }
            catch { failure = "telegram_owner_unavailable" }
        }
        let grants = allGrants.filter { $0.scopes.contains(.receiveWake) }
        for (id, state) in polling where !grants.contains(state.grant) {
            state.task.cancel(); retiredPolling[state.generation] = state.task; polling.removeValue(forKey: id)
        }
        for grant in grants where polling[grant.id] == nil && !telegramConflicts.contains(grant.id) {
            do {
                guard let bot = grant.telegram?.botID, let lease = telegramLeases[bot] else { continue }
                let poller = try RuntimeTelegramPoller(grant: grant, directory: directory, secureStore: secureStore, lease: lease,
                    authorized: { [weak self] in await self?.telegramAuthorized(grant) == true },
                    accept: { [weak self] update in guard let self else { throw CancellationError() }; return try await self.receiveTelegram(update, grant: grant) },
                    report: { [weak self] message in await self?.reportTelegram(grant.id, message) })
                let generation = UUID()
                polling[grant.id] = Polling(generation: generation, grant: grant, task: Task { [weak self] in
                    await poller.run()
                    await self?.pollingFinished(grantID: grant.id, generation: generation)
                })
            } catch { failure = "telegram_owner_or_configuration_unavailable" }
        }
    }
    private func pollingFinished(grantID: UUID, generation: UUID) {
        if polling[grantID]?.generation == generation { polling.removeValue(forKey: grantID) }
        retiredPolling.removeValue(forKey: generation)
    }
    private func receiveTelegram(_ update: RuntimeTelegramUpdate, grant: RuntimeChannelGrant) async throws -> Bool {
        guard await telegramAuthorized(grant) else { throw CancellationError() }
        guard let target = grant.telegram, let message = update.message, message.chat.id == target.chatID,
              let sender = message.from, !sender.is_bot, target.senderIDs.contains(sender.id), let text = message.text,
              !text.isEmpty, text.utf8.count <= 65_536 else { return false }
        let event = RuntimeChannelEvent(version: 1, id: "telegram:" + String(target.botID) + ":" + String(update.update_id),
            executionID: grant.executionID, eventKey: grant.eventKey, occurredAt: Date(timeIntervalSince1970: Double(message.date)),
            data: .object(["kind": .string("telegram_message"), "text": .string(text),
                "chat_id": .string(String(target.chatID)), "sender_id": .string(String(sender.id)), "message_id": .string(String(message.message_id))]))
        do { try await receive(body: Self.encoder().encode(event), grant: grant); return true }
        catch RuntimeChannelError.unauthorized { return false }
        catch RuntimeChannelError.invalidEvent { return false }
    }
    package struct DeliveryStatus: Codable, Sendable { package var transport: RuntimeChannelGrant.Transport; package var id: String; package var state: String; package var messageID: Int64?; package var error: String?; package var pluginRemoteReceiptID: String? }
    package func deliveryStatuses() async -> [DeliveryStatus] {
        guard let account = await accountID() else { return [] }
        return receipts.values.filter { $0.direction == .outbox && $0.grant.accountID == account }.sorted { $0.id < $1.id }.map {
            DeliveryStatus(transport: $0.grant.transport, id: $0.id, state: $0.state, messageID: $0.telegramMessageID, error: $0.lastError, pluginRemoteReceiptID: $0.pluginReceiptID)
        }
    }
    /// Local operator decision, never granted by an incoming Telegram message.
    package func reconcileTelegram(receiptID: String, confirmedMessageID: Int64?, authorizeResend: Bool) async throws {
        guard var receipt = receipts[receiptID], receipt.grant.transport == .telegram, receipt.state == "outcome_unknown",
              let account = await accountID(), try currentGrant(receipt.grant.id, scope: .deliverResult, account: account) == receipt.grant,
              (confirmedMessageID != nil) != authorizeResend else { throw RuntimeChannelError.unauthorized }
        if let id = confirmedMessageID {
            guard id > 0 else { throw RuntimeChannelError.invalidEvent }
            receipt.telegramMessageID = id; receipt.state = "delivered"; receipt.deliveredAt = .now
            receipt.lastError = "telegram_delivery_manually_confirmed"
        } else {
            receipt.state = "pending"; receipt.nextAttemptAt = .now; receipt.lastError = "telegram_resend_explicitly_authorized"
        }
        try save(receipt)
    }
    private func sdkGrant(_ grant: RuntimeChannelGrant) throws -> AgentChannelGrant {
        guard grant.transport == .plugin, let p = grant.plugin, p.version == 1, p.apiVersion == 1 else { throw RuntimeChannelError.invalidConfiguration }
        return AgentChannelGrant(id: grant.id, accountID: grant.accountID, executionID: grant.executionID, eventKey: grant.eventKey,
            scopes: Set(grant.scopes.compactMap { AgentChannelGrant.Scope(rawValue: $0.rawValue) }), expiresAt: grant.expiresAt,
            pluginID: p.pluginID, pluginVersion: p.pluginVersion, configuration: p.configuration)
    }
    private func pluginAuthorized(_ snapshot: AgentChannelGrant, scope: AgentChannelGrant.Scope,
        expected: RuntimeChannelGrant? = nil) async throws -> Bool {
        guard running, !RuntimePrivacyPolicy.isEnabled, let account = await accountID(),
              let localScope = RuntimeChannelGrant.Scope(rawValue: scope.rawValue) else { return false }
        let grant = try currentGrant(snapshot.id, scope: localScope, account: account)
        guard expected == nil || expected == grant, try sdkGrant(grant) == snapshot,
              let record = try await coordinator.snapshot(grant.executionID), record.accountID == account else { return false }
        if scope == .deliverResult { return true }
        if try await newPluginIngressAllowed(grant) { return true }
        // Allows exact pending batch reconciliation/ack and credentials of the
        // existing session after wake consumed its condition, never a new wake.
        return pluginIngress.values.contains { $0.grant == grant }
    }
    private func newPluginIngressAllowed(_ grant: RuntimeChannelGrant) async throws -> Bool {
        guard let account = await accountID(), try currentGrant(grant.id, scope: .receiveWake, account: account) == grant,
              let record = try await coordinator.snapshot(grant.executionID), record.accountID == account, record.state == .waitingEvent else { return false }
        return try await executions.wakeConditions().contains { $0.executionID == grant.executionID && $0.key == grant.eventKey && [.webhook, .mail].contains($0.kind) }
    }
    private func pluginCredential(_ grant: RuntimeChannelGrant) async throws -> Data? {
        guard let scope = grant.scopes.first, try await pluginAuthorized(sdkGrant(grant), scope: AgentChannelGrant.Scope(rawValue: scope.rawValue)!, expected: grant) else { throw RuntimeChannelError.unauthorized }
        guard let key = grant.credentialKey else { return nil }
        let bytes = try secureStore.readData(forKey: key)
        guard try await pluginAuthorized(sdkGrant(grant), scope: AgentChannelGrant.Scope(rawValue: scope.rawValue)!, expected: grant) else { throw RuntimeChannelError.unauthorized }
        return bytes
    }
    private func pluginSession(_ grant: RuntimeChannelGrant) async throws -> any AgentChannelSession {
        if let session = pluginSessions[grant.id] { return session }
        if let task = pluginStarting[grant.id] { return try await task.value }
        guard pluginClosing[grant.id] == nil, pluginLeases[grant.id] != nil else { throw AgentChannelPluginError.conflictingSession }
        let snapshot = try sdkGrant(grant)
        let config = AgentChannelPluginConfiguration(grant: snapshot, credentials: { [weak self] in
            guard let self else { throw RuntimeChannelError.unauthorized }; return try await self.pluginCredential(grant)
        })
        let task = Task { [weak self] in
            try await AgentPluginRegistry.shared.makeChannel(configuration: config, authorize: { [weak self] sdk, scope in
                guard let self else { return false }; return try await self.pluginAuthorized(sdk, scope: scope, expected: grant)
            })
        }
        pluginStarting[grant.id] = task
        do {
            let session = try await task.value
            pluginStarting.removeValue(forKey: grant.id)
            guard running, !RuntimePrivacyPolicy.isEnabled, let account = await accountID(),
                  try configuration().grants.first(where: { $0.id == grant.id && $0.accountID == account }) == grant,
                  pluginClosing[grant.id] == nil else {
                await AgentPluginRegistry.shared.closeChannel(grantID: grant.id)
                throw RuntimeChannelError.unauthorized
            }
            pluginSessions[grant.id] = session
            return session
        } catch { pluginStarting.removeValue(forKey: grant.id); throw error }
    }
    private func closePlugin(_ id: UUID) {
        guard pluginClosing[id] == nil else { return }
        pluginStarting[id]?.cancel(); pluginSessions.removeValue(forKey: id)
        let lease = pluginLeases[id]
        pluginClosing[id] = Task { [weak self, lease] in
            defer { withExtendedLifetime(lease) {} }
            await AgentPluginRegistry.shared.closeChannel(grantID: id)
            await self?.pluginClosed(id)
        }
    }
    private func pluginClosed(_ id: UUID) { pluginClosing.removeValue(forKey: id) }
    private func synchronizePlugins(_ config: RuntimeChannelConfiguration, account: UUID) {
        let grants = config.enabled ? config.grants.filter { $0.transport == .plugin && $0.accountID == account
            && !$0.revoked && $0.expiresAt > .now && !$0.scopes.isEmpty } : []
        let ids = Set(grants.map(\.id))
        for id in Set(pluginSessions.keys).union(pluginStarting.keys).union(pluginLeases.keys) where !ids.contains(id) {
            pluginPolling[id]?.task.cancel(); closePlugin(id); pluginLeases.removeValue(forKey: id)
        }
        for (id, state) in pluginPolling where !grants.contains(state.grant) {
            state.task.cancel(); retiredPolling[state.generation] = state.task
            pluginPolling.removeValue(forKey: id); closePlugin(id)
        }
        for grant in grants where pluginClosing[grant.id] == nil {
            if pluginLeases[grant.id] == nil {
                do { pluginLeases[grant.id] = try RuntimeLease(url: directory.appendingPathComponent("plugin-" + grant.id.uuidString + ".lock")) }
                catch { failure = "plugin_channel_owner_unavailable"; continue }
            }
            guard grant.scopes.contains(.receiveWake), pluginPolling[grant.id] == nil, !pluginSuspended.contains(grant.id),
                  let lease = pluginLeases[grant.id] else { continue }
            let generation = UUID()
            pluginPolling[grant.id] = Polling(generation: generation, grant: grant, task: Task { [weak self, lease] in
                defer { withExtendedLifetime(lease) {} }
                await self?.pollPlugin(grant)
                await self?.pluginPollingFinished(grant.id, generation: generation)
            })
        }
    }
    private func pluginPollingFinished(_ id: UUID, generation: UUID) {
        if pluginPolling[id]?.generation == generation { pluginPolling.removeValue(forKey: id) }
        retiredPolling.removeValue(forKey: generation)
    }
    private func savePluginIngress(_ value: RuntimePluginIngress) throws {
        let file = directory.appendingPathComponent("plugin-ingress-" + value.hostReceiptID + ".json")
        try Self.encoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        pluginIngress[value.hostReceiptID] = value
    }
    private func storePluginBatch(_ events: [AgentChannelEvent], grant: RuntimeChannelGrant) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for event in events {
            let id = Self.receiptID(grant: grant, eventID: event.id, direction: .ingress)
            let data = try encoder.encode(event); let digest = Self.digest(data)
            if let previous = pluginIngress[id] {
                guard previous.grant == grant, previous.digest == digest, previous.encodedEvent == data else { throw RuntimeChannelError.conflict }
            } else {
                try savePluginIngress(RuntimePluginIngress(grant: grant, encodedEvent: data, hostReceiptID: id, digest: digest))
            }
        }
    }
    private func admitPlugin(_ event: AgentChannelEvent, grant: RuntimeChannelGrant) async throws -> RuntimePluginIngress {
        let id = Self.receiptID(grant: grant, eventID: event.id, direction: .ingress)
        guard var receipt = pluginIngress[id], receipt.grant == grant else { throw RuntimeChannelError.conflict }
        if receipt.disposition != nil { return receipt }
        let value = RuntimeChannelEvent(version: 1, id: event.id, executionID: event.executionID, eventKey: event.eventKey,
            occurredAt: event.occurredAt, data: .object(["kind": .string("plugin_event"), "plugin_id": .string(grant.plugin!.pluginID),
                "payload_base64": .string(event.payload.base64EncodedString())]))
        do { try await receive(body: Self.encoder().encode(value), grant: grant); receipt.disposition = "accepted" }
        catch RuntimeChannelError.unauthorized { receipt.disposition = "rejected" }
        catch RuntimeChannelError.invalidEvent { receipt.disposition = "rejected" }
        try savePluginIngress(receipt)
        return receipt
    }
    private func pollPlugin(_ grant: RuntimeChannelGrant) async {
        defer { closePlugin(grant.id) }
        do {
            let snapshot = try sdkGrant(grant)
            while !Task.isCancelled {
                guard try await pluginAuthorized(snapshot, scope: .receiveWake, expected: grant) else { return }
                let pending = pluginIngress.values.contains { $0.grant == grant && !$0.acknowledged }
                if !pending, !(try await newPluginIngressAllowed(grant)) {
                    try await Task.sleep(for: .seconds(1)); continue
                }
                let channel = try await pluginSession(grant)
                let events = try await channel.poll()
                guard try await pluginAuthorized(snapshot, scope: .receiveWake, expected: grant) else { return }
                try storePluginBatch(events, grant: grant) // entire batch before any wake or ACK.
                for event in events {
                    var receipt = try await admitPlugin(event, grant: grant)
                    guard try await pluginAuthorized(snapshot, scope: .receiveWake, expected: grant) else { return }
                    try await channel.acknowledge(receipt.receipt())
                    receipt.acknowledged = true; try savePluginIngress(receipt)
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {} catch {
            failure = "plugin_poll_suspended"; pluginSuspended.insert(grant.id)
        }
        closePlugin(grant.id)
    }
    package func restartChannel(grantID: UUID) async throws {
        guard let account = await accountID(), let grant = try configuration().grants.first(where: { $0.id == grantID && $0.accountID == account }) else { throw RuntimeChannelError.unauthorized }
        if grant.transport == .telegram { try await restartTelegram(grantID: grantID) }
        else if grant.transport == .plugin { try await restartPlugin(grantID: grantID) }
        else { throw RuntimeChannelError.invalidConfiguration }
    }
    package func restartPlugin(grantID: UUID) async throws {
        guard let account = await accountID() else { throw RuntimeChannelError.unauthorized }
        let config = try configuration()
        guard config.enabled, let grant = config.grants.first(where: { $0.id == grantID && $0.accountID == account }),
              grant.transport == .plugin, !grant.revoked, grant.expiresAt > .now else { throw RuntimeChannelError.unauthorized }
        if let state = pluginPolling.removeValue(forKey: grantID) { state.task.cancel(); await state.task.value }
        closePlugin(grantID)
        if let task = pluginClosing[grantID] { await task.value }
        pluginSuspended.remove(grantID)
    }
    package func reconcilePlugin(receiptID: String, confirmedRemoteReceiptID: String?, authorizeResend: Bool) async throws {
        guard var receipt = receipts[receiptID], receipt.grant.transport == .plugin, receipt.state == "outcome_unknown",
              let account = await accountID(), try currentGrant(receipt.grant.id, scope: .deliverResult, account: account) == receipt.grant,
              (confirmedRemoteReceiptID != nil) != authorizeResend else { throw RuntimeChannelError.unauthorized }
        if let value = confirmedRemoteReceiptID {
            guard !value.isEmpty, value.utf8.count <= 512 else { throw RuntimeChannelError.invalidEvent }
            receipt.pluginReceiptID = value; receipt.state = "delivered"; receipt.deliveredAt = .now
            receipt.lastError = "plugin_delivery_manually_confirmed"
        } else {
            receipt.state = "pending"; receipt.nextAttemptAt = .now; receipt.lastError = "plugin_resend_explicitly_authorized"
        }
        try save(receipt)
    }
    private func deliver(_ id: String) async {
        defer { delivering.removeValue(forKey: id) }
        guard running, var receipt = receipts[id], let account = await accountID() else { return }
        var telegramEffectStarted = false
        var pluginEffectStarted = false
        do {
            let grant = try currentGrant(receipt.grant.id, scope: .deliverResult, account: account)
            // A scope/target change revokes pending work rather than redirecting it.
            guard grant == receipt.grant, let record = try await coordinator.snapshot(grant.executionID), record.accountID == account else { throw RuntimeChannelError.unauthorized }
            try Task.checkCancellation()
            receipt.attempts += 1; receipt.state = "sending"; try save(receipt)
            let data = try Self.encoder().encode(receipt.event)
            switch grant.transport {
            case .file:
                let outbox = try Self.folder(grant.outboxDirectory)
                guard outbox != directory.resolvingSymlinksInPath() else { throw RuntimeChannelError.invalidConfiguration }
                let file = outbox.appendingPathComponent("aim-" + id + ".json")
                if FileManager.default.fileExists(atPath: file.path) {
                    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                          Self.digest(try Data(contentsOf: file)) == receipt.digest else { throw RuntimeChannelError.conflict }
                } else {
                    // A hard link publishes complete bytes atomically and never
                    // replaces an existing receipt, even with a concurrent writer.
                    let temporary = outbox.appendingPathComponent(".aim-delivery-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                    guard Darwin.link(temporary.path, file.path) == 0 else { throw RuntimeChannelError.conflict }
                }
            case .plugin:
                try RuntimePrivacyPolicy.requireNetwork(); try Task.checkCancellation()
                let channel = try await pluginSession(grant)
                let event = AgentChannelEvent(id: receipt.event.id, accountID: grant.accountID, executionID: grant.executionID,
                    eventKey: grant.eventKey, occurredAt: receipt.event.occurredAt, payload: data)
                guard try await pluginAuthorized(sdkGrant(grant), scope: .deliverResult) else { throw RuntimeChannelError.unauthorized }
                pluginEffectStarted = true
                let result = try await channel.deliver(AgentChannelDelivery(id: receipt.id, digest: receipt.digest, event: event))
                guard result.deliveryID == receipt.id, result.digest == receipt.digest, result.state == .confirmed else { throw AgentChannelPluginError.invalidReceipt }
                receipt.pluginReceiptID = result.remoteReceiptID
                receipt.state = "delivered"; receipt.deliveredAt = .now; receipt.lastError = nil; try save(receipt)
                return
            case .telegram:
                try RuntimePrivacyPolicy.requireNetwork(); try Task.checkCancellation()
                guard let target = grant.telegram else { throw RuntimeTelegramError.invalidConfiguration }
                let token = try RuntimeTelegramClient.token(target, store: secureStore)
                let text = "AIM result " + receipt.event.id + "\n" + (receipt.event.data.objectValue?["content"]?.stringValue ?? "")
                guard !text.isEmpty, text.count <= 4096 else { throw RuntimeTelegramError.oversized }
                guard running, let currentAccount = await accountID(),
                      try currentGrant(grant.id, scope: .deliverResult, account: currentAccount) == grant else { throw RuntimeChannelError.unauthorized }
                // This persisted boundary precedes the sole sendMessage call.
                telegramEffectStarted = true
                receipt.telegramMessageID = try await telegramClient.send(token: token, chatID: target.chatID, text: text)
                receipt.state = "delivered"; receipt.deliveredAt = .now; receipt.lastError = nil
                try save(receipt)
                return
            case .webhook:
                try RuntimePrivacyPolicy.requireNetwork()
                guard grant.receiverSupportsIdempotency == true, let endpoint = grant.endpoint,
                      endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
                      let keyName = grant.credentialKey, let key = try secureStore.readData(forKey: keyName), key.count >= 32 else { throw RuntimeChannelError.missingCredential }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"; request.httpBody = data
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(id, forHTTPHeaderField: "Idempotency-Key")
                request.setValue(Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))).base64EncodedString(), forHTTPHeaderField: "X-AIM-Signature")
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw RuntimeChannelError.deliveryUnconfirmed }
                var bytes = Data()
                for try await byte in stream {
                    guard bytes.count < 65_536 else { throw RuntimeChannelError.deliveryUnconfirmed }
                    bytes.append(byte)
                }
                guard let ack = try JSONDecoder().decode(RemoteJSONValue.self, from: bytes).objectValue,
                      ack["version"]?.numberValue == 1, ack["event_id"]?.stringValue == id, ack["accepted"] == .bool(true) else {
                    throw RuntimeChannelError.deliveryUnconfirmed
                }
            }
            try Task.checkCancellation()
            guard let current = await accountID(), try currentGrant(grant.id, scope: .deliverResult, account: current) == grant else { throw RuntimeChannelError.unauthorized }
            receipt.state = "delivered"; receipt.deliveredAt = .now; receipt.lastError = nil; try save(receipt)
        } catch {
            if pluginEffectStarted {
                receipt.state = "outcome_unknown"; receipt.lastError = "plugin_delivery_outcome_unknown"
            } else if telegramEffectStarted {
                if case RuntimeTelegramError.rejected(let code) = error {
                    receipt.state = code == 429 ? "pending" : "blocked"
                    receipt.lastError = "telegram_rejected_" + String(code)
                } else {
                    receipt.state = "outcome_unknown"; receipt.lastError = "telegram_delivery_outcome_unknown"
                }
            } else {
                if case RuntimeTelegramError.oversized = error { receipt.state = "blocked"; receipt.lastError = "telegram_message_too_long" }
                else { receipt.state = "pending"; receipt.lastError = String(describing: type(of: error)) }
            }
            receipt.nextAttemptAt = Date().addingTimeInterval(min(3_600, pow(2, Double(min(receipt.attempts, 10)))))
            try? save(receipt); failure = receipt.lastError
        }
    }
}
