import AIMCore
import AIMMacPlatform
import Foundation

package struct RuntimePeerArtifactEndpoint: Sendable {
    package let store: RemotePeerArtifactStore
    package init(store: RemotePeerArtifactStore) { self.store = store }
    package func handle(_ request: RemotePeerRequest, grant: RemotePeerGrant, recovering: Bool) async throws -> Data {
        switch request.action {
        case .artifactManifest:
            try await store.receive(manifest: RemotePeerCoding.decode(RemotePeerArtifactManifest.self, request.payload), grant: grant)
        case .artifactChunk:
            try await store.receive(chunk: RemotePeerCoding.decode(RemotePeerArtifactChunk.self, request.payload), grant: grant)
        case .artifactCommit:
            let url = try await store.commit(RemotePeerCoding.decode(RemotePeerArtifactCommit.self, request.payload), grant: grant)
            struct Result: Encodable { let transferID: UUID; let directory: String }
            let commit = try RemotePeerCoding.decode(RemotePeerArtifactCommit.self, request.payload)
            return try RemotePeerCoding.encode(Result(transferID: commit.transferID, directory: url.path))
        default: throw RemotePeerError.unauthorized
        }
        return Data("{}".utf8)
    }
    /// Stable command IDs are supplied by the origin's durable transfer record;
    /// never regenerate them after an uncertain delivery.
    package func send(manifest: RemotePeerArtifactManifest, grant: RemotePeerSignedGrant, transport: any RemotePeerTransport,
        manifestCommandID: UUID, chunkCommandIDs: [[UUID]], commitCommandID: UUID) async throws -> Data {
        try manifest.validate(grant: grant.grant)
        guard chunkCommandIDs.count == manifest.files.count,
              zip(chunkCommandIDs, manifest.files).allSatisfy({ $0.0.count == $0.1.chunks.count }),
              Set([manifestCommandID, commitCommandID] + chunkCommandIDs.flatMap { $0 }).count == 2 + chunkCommandIDs.flatMap({ $0 }).count else {
            throw RemotePeerError.invalidConfiguration
        }
        _ = try await transport.request(.init(commandID: manifestCommandID, action: .artifactManifest, grant: grant,
            payload: RemotePeerCoding.encode(manifest)), timeout: 30)
        for (fileIndex, ids) in chunkCommandIDs.enumerated() {
            for (chunkIndex, commandID) in ids.enumerated() {
                let chunk = try await store.chunk(transferID: manifest.transferID, fileIndex: fileIndex, chunkIndex: chunkIndex, grant: grant.grant)
                _ = try await transport.request(.init(commandID: commandID, action: .artifactChunk, grant: grant,
                    payload: RemotePeerCoding.encode(chunk)), timeout: 30)
            }
        }
        let commit = RemotePeerArtifactCommit(transferID: manifest.transferID,
            manifestSHA256: RemotePeerArtifactManifest.hash(try RemotePeerCoding.encode(manifest)))
        return try await transport.request(.init(commandID: commitCommandID, action: .artifactCommit, grant: grant,
            payload: RemotePeerCoding.encode(commit)), timeout: 30)
    }
}
