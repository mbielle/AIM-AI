# Security

Report suspected vulnerabilities privately to contact@aim-ai.tech. Do not open a
public issue containing exploitation steps against the live service, credentials,
private conversations, account identifiers or authorization tokens. Include the
component/version, expected boundary and a synthetic reproduction where possible.

Local profiles are storage identities, not cloud credentials. Account sessions,
paired-device and machine secrets, approval grants, encryption, local permissions
and server RLS remain required after removal of paid access.

Provider credentials belong in the user's Keychain. Apple APNs keys and service-role
credentials remain server-only. Use your own identifiers and signing material for
forks; never share the official release's private configuration.

Publication checks are defense in depth, not a guarantee that a repository is safe.
Review source, bundled assets and dependency licenses before publishing artifacts.
