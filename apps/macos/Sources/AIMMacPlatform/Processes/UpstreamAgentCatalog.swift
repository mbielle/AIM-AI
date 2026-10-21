import AIMAgentKit
import Foundation

/// The upstream versions this build of AIM runs, shipped (and signed) with the app, so an app
/// update brings its agents' updates. Selection rule (scripts/agents/vet-upstream.py): the latest
/// official stable release (GitHub "Latest" for Hermes, npm `latest` for OpenClaw; never a beta)
/// published at least 7 days earlier, that passes the bridge contract and import checks.
public struct UpstreamAgentRelease: Sendable, Equatable {
    public let engine: AgentEngineID
    /// What the person sees, e.g. "0.21.5".
    public let version: String
    public let url: String
    public let digest: String
    public let sha512: Bool
    /// Hermes archives unpack into one folder named after the tag.
    public let archiveFolder: String?
    /// The managed Python the release supports (Hermes only).
    public let python: String?
    public let publishedAt: String
}

public enum UpstreamAgentCatalog {
    public static let releases: [UpstreamAgentRelease] = [
        UpstreamAgentRelease(engine: .hermes, version: "0.21.5",
            url: "https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/v2026.9.24",
            digest: "7c68fc895cc029441c0de303abf53a84d92c5346b59f03acdb61f3ef1174dce6", sha512: false,
            archiveFolder: "hermes-agent-2026.9.24", python: "3.13", publishedAt: "2026-09-24"),
        UpstreamAgentRelease(engine: .openClaw, version: "2026.9.8",
            url: "https://registry.npmjs.org/openclaw/-/openclaw-2026.9.8.tgz",
            digest: "G+JkNUhtpDE3cXR4AEi2NyyG9fqI/T2WUSl8ZnR8AATH8Dh1kC3qYFL7wwPoZtgHiP/cszA86PEiE0PDysxb9Q==", sha512: true,
            archiveFolder: nil, python: nil, publishedAt: "2026-10-03"),
    ]
    public static func release(_ engine: AgentEngineID) -> UpstreamAgentRelease? { releases.first { $0.engine == engine } }
}
