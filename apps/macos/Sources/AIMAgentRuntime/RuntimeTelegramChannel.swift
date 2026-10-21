import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

package struct RuntimeTelegramGrant: Codable, Sendable, Equatable {
    package var version: Int
    package var botID: Int64
    package var tokenKey: String
    package var chatID: Int64
    package var senderIDs: Set<Int64>
    package var reconciliation: String // v1: manual only, never an automatic resend.
}
package struct RuntimeTelegramUpdate: Codable, Sendable {
    package struct Message: Codable, Sendable {
        package struct User: Codable, Sendable { var id: Int64; var is_bot: Bool }
        package struct Chat: Codable, Sendable { var id: Int64 }
        var message_id: Int64
        var date: Int64
        var chat: Chat
        var from: User?
        var text: String?
    }
    var update_id: Int64
    var message: Message?
}
package enum RuntimeTelegramError: Error, Sendable {
    case invalidConfiguration, unavailableCredential, conflictingOwner, rejected(Int), invalidResponse, oversized, outcomeUnknown
}
private final class TelegramHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
package struct RuntimeTelegramClient: Sendable {
    private let session: URLSession
    package init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 35
        session = AIMManagedNetworkSession.make(configuration: config, delegate: TelegramHTTPDelegate(), delegateQueue: nil)
    }
    package static func token(_ grant: RuntimeTelegramGrant, store: any SecureStoring) throws -> String {
        guard grant.version == 1, grant.botID > 0, grant.botID < 9_007_199_254_740_992,
              grant.chatID != 0, grant.chatID > -9_007_199_254_740_992, grant.chatID < 9_007_199_254_740_992, !grant.senderIDs.isEmpty,
              grant.senderIDs.allSatisfy({ $0 > 0 && $0 < 9_007_199_254_740_992 }), !grant.tokenKey.isEmpty, grant.reconciliation == "manual",
              let bytes = try store.readData(forKey: grant.tokenKey), let token = String(data: bytes, encoding: .utf8) else { throw RuntimeTelegramError.unavailableCredential }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, Int64(parts[0]) == grant.botID, parts[1].count >= 20,
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw RuntimeTelegramError.unavailableCredential }
        return token
    }
    private func request(method: String, token: String, payload: [String: RemoteJSONValue]) async throws -> [String: RemoteJSONValue] {
        try RuntimePrivacyPolicy.requireNetwork(); try Task.checkCancellation()
        // Fixed official origin; token never appears in logs, receipts or errors.
        let url = URL(string: "https://api.telegram.org/bot" + token + "/" + method)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (stream, response) = try await session.bytes(for: request)
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < 1_048_576 else { throw RuntimeTelegramError.oversized }
            bytes.append(byte)
        }
        guard let response = response as? HTTPURLResponse else { throw RuntimeTelegramError.invalidResponse }
        if method == "getUpdates", response.statusCode == 409 { throw RuntimeTelegramError.conflictingOwner }
        let json = try JSONDecoder().decode(RemoteJSONValue.self, from: bytes).objectValue
        if let json, json["ok"] == .bool(false), let code = json["error_code"]?.numberValue, code >= 400, code < 500 {
            throw RuntimeTelegramError.rejected(Int(code))
        }
        guard (200..<300).contains(response.statusCode), let json, json["ok"] == .bool(true) else { throw RuntimeTelegramError.invalidResponse }
        return json
    }
    package func updates(token: String, offset: Int64?) async throws -> [RemoteJSONValue] {
        var parameters: [String: RemoteJSONValue] = ["timeout": .number(20), "limit": .number(20), "allowed_updates": .array([.string("message")])]
        if let offset { parameters["offset"] = .number(Double(offset)) }
        let json = try await request(method: "getUpdates", token: token, payload: parameters)
        guard let result = json["result"]?.arrayValue else { throw RuntimeTelegramError.invalidResponse }
        return result
    }
    package func send(token: String, chatID: Int64, text: String) async throws -> Int64 {
        // No splitting: one journal receipt corresponds to one Telegram effect.
        guard !text.isEmpty, text.count <= 4096 else { throw RuntimeTelegramError.oversized }
        let json = try await request(method: "sendMessage", token: token,
            payload: ["chat_id": .number(Double(chatID)), "text": .string(text)])
        guard let result = json["result"]?.objectValue,
              result["chat"]?.objectValue?["id"]?.numberValue == Double(chatID),
              let id = result["message_id"]?.numberValue, id > 0, id.rounded() == id, id < 9_007_199_254_740_992 else { throw RuntimeTelegramError.invalidResponse }
        return Int64(id)
    }
}

/// One local lease per bot ID, held across long polling and offset acknowledgments.
/// Operators must deploy one owner globally; Telegram 409 permanently suspends
/// this poller rather than competing with a webhook or another remote owner.
package actor RuntimeTelegramPoller {
    private struct Ledger: Codable {
        var version = 1
        var grant: RuntimeChannelGrant
        var offset: Int64?
        var pending: RemoteJSONValue?
        var lastState: String?
        var lastUpdateID: Int64?
    }
    private let file: URL
    private let grant: RuntimeChannelGrant
    private let secureStore: any SecureStoring
    private let client = RuntimeTelegramClient()
    private let lease: RuntimeLease
    private var ledger: Ledger
    private let authorized: @Sendable () async -> Bool
    private let accept: @Sendable (RuntimeTelegramUpdate) async throws -> Bool
    private let report: @Sendable (String) async -> Void
    package init(grant: RuntimeChannelGrant, directory: URL, secureStore: any SecureStoring, lease: RuntimeLease,
        authorized: @escaping @Sendable () async -> Bool, accept: @escaping @Sendable (RuntimeTelegramUpdate) async throws -> Bool,
        report: @escaping @Sendable (String) async -> Void) throws {
        guard let telegram = grant.telegram else { throw RuntimeTelegramError.invalidConfiguration }
        self.grant = grant; self.secureStore = secureStore; self.authorized = authorized; self.accept = accept; self.report = report
        file = directory.appendingPathComponent("telegram-" + String(telegram.botID) + ".json")
        self.lease = lease
        if FileManager.default.fileExists(atPath: file.path) {
            let props = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard props.isRegularFile == true, props.isSymbolicLink != true, (props.fileSize ?? Int.max) <= 2_097_152 else { throw RuntimeTelegramError.invalidConfiguration }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let restored = try decoder.decode(Ledger.self, from: Data(contentsOf: file))
            guard restored.version == 1, restored.offset.map({ $0 >= 0 }) ?? true else { throw RuntimeTelegramError.invalidConfiguration }
            ledger = restored
            // Explicit configuration may renew/reassign an idle bot, retaining
            // its committed offset. A pending old update cannot change authority.
            if ledger.grant != grant {
                guard ledger.pending == nil else { throw RuntimeTelegramError.invalidConfiguration }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let previous = directory.appendingPathComponent("telegram-grant-transition-" + String(telegram.botID) + "-" + UUID().uuidString + ".json")
                try encoder.encode(ledger).write(to: previous, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
                var renewed = ledger; renewed.grant = grant
                try encoder.encode(renewed).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                ledger = renewed
            }
        } else { ledger = Ledger(grant: grant) }
    }
    private func persist(_ candidate: Ledger) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        try encoder.encode(candidate).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        ledger = candidate
    }
    private func evidence(_ raw: RemoteJSONValue, id: Int64, state: String) throws {
        guard let bot = grant.telegram?.botID else { throw RuntimeTelegramError.invalidConfiguration }
        let record = file.deletingLastPathComponent().appendingPathComponent("telegram-update-" + String(bot) + "-" + String(id) + ".json")
        let data: RemoteJSONValue = .object(["version": .number(1), "grant_id": .string(grant.id.uuidString),
            "update": raw, "state": .string(state)])
        try JSONEncoder().encode(data).write(to: record, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    }
    private func consume(_ raw: RemoteJSONValue) async throws {
        let update = try JSONDecoder().decode(RuntimeTelegramUpdate.self, from: JSONEncoder().encode(raw))
        guard update.update_id >= 0, update.update_id < Int64.max else { throw RuntimeTelegramError.invalidResponse }
        if let offset = ledger.offset, update.update_id < offset { return }
        // Persist raw update before admitting its data or advancing Telegram offset.
        var pending = ledger; pending.pending = raw; pending.lastState = "received"
        try evidence(raw, id: update.update_id, state: "received"); try persist(pending)
        guard await authorized(), !Task.isCancelled, !RuntimePrivacyPolicy.isEnabled else { throw CancellationError() }
        let accepted = try await accept(update)
        guard await authorized(), !Task.isCancelled, !RuntimePrivacyPolicy.isEnabled else { throw CancellationError() }
        let state = accepted ? "accepted" : "ignored"
        try evidence(raw, id: update.update_id, state: state)
        var finished = ledger; finished.lastState = state; finished.lastUpdateID = update.update_id
        finished.offset = update.update_id + 1; finished.pending = nil; try persist(finished)
    }
    package func run() async {
        defer { withExtendedLifetime(lease) {} }
        do {
            guard let telegram = grant.telegram else { throw RuntimeTelegramError.invalidConfiguration }
            while !Task.isCancelled {
                guard await authorized(), !RuntimePrivacyPolicy.isEnabled else { return }
                let token = try RuntimeTelegramClient.token(telegram, store: secureStore)
                if let pending = ledger.pending { try await consume(pending) }
                do {
                    let updates = try await client.updates(token: token, offset: ledger.offset)
                    guard await authorized(), !RuntimePrivacyPolicy.isEnabled else { return }
                    for update in updates { try await consume(update) }
                } catch RuntimeTelegramError.conflictingOwner {
                    await report("telegram_conflicting_owner"); return
                } catch is CancellationError { return }
                catch {
                    await report("telegram_poll_unconfirmed")
                    try await Task.sleep(for: .seconds(10))
                }
            }
        } catch is CancellationError {} catch { await report("telegram_poll_stopped") }
    }
}
