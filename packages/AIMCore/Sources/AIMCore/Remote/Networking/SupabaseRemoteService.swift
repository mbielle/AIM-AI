import Foundation
import CryptoKit
import OSLog
import Supabase

actor SupabaseRemoteService: RemoteServicing, RemoteAccessPolicyReceiving {
    private var localAccessPolicy = RemoteLocalAccessPolicy()
    func setLocalAccessPolicy(_ policy: RemoteLocalAccessPolicy) {
        localAccessPolicy = policy
        for (scope, task) in keyRequestTasks where scope.split(separator: ":").contains(where: { policy.isSuspended(String($0)) }) { task.cancel() }
    }
    private static let pairingLogger = Logger(subsystem: "com.aimai.ios", category: "RemotePairing")
    private static let commandLogger = Logger(subsystem: "com.aimai.ios", category: "RemoteCommand")
    private let client: SupabaseClient
    private let relayIdentifier: String?
    private let identities: RemoteDeviceIdentityStore
    private var cachedKeys: [String: RemoteMirrorKeyCacheEntry] = [:]
    private var keyRequests: [String: Date] = [:]
    private var keyRequestTasks: [String: Task<Void, Never>] = [:]
    private var keyRequestIDs: [String: UUID] = [:]
    private var keyRequestFailures: [String: RemoteCommandFailure] = [:]
    private var verifiedKeyReplies: [String: (date: Date, version: Int)] = [:]
    private var linkDiagnostics: [String: RemoteLinkDiagnostic] = [:]
    private var reportedFieldStates: [String: RemoteReadState] = [:]
    private var registeredPublicKey: String?
    private var diagnosticContext: RemoteMirrorKeyContext?
    private var localEvents: [UUID: AsyncStream<RemoteEvent>.Continuation] = [:]
    private var diagnosticEntries: [RemoteDiagnosticEntry] = []
    private var pendingCommands: [String: PendingCommand] = [:]
    private let continuityCommands: RemoteContinuityCommandStore
    private var unlockToken: RemoteUnlockToken?
    private var unlockTokenAccountID: UUID?
    private var securityGeneration = UUID()

    init(client: SupabaseClient, secureStore: any SecureStoring, relayURL: URL? = nil) {
        self.client = client
        relayIdentifier = relayURL?.host.map(RemoteDiagnosticPrivacy.identifier)
        identities = RemoteDeviceIdentityStore(secureStore: secureStore)
        continuityCommands = RemoteContinuityCommandStore(secureStore: secureStore)
    }

    func diagnosticReport() async -> RemoteDiagnosticReport {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return .init(formatVersion: 2, appVersion: version, entries: diagnosticEntries, links: linkDiagnostics.values.sorted { $0.machineIdentifier < $1.machineIdentifier },
            installationIdentifier: Bundle.main.bundleIdentifier,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            relayIdentifier: relayIdentifier)
    }

    func loadOverview() async throws -> RemoteOverview {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            _ = try await client.auth.session
        } catch {
            throw pairingFailure(stage: .authentication, error: error)
        }
        do {
            let identity = try identities.identity()
            let context = try keyContext(identity)
            let deviceRow: DeviceRow? = try await client
                .from("remote_devices")
                .select("id,revoked_at,expires_at,public_key")
                .eq("id", value: identity.deviceID)
                .maybeSingle()
                .execute()
                .value
            try validateKeyContext(context)
            registeredPublicKey = deviceRow?.publicKey
            let state = connectionState(deviceRow: deviceRow, identity: identity)

            do {
                async let machineRequest: [MachineRow] = client
                    .from("remote_machines")
                    .select("id,name,platform,app_version,last_seen_at,key_version,capabilities")
                    .order("last_seen_at", ascending: false)
                    .execute()
                    .value
                // The session-management migration is additive and the iPhone can be
                // updated before the linked Supabase project. PostgREST rejects the
                // entire select when even one requested column is absent, which used
                // to make a healthy pairing look disconnected. Retry the legacy
                // projection so the core Remote experience remains available while
                // the migration rolls out.
                async let sessionRequest = loadSessionRows()
                let (machineRows, sessionRows) = try await (machineRequest, sessionRequest)
                var machines: [RemoteMachine] = []
                var overviewKeys: [String: [Int: Data]] = [:]
                for row in machineRows {
                    try validateKeyContext(context)
                    let (machine, keys) = try await machine(row, identity: identity)
                    machines.append(machine)
                    overviewKeys[row.id] = keys
                }
                let machineVersions = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.keyVersion) })
                var sessions: [RemoteSession] = []
                for row in sessionRows {
                    try validateKeyContext(context)
                    if overviewKeys[row.machineID] == nil {
                        overviewKeys[row.machineID] = try await mirrorKeys(machineID: row.machineID, identity: identity)
                    }
                    sessions.append(try await session(row, machineVersion: machineVersions[row.machineID] ?? nil,
                        identity: identity, overviewKeys: overviewKeys[row.machineID] ?? [:]))
                }
                try validateKeyContext(context)
                return RemoteOverview(
                    connectionState: state,
                    machines: machines,
                    sessions: sessions
                )
            } catch {
                // Reading the mirror is intentionally independent from pairing. If an
                // older account has no mirror rows yet, keep the actionable pairing
                // state instead of turning it into a misleading network failure.
                guard state != .paired else { throw error }
                return RemoteOverview(connectionState: state, machines: [], sessions: [])
            }
        } catch let error as RemoteServiceError {
            throw error
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    private func loadSessionRows() async throws -> [SessionRow] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        func rows(columns: String) async throws -> [SessionRow] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
            var result: [SessionRow] = []
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page: [SessionRow] = try await client.from("remote_sessions").select(columns)
                    .order("updated_at", ascending: false).order("id", ascending: true)
                    .range(from: offset, to: offset + 499).execute().value
                result.append(contentsOf: page)
                if page.count < 500 { return result }
                offset += page.count
            }
        }
        do {
            return try await rows(columns: "id,machine_id,mode,title,workspace,model_id,approval_mode,status,pending_approval,message_count,updated_at,agent_system,phase,silence,interrupted,run_started_at,is_pinned,archived_at,project_id")
        } catch {
            return try await rows(columns: "id,machine_id,mode,title,workspace,model_id,approval_mode,status,pending_approval,message_count,updated_at,agent_system,phase,silence,interrupted,run_started_at")
        }
    }

    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            _ = try await client.auth.session
            let identity = try identities.identity()
            let context = try keyContext(identity)
            let rows: [MessageRow] = try await client
                .from("remote_messages")
                .select("id,session_id,seq,role,content,tool_calls,model,reasoning,run_stats,timeline")
                .eq("session_id", value: sessionID)
                .order("seq", ascending: true)
                .execute()
                .value
            let machine: MachineVersionRow? = try await client
                .from("remote_machines")
                .select("key_version")
                .eq("id", value: machineID)
                .maybeSingle()
                .execute()
                .value
            let keys = try await mirrorKeys(machineID: machineID, identity: identity)
            try validateKeyContext(context)
            return rows.map { row in
                let contentRead = readField(row.content, table: "remote_messages", column: "content", rowID: row.id, machineID: machineID, machineVersion: machine?.keyVersion, keys: keys)
                let content = contentRead.displayText ?? ""
                let reasoning = readableText(row.reasoning, table: "remote_messages", column: "reasoning", rowID: row.id, machineVersion: machine?.keyVersion, keys: keys)
                let toolJSON = readableJSON(row.toolCalls, table: "remote_messages", column: "tool_calls", rowID: row.id, machineVersion: machine?.keyVersion, keys: keys)
                let timeline = readableJSON(row.timeline, table: "remote_messages", column: "timeline", rowID: row.id, machineVersion: machine?.keyVersion, keys: keys)?.arrayValue
                let tools = toolJSON?.arrayValue?.compactMap(RemoteToolCall.init(json:)) ?? []
                return RemoteMessage(
                    id: row.id,
                    sessionID: row.sessionID,
                    sequence: row.sequence,
                    role: row.role,
                    content: content,
                    reasoning: reasoning,
                    timeline: timeline,
                    toolCalls: tools,
                    model: row.model,
                    runStats: RemoteRunStats(json: row.runStats),
                    readState: contentRead.state
                )
            }
        } catch let error as RemoteServiceError { throw error
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    func deleteSessions(ids: [String]) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return }
        do {
            _ = try await client.auth.session
            for id in uniqueIDs {
                let row: SessionMachineRow? = try await client
                    .from("remote_sessions")
                    .select("id,machine_id")
                    .eq("id", value: id)
                    .maybeSingle()
                    .execute()
                    .value
                guard let row else { continue }
                _ = try await execute(
                    type: RemoteCommandType.deleteSession.rawValue,
                    payload: .object([:]),
                    machineID: row.machineID,
                    sessionID: id,
                    timeout: .seconds(45)
                )
            }
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    func setSessionPinned(_ pinned: Bool, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            try await client.from("remote_sessions")
                .update(SessionPinnedUpdate(isPinned: pinned))
                .eq("id", value: sessionID)
                .execute()
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    func setSessionProject(_ projectID: String?, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            try await client.from("remote_sessions")
                .update(SessionProjectUpdate(projectID: projectID))
                .eq("id", value: sessionID)
                .execute()
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    func renameSession(_ title: String, machineID: String, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !title.isEmpty else { throw RemoteServiceError.commandRejected("invalid_title") }
        _ = try await execute(
            type: RemoteCommandType.renameSession.rawValue,
            payload: .object(["title": .string(title)]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(45)
        )
    }

    func setSessionArchived(_ archived: Bool, machineID: String, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        _ = try await execute(
            type: RemoteCommandType.archiveSession.rawValue,
            payload: .object(["archived": .bool(archived)]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(45)
        )
    }

    private func machine(_ row: MachineRow, identity: RemoteDeviceIdentity) async throws -> (RemoteMachine, [Int: Data]) {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let keys = try await mirrorKeys(machineID: row.id, identity: identity, requiredVersion: row.keyVersion)
        if !localAccessPolicy.isSuspended(row.id), let version = row.keyVersion, keys[version] == nil,
           Date().timeIntervalSince(Self.date(row.lastSeenAt)) < 75, identity.privateKey != nil {
            // Bootstrapping the read-only envelope must not depend on a user
            // attempting a command that cannot yet be encrypted.
            do { try await requestCurrentKeys(machineID: row.id, identity: identity) }
            catch let RemoteServiceError.commandFailure(failure) {
                record(commandID: row.id, machineID: row.id, type: "request_keys", stage: .failed,
                       status: "key_request_failed", errorCode: failure.code, serverCode: failure.serverCode)
            }
            catch { record(commandID: row.id, machineID: row.id, type: "request_keys", stage: .failed,
                           status: "key_request_failed", errorCode: .networkUnavailable, serverCode: "key_request_network") }
        }
        let field = readField(row.capabilities?.stringValue, table: "remote_machines", column: "capabilities",
            rowID: row.id, machineID: row.id, machineVersion: row.keyVersion, keys: keys)
        let capabilitiesJSON = readableJSON(row.capabilities, table: "remote_machines", column: "capabilities",
            rowID: row.id, machineVersion: row.keyVersion, keys: keys)
        let capabilities = decode(RemoteCapabilities.self, from: capabilitiesJSON)
        let readState: RemoteReadState = capabilities != nil ? .readable
            : field.state.blocksReading ? field.state : row.capabilities == nil ? .unknown : .invalidData
        if readState == .invalidData, reportedFieldStates["capabilities:" + row.id] != .invalidData {
            reportedFieldStates["capabilities:" + row.id] = .invalidData
            record(commandID: row.id, machineID: row.id, type: "capabilities", stage: .decrypting,
                   status: "invalidData", errorCode: .unreadablePayload, serverCode: "capabilities_decode_failed")
        }
        return (RemoteMachine(id: row.id, name: row.name, platform: row.platform, appVersion: row.appVersion,
            lastSeenAt: Self.date(row.lastSeenAt), keyVersion: row.keyVersion, capabilities: capabilities,
            readState: readState, keyRequestFailure: keyRequestFailures[row.id]), keys)
    }

    func pairDevice(code: String, name: String) async throws -> RemotePairingResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RemoteServiceError.invalidPairingCode }

        do {
            _ = try await client.auth.session
        } catch {
            throw pairingFailure(stage: .authentication, error: error)
        }

        let prepared: RemotePreparedIdentity
        do {
            prepared = try identities.preparePairing()
        } catch {
            throw pairingFailure(stage: .identity, error: error)
        }

        let response: PairingResponse
        do {
            let params = PairingParameters(
                code: normalized,
                deviceID: prepared.deviceID,
                deviceSecret: prepared.secret,
                deviceName: name.isEmpty ? "iPhone" : name,
                publicKey: prepared.publicKey
            )
            response = try await client.rpc("remote_pair_device", params: params).execute().value
        } catch {
            throw pairingFailure(stage: .request, error: error)
        }

        guard response.ok else {
            return .init(succeeded: false, errorCode: response.error)
        }

        do {
            try identities.commit(prepared)
        } catch {
            throw pairingFailure(stage: .persistence, error: error)
        }

        cachedKeys.removeAll()
        for task in keyRequestTasks.values { task.cancel() }
        keyRequestTasks.removeAll(); keyRequestIDs.removeAll(); keyRequestFailures.removeAll(); verifiedKeyReplies.removeAll()
        linkDiagnostics.removeAll(); reportedFieldStates.removeAll()
        keyRequests.removeAll()
        securityGeneration = UUID()
        unlockToken = nil
        unlockTokenAccountID = nil
        // The pairing RPC has already consumed the one-time code and is the
        // source of truth for success. Asking each computer to publish its
        // encryption envelope is deliberately best-effort: a sleeping
        // computer or a transient mirror read must not turn an accepted
        // pairing into a visible failure.
        if let machines: [MachineIDRow] = try? await client
            .from("remote_machines")
            .select("id")
            .execute()
            .value
        {
            for machine in machines where !localAccessPolicy.isSuspended(machine.id) {
                try? await requestKeys(machineID: machine.id, identity: prepared)
            }
        }
        return .init(succeeded: true)
    }

    private struct SecurityRequestContext {
        let generation: UUID
        let accountID: UUID
        let identity: RemoteDeviceIdentity
    }

    private func beginSecurityRequest() async throws -> SecurityRequestContext {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let generation = securityGeneration
        let session: Session
        do { session = try await client.auth.session }
        catch { throw RemoteSecurityServiceError.authenticationRequired }
        guard generation == securityGeneration, client.auth.currentUser?.id == session.user.id else {
            throw RemoteSecurityServiceError.contextChanged
        }
        let identity = try identities.identity()
        guard identity.privateKey != nil else { throw RemoteSecurityServiceError.deviceNotPaired }
        return .init(generation: generation, accountID: session.user.id, identity: identity)
    }

    private func validateSecurityRequest(_ context: SecurityRequestContext) throws {
        let current = try identities.identity()
        guard securityGeneration == context.generation,
              client.auth.currentUser?.id == context.accountID,
              current.deviceID == context.identity.deviceID,
              current.privateKey?.publicKeyBase64 == context.identity.privateKey?.publicKeyBase64 else {
            throw RemoteSecurityServiceError.contextChanged
        }
    }

    private func securityFailure(_ error: Error) -> RemoteSecurityServiceError {
        if let typed = error as? RemoteSecurityServiceError { return typed }
        if let rpc = error as? PostgrestError {
            // Preserve a machine-readable reference, never its message/details.
            let code = rpc.code ?? "unknown"
            let safe = code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                && code.count <= 32 ? code : "unknown"
            return .transport(code: "schema_" + safe)
        }
        if error is AuthError { return .authenticationRequired }
        if let network = error as? URLError { return .transport(code: "url_\(network.errorCode)") }
        if error is DecodingError { return .invalidResponse }
        if case FunctionsError.relayError = error { return .transport(code: "edge_relay") }
        return .transport(code: "unknown")
    }

    func deviceAuthorizationState() async throws -> RemoteDeviceAuthorizationState? {
        let context = try await beginSecurityRequest()
        do {
            let response: RemoteDeviceAuthorizationState = try await client.rpc("remote_device_authorization_state", params: RemoteIdentityParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret)).execute().value
            try validateSecurityRequest(context)
            guard [1, 2].contains(response.version) else { throw RemoteSecurityServiceError.invalidResponse }
            return response
        } catch let error as PostgrestError where error.code == "PGRST202" && error.message.contains("remote_device_authorization_state") {
            try validateSecurityRequest(context); return nil
        } catch { try validateSecurityRequest(context); throw securityFailure(error) }
    }
    func migrateDeviceAuthorization() async throws -> RemoteDeviceAuthorizationState {
        let context = try await beginSecurityRequest()
        do {
            let response: RemoteDeviceAuthorizationState = try await client.rpc("remote_migrate_device_authorization", params: ProtectionPolicyIdentity(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret, token: validUnlockToken)).execute().value
            try validateSecurityRequest(context)
            guard response.version == 2 else { throw RemoteSecurityServiceError.invalidResponse }
            return response
        } catch { try validateSecurityRequest(context); throw securityFailure(error) }
    }
    func authorizeDevice() async throws -> RemoteUnlockToken {
        let context = try await beginSecurityRequest()
        if let unlockToken, unlockToken.method == "device_v2", unlockTokenAccountID == context.accountID,
           unlockToken.expiresAt.timeIntervalSinceNow > 120 { return unlockToken }
        do {
            let token: RemoteUnlockToken = try await client.rpc("remote_authorize_device", params: RemoteIdentityParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret)).execute().value
            try validateSecurityRequest(context)
            guard token.method == "device_v2", !token.token.isEmpty, !token.isExpired else { throw RemoteSecurityServiceError.invalidResponse }
            unlockToken = token; unlockTokenAccountID = context.accountID
            return token
        } catch { try validateSecurityRequest(context); throw securityFailure(error) }
    }

    func remoteProtectionPolicy() async throws -> RemoteProtectionPolicy? {
        let context = try await beginSecurityRequest()
        do {
            let response: ProtectionPolicyResponse = try await client.rpc("remote_security_policy",
                params: ProtectionPolicyIdentity(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret,
                    token: validUnlockToken)).execute().value
            try validateSecurityRequest(context)
            guard response.ok, let policy = response.policy else {
                throw RemoteSecurityServiceError.server(code: Self.policyError(response.error))
            }
            return policy
        } catch let error as PostgrestError where error.code == "PGRST202" && error.message.contains("remote_security_policy") {
            try validateSecurityRequest(context)
            return nil // Only the exact absent contract gets the legacy policy.
        } catch {
            try validateSecurityRequest(context)
            if let error = error as? RemoteSecurityServiceError { throw error }
            throw securityFailure(error)
        }
    }

    func setRemoteProtectionPolicy(_ modes: [RemoteMode], expectedRevision: Int) async throws -> RemoteProtectionPolicy {
        let context = try await beginSecurityRequest()
        let canonical = RemoteMode.allCases.filter { modes.contains($0) }
        do {
            let response: ProtectionPolicyResponse = try await client.rpc("remote_set_security_policy",
                params: ProtectionPolicyParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret,
                    modes: canonical, revision: expectedRevision, token: validUnlockToken)).execute().value
            try validateSecurityRequest(context)
            guard response.ok, let policy = response.policy else { throw RemoteSecurityServiceError.server(code: Self.policyError(response.error)) }
            guard policy.protectedModes == canonical, policy.revision > expectedRevision else { throw RemoteSecurityServiceError.invalidResponse }
            return policy
        } catch {
            try validateSecurityRequest(context)
            if let error = error as? RemoteSecurityServiceError { throw error }
            throw securityFailure(error)
        }
    }

    private static func policyError(_ code: String?) -> String {
        let allowed = ["not_authenticated", "device_not_paired", "unlock_required", "policy_conflict", "invalid_policy", "no_pin"]
        return code.flatMap { allowed.contains($0) ? $0 : nil } ?? "policy_unavailable"
    }

    func remoteUnlockState() async throws -> RemoteUnlockState {
        let context = try await beginSecurityRequest()
        do {
            let response: RemoteUnlockStateResponse = try await client.rpc(
                "remote_unlock_state",
                params: RemoteIdentityParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret)
            ).execute().value
            try validateSecurityRequest(context)
            return try response.validatedValue
        } catch {
            try validateSecurityRequest(context)
            throw securityFailure(error)
        }
    }

    func setRemoteUnlockEnabled(_ enabled: Bool) async throws -> RemoteSecurityResult {
        let context = try await beginSecurityRequest()
        do {
            let response: RemoteEnabledResponse = try await client.rpc(
                "remote_unlock_set_enabled",
                params: RemoteUnlockEnabledParameters(
                    deviceID: context.identity.deviceID,
                    deviceSecret: context.identity.secret,
                    enabled: enabled,
                    unlockToken: validUnlockToken
                )
            ).execute().value
            try validateSecurityRequest(context)
            return .init(succeeded: response.ok, isEnabled: response.enabled, errorCode: response.error)
        } catch {
            try validateSecurityRequest(context)
            throw securityFailure(error)
        }
    }

    func setRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        guard RemoteLockRules.isValidPIN(pin) else {
            return .init(succeeded: false, errorCode: "pin_invalide")
        }
        return try await invokeUnlock(action: "pin-set", pin: pin, token: validUnlockToken)
    }

    func verifyRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        guard RemoteLockRules.isValidPIN(pin) else {
            return .init(succeeded: false, errorCode: "pin_invalide")
        }
        return try await invokeUnlock(action: "pin-verify", pin: pin)
    }

    func lockRemote() async {
        let token = validUnlockToken
        securityGeneration = UUID()
        unlockToken = nil
        unlockTokenAccountID = nil
        guard token != nil else { return }
        if let context = try? await beginSecurityRequest() {
            try? await client.rpc("remote_revoke_device_authorization", params: RemoteIdentityParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret)).execute()
        }
        _ = try? await invokeUnlock(action: "lock", token: token)
    }

    func resetRemoteSecurity() async throws -> RemoteSecurityResult {
        let context = try await beginSecurityRequest()
        do {
            let response: BasicSecurityResponse = try await client.rpc(
                "remote_unlock_reset",
                params: RemoteIdentityParameters(deviceID: context.identity.deviceID, deviceSecret: context.identity.secret)
            ).execute().value
            try validateSecurityRequest(context)
            if response.ok {
                securityGeneration = UUID()
                unlockToken = nil
                unlockTokenAccountID = nil
            }
            return .init(succeeded: response.ok, errorCode: response.error)
        } catch {
            try validateSecurityRequest(context)
            throw securityFailure(error)
        }
    }

    private func invokeUnlock(action: String, pin: String? = nil, token: String? = nil) async throws -> RemoteSecurityResult {
        let context = try await beginSecurityRequest()
        let body = UnlockFunctionBody(
            action: action,
            deviceID: context.identity.deviceID,
            deviceSecret: context.identity.secret,
            pin: pin,
            unlockToken: token
        )
        let response: UnlockFunctionResponse
        do {
            // Supabase's request adapter refreshes/injects the authenticated JWT.
            // Never retry a PIN attempt or silently replace a gateway rejection.
            do {
                response = try await client.functions.invoke(
                    "remote-unlock",
                    options: .init(headers: ["Origin": "https://aim-ai.tech"], body: body),
                    decode: { data, http in
                        try RemoteSecurityTransport.decode(data: data, status: http.statusCode)
                    }
                )
            } catch let FunctionsError.httpError(status, data) {
                response = try RemoteSecurityTransport.decode(data: data, status: status)
            }
            try validateSecurityRequest(context)
        } catch {
            try validateSecurityRequest(context)
            throw securityFailure(error)
        }
        if response.ok, action == "pin-set" || action == "pin-verify" {
            guard let token = response.unlock, !token.isExpired, !token.token.isEmpty else {
                throw RemoteSecurityServiceError.invalidResponse
            }
            unlockToken = token
            unlockTokenAccountID = context.accountID
        }
        return .init(
            succeeded: response.ok,
            token: response.unlock,
            lockedUntil: response.lockedUntil.flatMap(Self.date),
            attempts: response.attempts,
            errorCode: response.error
        )
    }

    private func pairingFailure(stage: RemotePairingFailure.Stage, error: Error) -> RemoteServiceError {
        let code: String
        if let postgrest = error as? PostgrestError {
            code = postgrest.code ?? "POSTGREST"
        } else if let auth = error as? AuthError {
            code = auth.errorCode.rawValue
        } else if let urlError = error as? URLError {
            code = "URL-\(urlError.errorCode)"
        } else if error is DecodingError {
            code = "DECODE"
        } else {
            code = "UNKNOWN"
        }
        let failure = RemotePairingFailure(stage: stage, code: code)
        Self.pairingLogger.error("Pairing failed: \(failure.reference, privacy: .public)")
        return .pairingFailed(failure)
    }

    func sendCommand(
        machineID: String,
        sessionID: String,
        type: RemoteCommandType,
        payload: RemoteJSONValue
    ) async throws -> RemoteCommandResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        // The RPC only proves that Supabase accepted the command. It does not
        // prove that the desktop bridge has received or processed it. Waiting
        // for the terminal command state keeps the UI's Remote health honest
        // and avoids reporting a successful send for a command left queued.
        let response = try await executeCommand(
            type: type.rawValue,
            payload: payload,
            machineID: machineID,
            sessionID: sessionID,
            timeout: commandTimeout(for: type),
            idempotencyKey: commandKey(
                type: type.rawValue,
                machineID: machineID,
                sessionID: sessionID,
                payload: payload
            )
        )
        let value: RemoteJSONValue
        if type == .startPreview {
            value = try await resolveTransferredJSON(response.value, machineID: machineID, sessionID: sessionID)
        } else { value = response.value }
        return .init(succeeded: true, result: value, commandID: response.commandID)
    }

    private func commandTimeout(for type: RemoteCommandType) -> Duration {
        switch type {
        case .startContinuousGoal, .continuousGoalStatus, .pauseContinuousGoal, .resumeContinuousGoal,
             .cancelContinuousGoal, .correctContinuousGoal, .acceptContinuousGoal, .continuousGoalApproval, .continuousGoalQuestion:
            .seconds(40)
        case .stopGeneration, .resumeTurn:
            .seconds(25)
        case .setModel, .setModelAdded, .setApprovalMode, .approvalResponse, .getMacSettings, .setMacSettings:
            .seconds(40)
        case .userMessage, .requestDiff, .startPreview, .stopPreview, .runCommand, .stopCommand, .requestDetail,
             .requestHistory, .renameSession, .archiveSession, .deleteSession:
            .seconds(75)
        }
    }

    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        var payload: [String: RemoteJSONValue] = [
            "mode": .string(request.mode.rawValue),
            "model_id": .string(request.modelID),
            "text": .string(request.text),
        ]
        if let provider = request.provider { payload["provider"] = .string(provider) }
        if let workspace = request.workspace { payload["workspace"] = .string(workspace) }
        if let approvalMode = request.approvalMode { payload["approval_mode"] = .string(approvalMode) }
        if request.mode == .agent, let agentSystem = request.agentSystem { payload["agent_system"] = .string(agentSystem) }
        if let effort = request.effort { payload["effort"] = .string(effort) }
        if let goal = request.goal {
            if goal.continuous {
                let configuration = RemoteContinuousGoalConfiguration(maximumTurns: goal.maximumTurns > 0 ? goal.maximumTurns : nil, maximumSpendUSD: request.maximumSpendUSD)
                guard configuration.isValid else { throw RemoteSecurityServiceError.invalidResponse }
                payload["goal"] = configuration.json
            } else { payload["goal"] = goal.json }
        }
        if let id = request.delegationID { payload["client_request_id"] = .string(id.uuidString.lowercased()) }

        if !request.attachments.isEmpty {
            payload["attachments"] = .array(request.attachments.map { attachment in
                .object([
                    "transfer_id": .string(attachment.transferID),
                    "name": .string(attachment.name),
                    "mime": .string(attachment.mimeType),
                    "size": .number(Double(attachment.size)),
                ])
            })
        }
        if request.defersInitialMessage {
            payload["pieces_a_suivre"] = .bool(true)
        }

        let (result, commandID) = try await executeCommand(
            type: "create_session",
            payload: .object(payload),
            machineID: request.machineID,
            sessionID: nil,
            mode: request.mode,
            timeout: .seconds(40),
            idempotencyKey: commandKey(type: "create_session", machineID: request.machineID, sessionID: nil, payload: .object(payload))
        )
        guard let sessionID = result.objectValue?["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw commandFailure(
                code: .unreadablePayload,
                stage: .completed,
                commandID: commandID,
                serverCode: "missing_session_id"
            )
        }
        let publicationDeadline = ContinuousClock().now.advanced(by: .seconds(20))
        while ContinuousClock().now < publicationDeadline {
            let published: SessionIDRow? = try await client
                .from("remote_sessions")
                .select("id")
                .eq("id", value: sessionID)
                .maybeSingle()
                .execute()
                .value
            if published != nil {
                if request.goal?.continuous == true {
                    let account = try await client.auth.session.user.id
                    let device = try identities.identity()
                    let key = RemoteContinuityCommandStore.key(accountID: account, deviceID: device.deviceID,
                        commandKey: commandKey(type: "create_session", machineID: request.machineID, sessionID: nil, payload: .object(payload)))
                    if var receipt = try continuityCommands.load(key: key), receipt.commandID == commandID {
                        receipt.publicationComplete = true; try continuityCommands.save(receipt, key: key)
                    }
                }
                record(commandID: commandID, machineID: request.machineID, type: "create_session", stage: .published, status: "published")
                return sessionID
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        throw commandFailure(
            code: .lateSynchronization,
            stage: .published,
            commandID: commandID,
            serverCode: "publication_timeout"
        )
    }

    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let payload: RemoteJSONValue = path.map { .object(["path": .string($0)]) } ?? .object([:])
        let (result, _) = try await executeCommand(
            type: "list_folders",
            payload: payload,
            machineID: machineID,
            sessionID: nil,
            timeout: .seconds(25),
            idempotencyKey: commandKey(type: "list_folders", machineID: machineID, sessionID: nil, payload: payload)
        )
        let object = result.objectValue ?? [:]
        let values = (path == nil ? object["roots"] : object["entries"])?.arrayValue ?? []
        return .init(
            folders: values.compactMap(RemoteFolder.init(json:)),
            currentPath: path,
            projectsDirectory: object["projectsDir"]?.stringValue
        )
    }

    func createFolder(machineID: String, parent: String, name: String) async throws -> RemoteFolder {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !cleanName.isEmpty else {
            throw RemoteServiceError.commandFailure(
                .init(code: .invalidRequest, stage: .failed, serverCode: "invalid_folder_name", diagnosticReference: "REMOTE-FOLDER-INVALID-REQUEST")
            )
        }
        let value = try await execute(
            type: "create_folder",
            payload: .object(["parent": .string(parent), "name": .string(cleanName)]),
            machineID: machineID,
            sessionID: nil,
            timeout: .seconds(35)
        )
        guard
            let object = value.objectValue,
            let path = object["path"]?.stringValue,
            !path.isEmpty
        else {
            throw RemoteServiceError.commandFailure(
                .init(code: .unreadablePayload, stage: .completed, serverCode: "missing_folder_path", diagnosticReference: "REMOTE-FOLDER-UNREADABLE-PAYLOAD")
            )
        }
        return .init(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
    }

    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let rawValue = try await execute(
            type: "request_diff",
            payload: .object([:]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(35)
        )
        let value = try await resolveTransferredJSON(rawValue, machineID: machineID, sessionID: sessionID)
        let object = value.objectValue ?? [:]
        return .init(
            diff: object["diff"]?.stringValue ?? "",
            base: object["base"]?.stringValue,
            directory: object["dir"]?.stringValue,
            files: object["files"]?.arrayValue?.compactMap { value in
                guard let file = value.objectValue, let path = file["path"]?.stringValue else { return nil }
                return RemoteChangedFile(
                    path: path,
                    status: file["status"]?.stringValue,
                    additions: Int(file["additions"]?.numberValue ?? 0),
                    deletions: Int(file["deletions"]?.numberValue ?? 0)
                )
            } ?? []
        )
    }

    func loadHistory(machineID: String, sessionID: String, cursor: String?, limit: Int) async throws -> RemoteHistoryPage {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        var payload: [String: RemoteJSONValue] = ["limit": .number(Double(min(100, max(1, limit))))]
        if let cursor { payload["cursor"] = .string(cursor) }
        let rawValue = try await execute(
            type: RemoteCommandType.requestHistory.rawValue,
            payload: .object(payload),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(90)
        )
        let value = try await resolveTransferredJSON(rawValue, machineID: machineID, sessionID: sessionID)
        let object = value.objectValue ?? [:]
        let messages = object["messages"]?.arrayValue?.compactMap { value -> RemoteMessage? in
            guard let row = value.objectValue,
                  let id = row["id"]?.stringValue,
                  let roleValue = row["role"]?.stringValue,
                  let role = RemoteMessageRole(rawValue: roleValue)
            else { return nil }
            let sequence = Int(row["seq"]?.numberValue ?? row["sequence"]?.numberValue ?? 0)
            let tools = row["tool_calls"]?.arrayValue?.compactMap(RemoteToolCall.init(json:)) ?? []
            return RemoteMessage(
                id: id,
                sessionID: sessionID,
                sequence: sequence,
                role: role,
                content: row["content"]?.stringValue ?? "",
                reasoning: row["reasoning"]?.stringValue,
                timeline: row["timeline"]?.arrayValue,
                toolCalls: tools,
                model: row["model"]?.stringValue,
                runStats: RemoteRunStats(json: row["run_stats"])
            )
        } ?? []
        return .init(
            messages: messages,
            nextCursor: object["next_cursor"]?.stringValue,
            hasMore: object["has_more"]?.boolValue ?? false
        )
    }

    func loadAttachmentMetadata(machineID: String, sessionID: String) async throws -> [RemoteSessionAttachment] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            let identity = try identities.identity()
            let machine: MachineVersionRow? = try await client.from("remote_machines")
                .select("key_version")
                .eq("id", value: machineID)
                .maybeSingle()
                .execute()
                .value
            let keys = try await mirrorKeys(machineID: machineID, identity: identity)
            let rows: [AttachmentMetadataRow] = try await client.from("remote_session_attachments")
                .select("id,session_id,machine_id,key_version,metadata,created_at,expires_at")
                .eq("session_id", value: sessionID)
                .order("created_at", ascending: true)
                .execute()
                .value
            return rows.compactMap { row in
                guard let metadata = readableJSON(
                    row.metadata,
                    table: "remote_session_attachments",
                    column: "metadata",
                    rowID: row.id,
                    machineVersion: row.keyVersion ?? machine?.keyVersion,
                    keys: keys
                )?.objectValue else { return nil }
                return RemoteSessionAttachment(
                    id: row.id,
                    sessionID: row.sessionID,
                    machineID: row.machineID,
                    name: metadata["name"]?.stringValue ?? "File",
                    mimeType: metadata["mime"]?.stringValue ?? "application/octet-stream",
                    size: Int(metadata["size"]?.numberValue ?? 0),
                    source: metadata["source"]?.stringValue ?? "remote",
                    createdAt: Self.date(row.createdAt),
                    expiresAt: row.expiresAt.map(Self.date)
                )
            }
        } catch {
            throw RemoteServiceError.unavailable
        }
    }

    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let rawValue = try await execute(
            type: "run_command",
            payload: .object(["command": .string(command)]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(120)
        )
        let value = try await resolveTransferredJSON(rawValue, machineID: machineID, sessionID: sessionID)
        let object = value.objectValue ?? [:]
        return .init(
            output: object["output"]?.stringValue ?? object["tail"]?.stringValue ?? "",
            exitCode: object["exitCode"]?.numberValue.map(Int.init),
            truncated: object["truncated"]?.boolValue ?? false,
            stopped: object["stopped"]?.boolValue ?? false
        )
    }

    func stopTerminalCommand(machineID: String, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        _ = try await execute(
            type: "stop_command",
            payload: .object([:]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(20)
        )
    }

    func requestDetail(machineID: String, sessionID: String, detailID: String) async throws -> RemoteJSONValue {
        try await requestDetail(machineID: machineID, sessionID: sessionID, detailID: detailID, offset: 0)
    }
    func requestDetail(machineID: String, sessionID: String, detailID: String, offset: Int) async throws -> RemoteJSONValue {
        guard (0...1_000_000).contains(offset) else { throw URLError(.badURL) }
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let value = try await execute(
            type: "request_detail",
            payload: .object(["detail_id": .string(detailID), "offset": .number(Double(offset))]),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(75)
        )
        return try await resolveTransferredJSON(value, machineID: machineID, sessionID: sessionID)
    }

    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        var payload: [String: RemoteJSONValue] = [:]
        if let script { payload["script"] = .string(script) }
        let rawValue = try await execute(
            type: "start_preview",
            payload: .object(payload),
            machineID: machineID,
            sessionID: sessionID,
            timeout: .seconds(75)
        )
        return .init(json: try await resolveTransferredJSON(rawValue, machineID: machineID, sessionID: sessionID))
    }

    func stopPreview(machineID: String, sessionID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let commandID = UUID().uuidString.lowercased()
        let response = try await submitCommand(
            commandID: commandID,
            machineID: machineID,
            sessionID: sessionID,
            type: "stop_preview",
            payload: .object([:])
        )
        guard response.ok else {
            throw commandError(response.error, stage: .rpc, commandID: commandID, machineID: machineID, type: "stop_preview")
        }
    }

    func uploadAttachment(
        data: Data,
        name: String,
        mimeType: String,
        machineID: String,
        sessionID: String
    ) async throws -> RemoteAttachmentReference {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let candidate = RemoteAttachmentCandidate(name: name, size: data.count, mimeType: mimeType)
        guard RemoteAttachmentRules.sort(existingCount: 0, candidates: [candidate]).accepted.count == 1 else {
            throw RemoteServiceError.commandRejected("attachment_invalid")
        }
        let session = try await client.auth.session
        let identity = try identities.identity()
        let machine: MachineVersionRow? = try await client
            .from("remote_machines")
            .select("key_version")
            .eq("id", value: machineID)
            .maybeSingle()
            .execute()
            .value
        guard let keyVersion = machine?.keyVersion else { throw RemoteServiceError.encryptionKeyUnavailable }
        let keys = try await mirrorKeys(machineID: machineID, identity: identity)
        guard let key = keys[keyVersion] else { throw RemoteServiceError.encryptionKeyUnavailable }

        let transferID = UUID().uuidString.lowercased()
        let transfer = try RemoteTransferCrypto.prepareAttachment(
            data: data,
            key: key,
            keyVersion: keyVersion,
            transferID: transferID,
            machineID: machineID,
            sessionID: sessionID,
            filename: candidate.name,
            mimeType: candidate.mimeType ?? "application/octet-stream"
        )
        let sealedManifest = try RemoteTransferCrypto.sealManifest(transfer.manifest, key: key)
        let row = TransferInsertRow(
            id: transferID,
            userID: session.user.id.uuidString.lowercased(),
            machineID: machineID,
            sessionID: sessionID,
            keyVersion: keyVersion,
            manifest: sealedManifest,
            chunkCount: transfer.manifest.chunkCount,
            expiresAt: transfer.manifest.expiresAt
        )
        try await client.from("remote_transfers").insert(row).execute()

        do {
            for block in transfer.blocks {
                let path = try RemoteTransferCrypto.storagePath(
                    userID: row.userID,
                    manifest: transfer.manifest,
                    index: block.index
                )
                try await client.storage.from("remote-transfers").upload(
                    path,
                    data: block.encrypted,
                    options: FileOptions(contentType: "application/octet-stream", upsert: true)
                )
            }
            try await client.from("remote_transfers")
                .update(TransferStatusUpdate(status: "ready"))
                .eq("id", value: transferID)
                .execute()
            let metadataValue: RemoteJSONValue = .object([
                "name": .string(candidate.name),
                "mime": .string(candidate.mimeType ?? "application/octet-stream"),
                "size": .number(Double(candidate.size)),
                "source": .string("iphone"),
            ])
            let metadataClear = String(decoding: try JSONEncoder().encode(metadataValue), as: UTF8.self)
            let metadataEncrypted = try RemoteCrypto.encryptField(
                metadataClear,
                key: key,
                version: keyVersion,
                context: .init(table: "remote_session_attachments", column: "metadata", rowID: transferID)
            )
            try await client.from("remote_session_attachments").insert(
                AttachmentMetadataInsertRow(
                    id: transferID,
                    userID: session.user.id.uuidString.lowercased(),
                    machineID: machineID,
                    sessionID: sessionID,
                    keyVersion: keyVersion,
                    metadata: .string(metadataEncrypted),
                    expiresAt: transfer.manifest.expiresAt
                )
            ).execute()
        } catch {
            _ = try? await client.from("remote_transfers")
                .update(TransferStatusUpdate(status: "error"))
                .eq("id", value: transferID)
                .execute()
            throw RemoteServiceError.unavailable
        }
        return RemoteAttachmentRules.reference(transferID: transferID, file: candidate)
    }

    private func resolveTransferredJSON(
        _ value: RemoteJSONValue,
        machineID: String,
        sessionID: String
    ) async throws -> RemoteJSONValue {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let object = value.objectValue,
              let transferID = object["transfer_id"]?.stringValue ?? object["transferId"]?.stringValue,
              !transferID.isEmpty
        else { return value }

        do {
            let row: TransferDownloadRow = try await client.from("remote_transfers")
                .select("id,machine_id,session_id,status,manifest")
                .eq("id", value: transferID)
                .single()
                .execute()
                .value
            guard row.status == "ready", row.machineID == machineID, row.sessionID == sessionID else {
                throw RemoteTransferError.incompleteTransfer
            }

            let identity = try identities.identity()
            let keys = try await mirrorKeys(machineID: machineID, identity: identity)
            let manifest = try RemoteTransferCrypto.openManifest(
                row.manifest,
                transferID: transferID,
                keys: keys
            )
            guard manifest.machineID == machineID, manifest.sessionID == sessionID,
                  let key = keys[manifest.keyVersion]
            else { throw RemoteTransferError.invalidManifest }

            let authSession = try await client.auth.session
            let userID = authSession.user.id.uuidString.lowercased()
            var blocks: [RemoteTransferBlock] = []
            blocks.reserveCapacity(manifest.chunkCount)
            for index in 0..<manifest.chunkCount {
                let path = try RemoteTransferCrypto.storagePath(
                    userID: userID,
                    manifest: manifest,
                    index: index
                )
                let encrypted = try await client.storage.from("remote-transfers").download(path: path)
                blocks.append(.init(index: index, encrypted: encrypted))
            }
            let clear = try RemoteTransferCrypto.assemble(manifest: manifest, blocks: blocks, key: key)
            if let decoded = try? JSONDecoder().decode(RemoteJSONValue.self, from: clear) {
                return decoded
            }
            guard let text = String(data: clear, encoding: .utf8) else {
                throw RemoteTransferError.invalidSize
            }
            return .string(text)
        } catch let error as RemoteServiceError {
            throw error
        } catch {
            throw RemoteServiceError.commandFailure(
                .init(
                    code: .unreadablePayload,
                    stage: .decrypting,
                    serverCode: "transfer_unreadable",
                    diagnosticReference: RemoteDiagnosticPrivacy.reference(
                        commandID: transferID,
                        code: .unreadablePayload
                    )
                )
            )
        }
    }

    func events(for sessionID: String?) async -> AsyncStream<RemoteEvent> {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { return AsyncStream { $0.finish() } }
        return AsyncStream<RemoteEvent> { continuation in
            let eventID = UUID()
            localEvents[eventID] = continuation
            var subscriptions = [AIMRealtimeSubscription(table: "remote_machines"),
                AIMRealtimeSubscription(table: "remote_sessions"), AIMRealtimeSubscription(table: "remote_device_keys"), AIMRealtimeSubscription(table: "remote_commands")]
            if let sessionID { subscriptions.append(AIMRealtimeSubscription(table: "remote_messages", filter: "session_id=eq." + sessionID)) }
            let watched = subscriptions
            let client = self.client
            let task = Task {
                do {
                    for try await table in AIMNativeRealtime.changes(client: client, subscriptions: watched) {
                        if table == "remote_messages", let sessionID { continuation.yield(.messagesChanged(sessionID: sessionID)) }
                        else {
                            if table == "remote_device_keys" { self.cachedKeys.removeAll() }
                            continuation.yield(.overviewChanged)
                        }
                    }
                } catch { }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { await self.removeLocalEvents(eventID) }
            }
        }
    }

    private func removeLocalEvents(_ id: UUID) { localEvents[id] = nil }

    private func session(_ row: SessionRow, machineVersion: Int?, identity: RemoteDeviceIdentity, overviewKeys: [Int: Data]) async throws -> RemoteSession {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let keys = overviewKeys
        let titleRead = readField(row.title, table: "remote_sessions", column: "title", rowID: row.id, machineID: row.machineID, machineVersion: machineVersion, keys: keys)
        let pendingJSON = readableJSON(row.pendingApproval, table: "remote_sessions", column: "pending_approval", rowID: row.id, machineVersion: machineVersion, keys: keys)
        let announcement = RemoteConversationAnnouncement.decode(phase: readableText(row.phase, table: "remote_sessions", column: "phase", rowID: row.id, machineVersion: machineVersion, keys: keys))
        return RemoteSession(
            id: row.id,
            machineID: row.machineID,
            mode: row.mode,
            title: titleRead.displayText ?? "Conversation",
            workspace: readableText(row.workspace, table: "remote_sessions", column: "workspace", rowID: row.id, machineVersion: machineVersion, keys: keys),
            modelID: row.modelID,
            approvalMode: row.approvalMode,
            status: row.status,
            messageCount: row.messageCount,
            updatedAt: Self.date(row.updatedAt),
            agentSystem: row.agentSystem,
            phase: announcement.phase,
            isSilent: row.silence,
            isInterrupted: row.interrupted,
            pendingApproval: RemotePendingApproval(json: pendingJSON),
            runStartedAt: row.runStartedAt.map(Self.date),
            isPinned: row.isPinned,
            archivedAt: row.archivedAt.map(Self.date),
            projectID: row.projectID,
            readState: titleRead.state,
            executionDeviceIDs: announcement.executionDeviceIDs, latestResponseVersion: announcement.latestResponseVersion
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: RemoteJSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func keyContext(_ identity: RemoteDeviceIdentity) throws -> RemoteMirrorKeyContext {
        guard let accountID = client.auth.currentUser?.id else {
            throw RemoteServiceError.commandFailure(.init(code: .authenticationRequired, stage: .authentication,
                serverCode: "not_authenticated", diagnosticReference: "REMOTE-AUTH-CONTEXT"))
        }
        let context = RemoteMirrorKeyContext(accountID: accountID, deviceID: identity.deviceID,
            publicKey: identity.privateKey?.publicKeyBase64 ?? "", generation: securityGeneration)
        if let previous = diagnosticContext, previous != context {
            for task in keyRequestTasks.values { task.cancel() }
            keyRequestTasks.removeAll(); keyRequestIDs.removeAll(); keyRequestFailures.removeAll(); verifiedKeyReplies.removeAll()
            cachedKeys.removeAll(); keyRequests.removeAll(); linkDiagnostics.removeAll()
            reportedFieldStates.removeAll(); diagnosticEntries.removeAll(); registeredPublicKey = nil
        }
        diagnosticContext = context
        return context
    }

    private func validateKeyContext(_ context: RemoteMirrorKeyContext) throws {
        try Task.checkCancellation()
        let current = try identities.identity()
        guard client.auth.currentUser?.id == context.accountID, securityGeneration == context.generation,
              current.deviceID == context.deviceID, (current.privateKey?.publicKeyBase64 ?? "") == context.publicKey else {
            throw commandFailure(code: .authenticationRequired, stage: .authentication,
                commandID: context.deviceID, serverCode: "key_context_changed")
        }
    }

    private func mirrorKeys(machineID: String, identity: RemoteDeviceIdentity,
                            requiredVersion: Int? = nil, forceRefresh: Bool = false) async throws -> [Int: Data] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let privateKey = identity.privateKey, let accountID = client.auth.currentUser?.id else { return [:] }
        let context = try keyContext(identity)
        if !forceRefresh, let cached = cachedKeys[machineID],
           cached.isUsable(context: context, requiredVersion: requiredVersion, now: Date()) { return cached.keys }
        let rows: [DeviceKeyRow] = try await client
            .from("remote_device_keys")
            .select("key_version,envelope")
            .eq("device_id", value: identity.deviceID)
            .eq("machine_id", value: machineID)
            .execute()
            .value
        try validateKeyContext(context)
        var keys: [Int: Data] = [:]
        var unreadable = false
        for row in rows {
            guard let envelope = row.envelope, envelope.keyVersion == row.keyVersion else { unreadable = true; continue }
            do {
                keys[row.keyVersion] = try RemoteCrypto.openEnvelope(envelope,
                    devicePrivateKey: privateKey, machineID: machineID, deviceID: identity.deviceID)
            } catch { unreadable = true }
        }
        cachedKeys[machineID] = .init(context: context, keys: keys, fetchedAt: Date())
        let advertisedVersion = requiredVersion ?? linkDiagnostics[machineID]?.currentKeyVersion
        linkDiagnostics[machineID] = .init(accountID: accountID.uuidString, deviceID: identity.deviceID, machineID: machineID,
            localPublicKey: privateKey.publicKeyBase64, registeredPublicKey: registeredPublicKey,
            currentKeyVersion: advertisedVersion, envelopeVersions: rows.map(\.keyVersion), openedVersions: Array(keys.keys),
            unreadableVersions: rows.filter { keys[$0.keyVersion] == nil }.map(\.keyVersion),
            readState: advertisedVersion.map { keys[$0] != nil } == true ? .readable : unreadable ? .envelopeUnreadable : .keyPending)
        if linkDiagnostics.count > 100 { linkDiagnostics = [machineID: linkDiagnostics[machineID]!] }
        if let advertisedVersion, keys[advertisedVersion] != nil { keyRequestFailures[machineID] = nil }
        let envelopeState: RemoteReadState = unreadable ? .envelopeUnreadable : keys.isEmpty ? .keyPending : .readable
        let envelopeScope = "envelope:" + machineID
        if (unreadable || keys.isEmpty), reportedFieldStates[envelopeScope] != envelopeState {
            reportedFieldStates[envelopeScope] = envelopeState
            record(commandID: machineID, machineID: machineID, type: "mirror_keys", stage: .decrypting,
                   status: rows.isEmpty ? "envelope_missing" : "envelope_unreadable",
                   errorCode: rows.isEmpty ? .encryptionKeyPending : .unreadablePayload,
                   serverCode: rows.isEmpty ? "key_envelope_missing" : "key_envelope_unreadable")
        }
        if envelopeState == .readable { reportedFieldStates[envelopeScope] = .readable }
        return keys
    }

    func checkBridge(machineID: String) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        _ = try await client.auth.session
        let identity = try identities.identity()
        let context = try keyContext(identity)
        guard identity.privateKey != nil else { throw RemoteServiceError.encryptionKeyUnavailable }
        let row: MachineVersionRow? = try await client.from("remote_machines")
            .select("key_version,last_seen_at,app_version").eq("id", value: machineID).maybeSingle().execute().value
        try validateKeyContext(context)
        guard let row, let lastSeenAt = row.lastSeenAt, Date().timeIntervalSince(Self.date(lastSeenAt)) < 75 else {
            throw commandFailure(code: .computerOffline, stage: .rpc, commandID: machineID, serverCode: "computer_offline")
        }
        func hasRecentReply() -> Bool {
            guard let reply = verifiedKeyReplies[machineID] else { return false }
            return reply.version == row.keyVersion && Date().timeIntervalSince(reply.date) < 15
        }
        if hasRecentReply() { return }
        // request_keys is already PIN-exempt. Its terminal response alone is
        // insufficient: monitorKeyRequest also opens the advertised envelope.
        try await requestCurrentKeys(machineID: machineID, identity: identity)
        let scope = keyRequestScope(context, machineID: machineID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        // Another actor call may still be awaiting admission before its task exists.
        while keyRequestIDs[scope] != nil, keyRequestTasks[scope] == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20)); try validateKeyContext(context)
        }
        if let task = keyRequestTasks[scope] { await task.value }
        try validateKeyContext(context)
        if let failure = keyRequestFailures[machineID] { throw RemoteServiceError.commandFailure(failure) }
        guard hasRecentReply() else {
            throw commandFailure(code: .bridgeUnresponsive, stage: .rpc, commandID: machineID, serverCode: "key_reply_unconfirmed")
        }
    }

    private func keyRequestScope(_ context: RemoteMirrorKeyContext, machineID: String) -> String {
        context.accountID.uuidString + ":" + context.deviceID + ":" + context.publicKey + ":" + machineID + ":" + context.generation.uuidString
    }

    private func requestCurrentKeys(machineID: String, identity: RemoteDeviceIdentity) async throws {
        try localAccessPolicy.requireAccess(to: machineID)
        guard let privateKey = identity.privateKey else { return }
        let requestScope = keyRequestScope(try keyContext(identity), machineID: machineID)
        if keyRequestIDs[requestScope] != nil { return }
        if let date = keyRequests[requestScope], Date().timeIntervalSince(date) < 15 { return }
        // One repair request per scope/interval, including rejected requests;
        // never replay a user mutation while waiting for this read-only key.
        keyRequests[requestScope] = Date()
        try await requestKeys(machineID: machineID,
            identity: .init(deviceID: identity.deviceID, secret: identity.secret, privateKey: privateKey))
    }

    private func readField(_ value: String?, table: String, column: String, rowID: String, machineID: String,
                           machineVersion: Int?, keys: [Int: Data]) -> RemoteFieldRead {
        let version = value.flatMap { RemoteCrypto.keyVersion(of: $0) }
        let read = RemoteFieldReader.read(value, context: .init(table: table, column: column, rowID: rowID),
            currentVersion: machineVersion, keys: keys,
            envelopeUnreadable: version.map { linkDiagnostics[machineID]?.unreadableVersions.contains($0) == true } ?? false)
        let scope = machineID + ":" + table + ":" + column + ":" + (version.map(String.init) ?? "legacy")
        if read.state.blocksReading, reportedFieldStates[scope] != read.state {
            reportedFieldStates[scope] = read.state
            record(commandID: rowID, machineID: machineID, type: table + "." + column, stage: .decrypting,
                   status: read.state.rawValue, errorCode: read.state == .keyPending || read.state == .historicalKeyMissing ? .encryptionKeyPending : .unreadablePayload,
                   serverCode: version.map { "field_key_version_\($0)" })
        }
        if reportedFieldStates.count > 500 { reportedFieldStates.removeAll() }
        return read
    }

    private func readableText(_ value: String?, table: String, column: String, rowID: String, machineVersion: Int?, keys: [Int: Data]) -> String? {
        RemoteFieldReader.read(value, context: .init(table: table, column: column, rowID: rowID),
                               currentVersion: machineVersion, keys: keys).displayText
    }

    private func readableJSON(_ value: RemoteJSONValue?, table: String, column: String, rowID: String, machineVersion: Int?, keys: [Int: Data]) -> RemoteJSONValue? {
        guard let value else { return nil }
        if let encrypted = value.stringValue, RemoteCrypto.isEncrypted(encrypted) {
            guard let clear = readableText(encrypted, table: table, column: column, rowID: rowID, machineVersion: machineVersion, keys: keys),
                  !clear.hasPrefix("🔒"), let data = clear.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(RemoteJSONValue.self, from: data)
        }
        guard machineVersion == nil else { return nil }
        return value
    }

    private func connectionState(deviceRow: DeviceRow?, identity: RemoteDeviceIdentity) -> RemoteConnectionState {
        guard let deviceRow, deviceRow.revokedAt == nil else { return .unpaired }
        if let expiresAt = deviceRow.expiresAt, Self.date(expiresAt) <= Date() { return .unpaired }
        if deviceRow.publicKey != nil, identity.privateKey == nil { return .needsRepair }
        if let remoteKey = deviceRow.publicKey, remoteKey != identity.privateKey?.publicKeyBase64 { return .needsRepair }
        return .paired
    }

    private func requestKeys(machineID: String, identity: RemotePreparedIdentity) async throws {
        try localAccessPolicy.requireAccess(to: machineID)
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let context = try keyContext(.init(deviceID: identity.deviceID, secret: identity.secret, privateKey: identity.privateKey))
        try validateKeyContext(context)
        let scope = keyRequestScope(context, machineID: machineID)
        guard keyRequestIDs[scope] == nil else { return }
        let trackingID = UUID()
        keyRequestIDs[scope] = trackingID
        verifiedKeyReplies[machineID] = nil
        let parameters = RemoteCommandParameters(deviceID: identity.deviceID, deviceSecret: identity.secret,
            commandID: UUID().uuidString.lowercased(), machineID: machineID, sessionID: nil, type: "request_keys",
            payload: .object([:]), unlockToken: validUnlockToken)
        do {
            try localAccessPolicy.requireAccess(to: machineID)
            let response: PairingResponse = try await client.rpc("remote_send_command", params: parameters).execute().value
            try validateKeyContext(context)
            guard response.ok else {
                throw commandError(response.error, stage: .rpc, commandID: parameters.commandID,
                    machineID: machineID, type: "request_keys")
            }
            keyRequestFailures[machineID] = nil
            record(commandID: parameters.commandID, machineID: machineID, type: "request_keys", stage: .queued, status: "queued")
        } catch {
            if keyRequestIDs[scope] == trackingID { keyRequestIDs[scope] = nil }
            if (try? validateKeyContext(context)) != nil, case let RemoteServiceError.commandFailure(failure) = error {
                keyRequestFailures[machineID] = failure
            }
            throw error
        }
        keyRequestTasks[scope] = Task { [weak self] in
            await self?.monitorKeyRequest(commandID: parameters.commandID, machineID: machineID,
                context: context, scope: scope, trackingID: trackingID)
        }
    }

    private func monitorKeyRequest(commandID: String, machineID: String, context: RemoteMirrorKeyContext,
                                   scope: String, trackingID: UUID) async {
        defer {
            if keyRequestIDs[scope] == trackingID { keyRequestIDs[scope] = nil; keyRequestTasks[scope] = nil }
        }
        do {
            _ = try await commandResult(commandID: commandID, machineID: machineID, sessionID: nil,
                type: "request_keys", timeout: .seconds(8), expectedKeyContext: context)
            try validateKeyContext(context)
            let row: MachineVersionRow? = try await client.from("remote_machines").select("key_version")
                .eq("id", value: machineID).maybeSingle().execute().value
            try validateKeyContext(context)
            let identity = try identities.identity()
            let keys = try await mirrorKeys(machineID: machineID, identity: identity,
                requiredVersion: row?.keyVersion, forceRefresh: true)
            guard let version = row?.keyVersion, keys[version] != nil else {
                let unreadable = row?.keyVersion.map { linkDiagnostics[machineID]?.unreadableVersions.contains($0) == true } ?? false
                throw recordedFailure(code: unreadable ? .unreadablePayload : .encryptionKeyPending,
                    stage: .decrypting, commandID: commandID, machineID: machineID, type: "request_keys",
                    serverCode: unreadable ? "published_envelope_unreadable" : "published_envelope_missing", startedAt: Date())
            }
            keyRequestFailures[machineID] = nil
            verifiedKeyReplies[machineID] = (Date(), version)
            record(commandID: commandID, machineID: machineID, type: "request_keys", stage: .decrypting, status: "envelope_opened")
        } catch {
            guard (try? validateKeyContext(context)) != nil else { return }
            if case let RemoteServiceError.commandFailure(failure) = error { keyRequestFailures[machineID] = failure }
            else {
                let failure = RemoteCommandFailure(code: .networkUnavailable, stage: .rpc,
                    serverCode: "key_request_transport", diagnosticReference: RemoteDiagnosticPrivacy.reference(commandID: commandID, code: .networkUnavailable))
                keyRequestFailures[machineID] = failure
                record(commandID: commandID, machineID: machineID, type: "request_keys", stage: .failed,
                       status: "key_request_transport", errorCode: failure.code, serverCode: failure.serverCode)
            }
        }
        for continuation in localEvents.values { continuation.yield(.overviewChanged) }
    }

    private func submitCommand(
        commandID: String = UUID().uuidString.lowercased(),
        machineID: String,
        sessionID: String?,
        type: String,
        payload: RemoteJSONValue,
        mode: RemoteMode? = nil, durableKey: String? = nil, pendingKey: String? = nil
    ) async throws -> PairingResponse {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let startedAt = Date()
        record(commandID: commandID, machineID: machineID, type: type, stage: .authentication, status: "started", startedAt: startedAt)
        do {
            _ = try await client.auth.session
            record(commandID: commandID, machineID: machineID, type: type, stage: .authentication, status: "authenticated", startedAt: startedAt)
            let identity = try identities.identity()
            let context = try keyContext(identity)
            let versionRow: MachineVersionRow? = try await client
                .from("remote_machines")
                .select("key_version,last_seen_at,app_version")
                .eq("id", value: machineID)
                .maybeSingle()
                .execute()
                .value

            guard let versionRow else {
                throw commandFailure(
                    code: .computerOffline,
                    stage: .rpc,
                    commandID: commandID,
                    serverCode: "unknown_machine"
                )
            }
            if let lastSeenAt = versionRow.lastSeenAt,
               Date().timeIntervalSince(Self.date(lastSeenAt)) >= 75
            {
                throw commandFailure(
                    code: .computerOffline,
                    stage: .rpc,
                    commandID: commandID,
                    serverCode: "computer_offline"
                )
            }

            var protectedPayload = payload
            let storedWirePayload = try durableKey.flatMap { try continuityCommands.load(key: $0)?.wirePayload }
            if let storedWirePayload {
                protectedPayload = storedWirePayload
            } else if let version = versionRow.keyVersion {
                var keys = try await mirrorKeys(machineID: machineID, identity: identity, requiredVersion: version)
                if keys[version] == nil {
                    try await requestCurrentKeys(machineID: machineID, identity: identity)
                    // Give the existing host a bounded chance to publish. This
                    // polls envelopes only; the user's command is not submitted yet.
                    for _ in 0..<8 {
                        if let failure = keyRequestFailures[machineID] { throw RemoteServiceError.commandFailure(failure) }
                        try await Task.sleep(for: .seconds(1))
                        keys = try await mirrorKeys(machineID: machineID, identity: identity,
                                                    requiredVersion: version, forceRefresh: true)
                        if keys[version] != nil { break }
                    }
                }
                guard let key = keys[version] else {
                    throw commandFailure(code: .encryptionKeyPending, stage: .rpc,
                        commandID: commandID, serverCode: "key_envelope_missing")
                }
                let clear = try String(
                    decoding: JSONEncoder().encode(payload),
                    as: UTF8.self
                )
                let encrypted = try RemoteCrypto.encryptField(
                    clear,
                    key: key,
                    version: version,
                    context: RemoteCommandIdentity(id: commandID, type: type, sessionID: sessionID, machineID: machineID).context(for: .payload)
                )
                protectedPayload = .object(["e": .string(encrypted)])
            }

            if let durableKey {
                guard protectedPayload.objectValue?["e"]?.stringValue != nil,
                      var receipt = try continuityCommands.load(key: durableKey), receipt.commandID == commandID else {
                    throw commandFailure(code: .encryptionKeyPending, stage: .rpc, commandID: commandID, serverCode: "cle_en_attente")
                }
                receipt.wirePayload = protectedPayload
                try continuityCommands.save(receipt, key: durableKey)
            }
            try validateKeyContext(context)
            let parameters = RemoteCommandParameters(
                deviceID: identity.deviceID,
                deviceSecret: identity.secret,
                commandID: commandID,
                machineID: machineID,
                sessionID: sessionID,
                type: type,
                payload: protectedPayload,
                unlockToken: validUnlockToken,
                mode: mode
            )
            // Only commands that reached transmission may be resumed as
            // pending. A missing envelope previously left an unsent command
            // here, so Refresh polled a command that could never exist.
            if let pendingKey { pendingCommands[pendingKey] = .init(commandID: commandID, createdAt: startedAt) }
            record(commandID: commandID, machineID: machineID, type: type, stage: .rpc, status: "sending", startedAt: startedAt)
            try localAccessPolicy.requireAccess(to: machineID)
            let response: PairingResponse = try await client.rpc("remote_send_command", params: parameters).execute().value
            try validateKeyContext(context)
            if response.ok {
                record(commandID: commandID, machineID: machineID, type: type, stage: .queued, status: "queued", startedAt: startedAt)
            } else {
                let code = RemoteCommandErrorCode.classify(response.error)
                record(
                    commandID: commandID,
                    machineID: machineID,
                    type: type,
                    stage: .failed,
                    status: "rejected",
                    startedAt: startedAt,
                    errorCode: code,
                    serverCode: response.error
                )
            }
            return response
        } catch let error as RemoteServiceError {
            throw error
        } catch is AuthError {
            throw recordedFailure(
                code: .authenticationRequired,
                stage: .authentication,
                commandID: commandID,
                machineID: machineID,
                type: type,
                serverCode: "not_authenticated",
                startedAt: startedAt
            )
        } catch let error as URLError {
            throw recordedFailure(
                code: .networkUnavailable,
                stage: .rpc,
                commandID: commandID,
                machineID: machineID,
                type: type,
                serverCode: "url_\(error.errorCode)",
                startedAt: startedAt
            )
        } catch {
            throw recordedFailure(
                code: .networkUnavailable,
                stage: .rpc,
                commandID: commandID,
                machineID: machineID,
                type: type,
                serverCode: "rpc_failed",
                startedAt: startedAt
            )
        }
    }

    private func execute(
        type: String,
        payload: RemoteJSONValue,
        machineID: String,
        sessionID: String?,
        timeout: Duration
    ) async throws -> RemoteJSONValue {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await executeCommand(
            type: type,
            payload: payload,
            machineID: machineID,
            sessionID: sessionID,
            timeout: timeout,
            idempotencyKey: commandKey(type: type, machineID: machineID, sessionID: sessionID, payload: payload)
        ).value
    }

    private func executeCommand(
        type: String,
        payload: RemoteJSONValue,
        machineID: String,
        sessionID: String?,
        mode: RemoteMode? = nil,
        timeout: Duration,
        idempotencyKey: String? = nil
    ) async throws -> (value: RemoteJSONValue, commandID: String) {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let now = Date()
        let action = RemoteContinuityAction(rawValue: type)
        let browserMutation = type == "start_preview" && payload.objectValue?["browser"]?.objectValue?["name"]?.stringValue.map { $0 != "browser_snapshot" } == true
        let durable = action != nil && action != .status || payload.objectValue?["goal"]?.objectValue?["continuous"]?.boolValue == true
            || type == "run_command" || browserMutation || ["rename_session", "archive_session", "delete_session"].contains(type)
        var durableKey: String?
        var durableReceipt: RemoteContinuityCommandReceipt?
        if durable {
            let session = try await client.auth.session
            let device = try identities.identity()
            let key = RemoteContinuityCommandStore.key(accountID: session.user.id, deviceID: device.deviceID,
                commandKey: idempotencyKey ?? commandKey(type: type, machineID: machineID, sessionID: sessionID, payload: payload))
            durableKey = key
            durableReceipt = try continuityCommands.load(key: key) ?? RemoteContinuityCommandReceipt()
            // A completed gesture may be performed again later (pause after resume,
            // for example). Historical receipts remain recoverable by command ID.
            let continuousCreation = type == "create_session" && payload.objectValue?["goal"]?.objectValue?["continuous"]?.boolValue == true
            if let receipt = durableReceipt, RemoteContinuityCommandRules.shouldBeginNewGesture(receipt, continuousCreation: continuousCreation) {
                durableReceipt = RemoteContinuityCommandReceipt()
            }
            try continuityCommands.save(durableReceipt!, key: key)
            if let result = durableReceipt?.result, let commandID = durableReceipt?.commandID { return (result, commandID) }
        }
        pendingCommands = pendingCommands.filter { now.timeIntervalSince($0.value.createdAt) < 10 * 60 }
        let pending = idempotencyKey.flatMap { pendingCommands[$0] }
        let commandID = durableReceipt?.commandID ?? pending?.commandID ?? UUID().uuidString.lowercased()
        if durable ? durableReceipt?.submitted != true : pending == nil {
            let response = try await submitCommand(
                commandID: commandID,
                machineID: machineID,
                sessionID: sessionID,
                type: type,
                payload: payload,
                mode: mode, durableKey: durableKey, pendingKey: idempotencyKey
            )
            guard response.ok else {
                if let idempotencyKey { pendingCommands[idempotencyKey] = nil }
                throw commandError(
                    response.error,
                    stage: .rpc,
                    commandID: commandID,
                    machineID: machineID,
                    type: type
                )
            }
            if let durableKey, var receipt = durableReceipt {
                receipt.submitted = true; try continuityCommands.save(receipt, key: durableKey); durableReceipt = receipt
            }
        } else {
            record(commandID: commandID, machineID: machineID, type: type, stage: .acknowledged, status: "resuming")
        }

        do {
            let value = try await commandResult(
                commandID: commandID,
                machineID: machineID,
                sessionID: sessionID,
                type: type,
                timeout: timeout, durableKey: durableKey
            )
            if let durableKey, var receipt = try continuityCommands.load(key: durableKey) {
                receipt.result = value; try continuityCommands.save(receipt, key: durableKey)
            }
            if let idempotencyKey { pendingCommands[idempotencyKey] = nil }
            return (value, commandID)
        } catch let RemoteServiceError.commandFailure(failure) {
            // A command acknowledged by the desktop may still complete after
            // the phone times out, so keep its identity and resume polling.
            // A command that stayed queued was never seen by the bridge;
            // retrying must publish a fresh INSERT so Realtime can deliver it.
            if failure.code != .bridgeUnresponsive || failure.stage == .queued,
               let idempotencyKey
            {
                pendingCommands[idempotencyKey] = nil
            }
            throw RemoteServiceError.commandFailure(failure)
        } catch let RemoteServiceError.commandRejected(reason) where reason == "remote_access_suspended" {
            // Suspension stops observation, not execution. Keep the submitted identity
            // so reactivation resumes polling rather than submitting the same mutation.
            throw RemoteServiceError.commandRejected(reason)
        } catch {
            if let idempotencyKey { pendingCommands[idempotencyKey] = nil }
            throw error
        }
    }

    private func commandResult(
        commandID: String,
        machineID: String,
        sessionID: String?,
        type: String,
        timeout: Duration, durableKey: String? = nil, expectedKeyContext: RemoteMirrorKeyContext? = nil
    ) async throws -> RemoteJSONValue {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let clock = ContinuousClock()
        let startedAt = Date()
        let deadline = clock.now.advanced(by: timeout)
        var attempts = 0
        var didAcknowledge = false
        var lastStatus: String?
        while clock.now < deadline {
            try localAccessPolicy.requireAccess(to: machineID)
            if let expectedKeyContext { try validateKeyContext(expectedKeyContext) }
            let row: CommandResultRow? = try await client
                .from("remote_commands")
                .select("status,error,result")
                .eq("id", value: commandID)
                .maybeSingle()
                .execute()
                .value
            if let expectedKeyContext { try validateKeyContext(expectedKeyContext) }
            lastStatus = row?.status
            if let status = row?.status, status != "pending", status != "queued", !didAcknowledge {
                didAcknowledge = true
                if let durableKey, var receipt = try continuityCommands.load(key: durableKey) {
                    receipt.acknowledged = true; try continuityCommands.save(receipt, key: durableKey)
                }
                record(commandID: commandID, machineID: machineID, type: type, stage: .acknowledged, status: status, startedAt: startedAt)
            }
            if row?.status == "error" {
                if let durableKey, var receipt = try continuityCommands.load(key: durableKey) {
                    receipt.terminalError = row?.error ?? "remote_command_failed"
                    try continuityCommands.save(receipt, key: durableKey)
                }
                throw commandError(row?.error, stage: .failed, commandID: commandID, machineID: machineID, type: type)
            }
            if row?.status == "done" {
                record(commandID: commandID, machineID: machineID, type: type, stage: .completed, status: "done", startedAt: startedAt)
                guard let result = row?.result else { return .object([:]) }
                let identity = try identities.identity()
                let machine: MachineVersionRow? = try await client
                    .from("remote_machines")
                    .select("key_version")
                    .eq("id", value: machineID)
                    .maybeSingle()
                    .execute()
                    .value
                let keys = try await mirrorKeys(machineID: machineID, identity: identity)
                if let encrypted = result.objectValue?["e"]?.stringValue, RemoteCrypto.isEncrypted(encrypted) {
                    record(commandID: commandID, machineID: machineID, type: type, stage: .decrypting, status: "decrypting", startedAt: startedAt)
                    do {
                        let clear = try RemoteCrypto.decryptField(
                            encrypted,
                            keys: keys,
                            context: RemoteCommandIdentity(id: commandID, type: type, sessionID: sessionID, machineID: machineID).context(for: .result)
                        )
                        guard let data = clear.data(using: .utf8) else {
                            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8"))
                        }
                        return try JSONDecoder().decode(RemoteJSONValue.self, from: data)
                    } catch {
                        throw recordedFailure(
                            code: .unreadablePayload,
                            stage: .decrypting,
                            commandID: commandID,
                            machineID: machineID,
                            type: type,
                            serverCode: "decrypt_failed",
                            startedAt: startedAt
                        )
                    }
                }
                if machine?.keyVersion != nil, !keys.isEmpty {
                    throw recordedFailure(
                        code: .unreadablePayload,
                        stage: .decrypting,
                        commandID: commandID,
                        machineID: machineID,
                        type: type,
                        serverCode: "unencrypted_result",
                        startedAt: startedAt
                    )
                }
                return result
            }
            attempts += 1
            try await Task.sleep(for: attempts <= 8 ? .milliseconds(250) : attempts <= 14 ? .milliseconds(700) : .milliseconds(1_500))
        }
        throw recordedFailure(
            code: .bridgeUnresponsive,
            stage: didAcknowledge ? .acknowledged : .queued,
            commandID: commandID,
            machineID: machineID,
            type: type,
            serverCode: didAcknowledge ? "handler_timeout" : "bridge_timeout_\(lastStatus ?? "missing")",
            startedAt: startedAt
        )
    }

    private func commandError(
        _ rawCode: String?,
        stage: RemoteCommandStage,
        commandID: String,
        machineID: String,
        type: String
    ) -> RemoteServiceError {
        let code = RemoteCommandErrorCode.classify(rawCode)
        record(
            commandID: commandID,
            machineID: machineID,
            type: type,
            stage: stage,
            status: "error",
            errorCode: code,
            serverCode: rawCode
        )
        return commandFailure(code: code, stage: stage, commandID: commandID, serverCode: rawCode)
    }

    private func commandFailure(
        code: RemoteCommandErrorCode,
        stage: RemoteCommandStage,
        commandID: String,
        serverCode: String?
    ) -> RemoteServiceError {
        .commandFailure(
            .init(
                code: code,
                stage: stage,
                serverCode: serverCode,
                diagnosticReference: RemoteDiagnosticPrivacy.reference(commandID: commandID, code: code)
            )
        )
    }

    private func recordedFailure(
        code: RemoteCommandErrorCode,
        stage: RemoteCommandStage,
        commandID: String,
        machineID: String,
        type: String,
        serverCode: String?,
        startedAt: Date
    ) -> RemoteServiceError {
        record(
            commandID: commandID,
            machineID: machineID,
            type: type,
            stage: stage,
            status: "error",
            startedAt: startedAt,
            errorCode: code,
            serverCode: serverCode
        )
        return commandFailure(code: code, stage: stage, commandID: commandID, serverCode: serverCode)
    }

    private func record(
        commandID: String,
        machineID: String,
        type: String,
        stage: RemoteCommandStage,
        status: String,
        startedAt: Date? = nil,
        errorCode: RemoteCommandErrorCode? = nil,
        serverCode: String? = nil,
        path: String? = nil
    ) {
        let entry = RemoteDiagnosticEntry(
            commandIdentifier: RemoteDiagnosticPrivacy.identifier(commandID),
            machineIdentifier: RemoteDiagnosticPrivacy.identifier(machineID),
            type: type,
            stage: stage,
            status: status,
            durationMilliseconds: startedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0,
            errorCode: errorCode,
            serverCode: serverCode,
            pathBasename: path
        )
        diagnosticEntries.append(entry)
        if diagnosticEntries.count > 200 {
            diagnosticEntries.removeFirst(diagnosticEntries.count - 200)
        }
        let reference = RemoteDiagnosticPrivacy.reference(commandID: commandID, code: errorCode)
        Self.commandLogger.info("Remote command \(type, privacy: .public) \(stage.rawValue, privacy: .public) status=\(status, privacy: .public) ref=\(reference, privacy: .public)")
    }

    private func commandKey(type: String, machineID: String, sessionID: String?, payload: RemoteJSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payloadData = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        return [type, machineID, sessionID ?? "", digest]
            .joined(separator: ":")
    }

    private var validUnlockToken: String? {
        guard let unlockToken, !unlockToken.isExpired,
              unlockTokenAccountID == client.auth.currentUser?.id else {
            self.unlockToken = nil
            return nil
        }
        return unlockToken.token
    }

    fileprivate static func date(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}

private struct MachineRow: Decodable {
    let id: String; let name: String; let platform: String?; let appVersion: String?; let lastSeenAt: String; let keyVersion: Int?; let capabilities: RemoteJSONValue?
    enum CodingKeys: String, CodingKey { case id, name, platform, capabilities; case appVersion = "app_version"; case lastSeenAt = "last_seen_at"; case keyVersion = "key_version" }
}

private struct SessionRow: Decodable {
    let id: String; let machineID: String; let mode: RemoteMode; let title: String; let workspace: String?; let modelID: String?; let approvalMode: String?; let status: String; let pendingApproval: RemoteJSONValue?; let messageCount: Int; let updatedAt: String; let agentSystem: String?; let phase: String?; let silence: Bool; let interrupted: Bool; let runStartedAt: String?; let isPinned: Bool; let archivedAt: String?; let projectID: String?
    enum CodingKeys: String, CodingKey { case id, mode, title, workspace, status, phase, silence, interrupted; case machineID = "machine_id"; case modelID = "model_id"; case approvalMode = "approval_mode"; case pendingApproval = "pending_approval"; case messageCount = "message_count"; case updatedAt = "updated_at"; case agentSystem = "agent_system"; case runStartedAt = "run_started_at"; case isPinned = "is_pinned"; case archivedAt = "archived_at"; case projectID = "project_id" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        machineID = try values.decode(String.self, forKey: .machineID)
        mode = try values.decode(RemoteMode.self, forKey: .mode)
        title = try values.decode(String.self, forKey: .title)
        workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        approvalMode = try values.decodeIfPresent(String.self, forKey: .approvalMode)
        status = try values.decode(String.self, forKey: .status)
        pendingApproval = try values.decodeIfPresent(RemoteJSONValue.self, forKey: .pendingApproval)
        messageCount = try values.decode(Int.self, forKey: .messageCount)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        agentSystem = try values.decodeIfPresent(String.self, forKey: .agentSystem)
        phase = try values.decodeIfPresent(String.self, forKey: .phase)
        silence = try values.decode(Bool.self, forKey: .silence)
        interrupted = try values.decode(Bool.self, forKey: .interrupted)
        runStartedAt = try values.decodeIfPresent(String.self, forKey: .runStartedAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
    }
}

private struct SessionMachineRow: Decodable { let id: String; let machineID: String; enum CodingKeys: String, CodingKey { case id; case machineID = "machine_id" } }
private struct SessionPinnedUpdate: Encodable { let isPinned: Bool; enum CodingKeys: String, CodingKey { case isPinned = "is_pinned" } }
private struct SessionProjectUpdate: Encodable { let projectID: String?; enum CodingKeys: String, CodingKey { case projectID = "project_id" } }
private struct AttachmentMetadataRow: Decodable {
    let id: String; let sessionID: String; let machineID: String; let keyVersion: Int?; let metadata: RemoteJSONValue?; let createdAt: String; let expiresAt: String?
    enum CodingKeys: String, CodingKey { case id, metadata; case sessionID = "session_id"; case machineID = "machine_id"; case keyVersion = "key_version"; case createdAt = "created_at"; case expiresAt = "expires_at" }
}

private struct MessageRow: Decodable {
    let id: String; let sessionID: String; let sequence: Int; let role: RemoteMessageRole; let content: String; let toolCalls: RemoteJSONValue?; let model: String?; let reasoning: String?; let runStats: RemoteJSONValue?; let timeline: RemoteJSONValue?
    enum CodingKeys: String, CodingKey { case id, role, content, model, reasoning, timeline; case sessionID = "session_id"; case sequence = "seq"; case toolCalls = "tool_calls"; case runStats = "run_stats" }
}

private struct MachineVersionRow: Decodable {
    let keyVersion: Int?
    let lastSeenAt: String?
    let appVersion: String?
    enum CodingKeys: String, CodingKey {
        case keyVersion = "key_version"
        case lastSeenAt = "last_seen_at"
        case appVersion = "app_version"
    }
}
private struct MachineIDRow: Decodable { let id: String }
private struct SessionIDRow: Decodable { let id: String }
private struct DeviceRow: Decodable { let id: String; let revokedAt: String?; let expiresAt: String?; let publicKey: String?; enum CodingKeys: String, CodingKey { case id; case revokedAt = "revoked_at"; case expiresAt = "expires_at"; case publicKey = "public_key" } }
private struct DeviceKeyRow: Decodable {
    let keyVersion: Int
    let envelope: RemoteKeyEnvelope?
    enum CodingKeys: String, CodingKey { case keyVersion = "key_version", envelope }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyVersion = try values.decode(Int.self, forKey: .keyVersion)
        envelope = try? values.decode(RemoteKeyEnvelope.self, forKey: .envelope)
    }
}
private struct PairingResponse: Decodable { let ok: Bool; let error: String? }
private struct CommandResultRow: Decodable { let status: String; let error: String?; let result: RemoteJSONValue? }

private struct PairingParameters: Encodable {
    let code: String; let deviceID: String; let deviceSecret: String; let deviceName: String; let publicKey: String
    enum CodingKeys: String, CodingKey { case code = "p_code"; case deviceID = "p_device_id"; case deviceSecret = "p_device_secret"; case deviceName = "p_device_name"; case publicKey = "p_public_key" }
}

struct RemoteCommandParameters: Encodable {
    let deviceID: String
    let deviceSecret: String
    let commandID: String
    let machineID: String
    let sessionID: String?
    let type: String
    let payload: RemoteJSONValue
    let unlockToken: String?
    var mode: RemoteMode? = nil

    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id"
        case deviceSecret = "p_device_secret"
        case commandID = "p_command_id"
        case machineID = "p_machine_id"
        case sessionID = "p_session_id"
        case type = "p_type"
        case payload = "p_payload"
        case unlockToken = "p_unlock_token"
        case mode = "p_mode"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceSecret, forKey: .deviceSecret)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(machineID, forKey: .machineID)
        if let sessionID { try container.encode(sessionID, forKey: .sessionID) }
        else { try container.encodeNil(forKey: .sessionID) }
        try container.encode(type, forKey: .type)
        try container.encode(payload, forKey: .payload)
        if let unlockToken { try container.encode(unlockToken, forKey: .unlockToken) }
        else { try container.encodeNil(forKey: .unlockToken) }
        if let mode { try container.encode(mode.rawValue, forKey: .mode) }
        else { try container.encodeNil(forKey: .mode) }
    }
}

private struct PendingCommand: Sendable {
    let commandID: String
    let createdAt: Date
}

private struct RemoteIdentityParameters: Encodable {
    let deviceID: String
    let deviceSecret: String
    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id"
        case deviceSecret = "p_device_secret"
    }
}

private struct RemoteUnlockEnabledParameters: Encodable {
    let deviceID: String
    let deviceSecret: String
    let enabled: Bool
    let unlockToken: String?
    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id"
        case deviceSecret = "p_device_secret"
        case enabled = "p_enabled"
        case unlockToken = "p_unlock_token"
    }
}

struct RemoteUnlockStateResponse: Decodable {
    let ok: Bool
    let passkeys: Int?
    let pin: Bool?
    let lockedUntil: String?
    let enabled: Bool?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case ok, passkeys, pin, enabled, error
        case lockedUntil = "locked_until"
    }

    var validatedValue: RemoteUnlockState {
        get throws {
            // Missing fields are unknown, never evidence that a PIN is absent.
            if ok {
                guard pin != nil, enabled != nil, let passkeys, passkeys >= 0 else {
                    throw RemoteSecurityServiceError.invalidResponse
                }
            }
            return value
        }
    }

    var value: RemoteUnlockState {
        .init(
            succeeded: ok,
            passkeyCount: passkeys ?? 0,
            hasPIN: pin ?? false,
            lockedUntil: lockedUntil.flatMap(SupabaseRemoteService.date),
            isEnabled: enabled ?? true,
            errorCode: error
        )
    }
}

private struct RemoteEnabledResponse: Decodable {
    let ok: Bool
    let enabled: Bool?
    let error: String?
}

private struct BasicSecurityResponse: Decodable {
    let ok: Bool
    let error: String?
}

private struct UnlockFunctionBody: Encodable {
    let action: String
    let deviceID: String
    let deviceSecret: String
    let pin: String?
    let unlockToken: String?
    enum CodingKeys: String, CodingKey {
        case action, pin, unlockToken
        case deviceID = "deviceId"
        case deviceSecret = "deviceSecret"
    }
}

struct UnlockFunctionResponse: Decodable {
    let ok: Bool
    let error: String?
    let unlock: RemoteUnlockToken?
    let lockedUntil: String?
    let attempts: Int?
    enum CodingKeys: String, CodingKey {
        case ok, error, unlock, attempts
        case lockedUntil = "locked_until"
    }
}

private struct TransferInsertRow: Encodable {
    let id: String
    let userID: String
    let machineID: String
    let sessionID: String
    let keyVersion: Int
    let manifest: String
    let chunkCount: Int
    let status = "uploading"
    let kind = "attachment"
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id, manifest, status, kind
        case userID = "user_id"
        case machineID = "machine_id"
        case sessionID = "session_id"
        case keyVersion = "key_version"
        case chunkCount = "chunk_count"
        case expiresAt = "expires_at"
    }
}

private struct TransferStatusUpdate: Encodable { let status: String }

private struct TransferDownloadRow: Decodable {
    let id: String
    let machineID: String
    let sessionID: String
    let status: String
    let manifest: String

    enum CodingKeys: String, CodingKey {
        case id, status, manifest
        case machineID = "machine_id"
        case sessionID = "session_id"
    }
}

private struct AttachmentMetadataInsertRow: Encodable {
    let id: String
    let userID: String
    let machineID: String
    let sessionID: String
    let keyVersion: Int
    let metadata: RemoteJSONValue
    let expiresAt: String
    enum CodingKeys: String, CodingKey {
        case id, metadata
        case userID = "user_id"
        case machineID = "machine_id"
        case sessionID = "session_id"
        case keyVersion = "key_version"
        case expiresAt = "expires_at"
    }
}

private struct ProtectionPolicyResponse: Decodable {
    let ok: Bool
    let policy: RemoteProtectionPolicy?
    let error: String?
}
private struct ProtectionPolicyParameters: Encodable {
    let deviceID: String
    let deviceSecret: String
    let modes: [RemoteMode]
    let revision: Int
    let token: String?
    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id", deviceSecret = "p_device_secret", modes = "p_protected_modes"
        case revision = "p_expected_revision", token = "p_unlock_token"
    }
}

private struct ProtectionPolicyIdentity: Encodable {
    let deviceID: String
    let deviceSecret: String
    let token: String?
    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id", deviceSecret = "p_device_secret", token = "p_unlock_token"
    }
}
