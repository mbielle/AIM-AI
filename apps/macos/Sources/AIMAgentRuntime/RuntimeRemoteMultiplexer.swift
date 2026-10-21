import AIMCore
import AIMMacPlatform

package struct RuntimeRemoteMultiplexer: RemoteHostDelegate {
    let continuity: ContinuityRemoteBridge
    let legacy: any RemoteHostDelegate
    package func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws {
        try await continuity.remoteStop(commandIDs: commandIDs, conversationIDs: conversationIDs)
        try await legacy.remoteStop(commandIDs: commandIDs, conversationIDs: conversationIDs)
    }
    package func remoteSnapshotReadSucceeded() async -> Bool { await continuity.remoteSnapshotReadSucceeded() }
    package func remoteSessionLimit() async -> Int? { nil }
    package func remoteCapabilities() async -> RemoteCapabilities {
        let old = await legacy.remoteCapabilities()
        let runtime = await continuity.remoteCapabilities()
        var features = old.features
        for feature in [RemoteCapabilities.Feature.continuity, RemoteCapabilities.Feature.experimentalContinuity,
                        RemoteCapabilities.Feature.continuityAvailable, RemoteCapabilities.Feature.sessionManagement,
                        RemoteCapabilities.Feature.history, RemoteCapabilities.Feature.agentTerminal, RemoteCapabilities.Feature.agentDiff,
                        RemoteCapabilities.Feature.structuredDiff, RemoteCapabilities.Feature.agentBrowser, "terminal", "code_terminal", "diff", "browser"] {
            features[feature] = runtime.supports(feature)
        }
        features["remoteDownloads"] = true
        features["goal"] = runtime.supports(RemoteCapabilities.Feature.continuity)
        return RemoteCapabilities(version: old.version, models: old.models, engines: runtime.engines, features: features, worker: runtime.worker)
    }
    package func remoteSnapshots() async -> [RemoteHostSessionSnapshot] {
        let durable = await continuity.remoteSnapshots(), old = await legacy.remoteSnapshots()
        let runtimeIDs = await continuity.durableSessionIDs()
        let live = old.filter { !runtimeIDs.contains($0.id) }
        let liveIDs = Set(live.map(\.id))
        return durable.filter { !liveIDs.contains($0.id) } + live
    }
    package func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue,
                               attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        try await legacy.remoteExecute(type: type, sessionID: sessionID, payload: payload, attachments: attachments)
    }
    package func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                               attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        if payload.objectValue?["section"]?.stringValue == "downloads" || RuntimeRemoteSessionBridge.commands.contains(type) || RemoteContinuityAction(rawValue: type) != nil || payload.objectValue?["goal"]?.objectValue?["continuous"] == .bool(true) {
            return try await continuity.remoteExecute(commandID: commandID, type: type, sessionID: sessionID, payload: payload, attachments: attachments)
        }
        return try await legacy.remoteExecute(commandID: commandID, type: type, sessionID: sessionID, payload: payload, attachments: attachments)
    }
}
