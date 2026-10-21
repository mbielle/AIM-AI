import AIMCore
import AIMApplication
import AIMAgentKit
import AIMMacPlatform
import Foundation

package struct RuntimePeerStartPayload: Codable, Sendable {
    package let request: AgentRequest
    package let workspaceTransfer: RemotePeerArtifactCommit?
}
package actor RuntimePeerWorkspaceBridge {
    private let artifacts: RuntimePeerArtifactEndpoint
    private let workspaces: RemotePeerWorkspaceStore
    private let directory: URL
    package init(artifacts: RuntimePeerArtifactEndpoint, directory: URL) throws {
        self.artifacts = artifacts; self.directory = directory
        workspaces = try RemotePeerWorkspaceStore(artifacts: artifacts.store, directory: directory.appending(path: "Workspaces"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidConfiguration }
    }
    package func prepare(root: String, transferID: UUID, grant: RemotePeerGrant, paths: [String]? = nil) async throws -> RemotePeerArtifactManifest {
        try await workspaces.snapshot(root: URL(fileURLWithPath: root), transferID: transferID, grant: grant, paths: paths)
    }
    package func send(_ manifest: RemotePeerArtifactManifest, grant: RemotePeerSignedGrant, transport: any RemotePeerTransport) async throws -> RemotePeerArtifactCommit {
        let prefix = "artifact:" + manifest.transferID.uuidString
        let chunks = manifest.files.enumerated().map { file, value in
            value.chunks.indices.map { chunk in RemotePeerCommandIdentity.derive(prefix + ":" + String(file) + ":" + String(chunk)) }
        }
        _ = try await artifacts.send(manifest: manifest, grant: grant, transport: transport,
            manifestCommandID: RemotePeerCommandIdentity.derive(prefix + ":manifest"), chunkCommandIDs: chunks,
            commitCommandID: RemotePeerCommandIdentity.derive(prefix + ":commit"))
        return RemotePeerArtifactCommit(transferID: manifest.transferID,
            manifestSHA256: RemotePeerArtifactManifest.hash(try RemotePeerCoding.encode(manifest)))
    }
    package func manifest(_ commit: RemotePeerArtifactCommit, grant: RemotePeerGrant) async throws -> RemotePeerArtifactManifest {
        let manifest = try await artifacts.store.manifest(transferID: commit.transferID, grant: grant)
        guard RemotePeerArtifactManifest.hash(try RemotePeerCoding.encode(manifest)) == commit.manifestSHA256 else { throw RemotePeerError.conflictingCommand }
        return manifest
    }
    package func materialize(_ commit: RemotePeerArtifactCommit, grant: RemotePeerGrant) async throws -> String {
        try await workspaces.materialize(commit: commit, grant: grant).path
    }
    package func exportFinal(grant: RemotePeerSignedGrant, record: AgentExecution, transport: any RemotePeerTransport) async throws -> RemotePeerArtifactCommit? {
        guard grant.grant.writer, [.accepted, .verified, .awaitingReview].contains(record.state) else { return nil }
        let request = try RemotePeerCoding.decode(AgentRequest.self, record.request)
        guard let root = request.workspacePath, root.hasPrefix(directory.appending(path: "Workspaces").path + "/") else {
            throw RemotePeerError.unauthorized
        }
        let file = directory.appendingPathComponent("final-" + grant.grant.childExecutionID.uuidString.lowercased() + ".json")
        let manifest: RemotePeerArtifactManifest
        if FileManager.default.fileExists(atPath: file.path) {
            let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 262144 else { throw RemotePeerError.invalidEnvelope }
            manifest = try RemotePeerCoding.decode(RemotePeerArtifactManifest.self, Data(contentsOf: file)); try manifest.validate(grant: grant.grant)
        } else {
            manifest = try await prepare(root: root, transferID: UUID(), grant: grant.grant)
            try RemotePeerCoding.encode(manifest).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return try await send(manifest, grant: grant, transport: transport)
    }
    package func applyFinal(_ final: RemotePeerArtifactCommit, baseline: RemotePeerArtifactManifest,
        destination: String, grant: RemotePeerGrant) async throws {
        let root = try await artifacts.store.commit(final, grant: grant)
        let manifest = try await artifacts.store.manifest(transferID: final.transferID, grant: grant)
        try await workspaces.synchronize(baseline: baseline, final: manifest, finalDirectory: root,
            destination: URL(fileURLWithPath: destination), grant: grant)
    }
}
