# AIM Direct native transport

This package provides the actual libdatachannel ICE/DTLS/SCTP implementation and
Network.framework local signalling. It does not authenticate an AIM account or
remove the native command approval/provider budget checks. Pairings belong to a
persistent `LocalProfile`; Supabase Remote remains a separate adapter.

Build the pinned static XCFramework before opening an app project or compiling
this package. Artifacts are generated, not fetched from an unverified binary URL:

```sh
python3 scripts/direct/build-native.py --cache /private/tmp/aim-direct-build --fetch --assemble
```

Requirements: Xcode with iPhone SDK, Python 3.9+, CMake 3.31+, Git, internet access
to the two pinned official source repositories and their pinned submodules. Use
`--cmake /absolute/path/to/cmake` when needed. Build slices: Mac arm64/x86_64,
iPhone arm64, simulator arm64/x86_64. Re-running slice builds is incremental. The
script refuses to replace an existing assembled XCFramework: archive/remove
only your generated artifact after review before assembling a replacement.
The receipt records source revisions, compiler/SDK toolchain and artifact hashes.
No signing identity, cloud credential or paid service is required.

`LibDataChannel` reports connected only after the native DataChannel opens and
selected ICE candidates are read. Relayed is reported only for selected `relay`
candidates. The signalling connection alone never establishes remote access.
The controller uses Bonjour `_aimdirect._tcp` for LAN; iOS needs local-network
permission and the matching `NSBonjourServices` entry. Internet mode needs the
configured WSS coordinator and, where direct ICE fails, a configured TURN relay.
An unavailable relay is not displayed as a successful connection.

QR invitations expire after 120 seconds. Scanning proposes a phone; the Mac must
explicitly confirm its identity and permissions. Cancelling invalidates pending
claims. The QR secret never goes to the coordinator. Both peers authenticate
reconnections with pinned P-256 keys; signalling and RPC payloads use the shared
AIM AES-GCM implementation. Session sequences and replay windows are durable.

RPC messages are encrypted in chunks, at most 4 MiB total, with bounded assembly
count and expiry. Larger reads fail explicitly and require paging. Host commands
are admitted to a private journal before execution. Retrying the same ID and
payload returns the previous result; changing the payload conflicts. A crash
after admission with no persisted result remains outcome-unknown and is not
re-executed automatically. Reading native job state after reconnection is separate
from replaying its creation command. Revocation rechecks the live grant and
closes pair-owned interactive control surfaces; a network disconnect alone does
not cancel Mac jobs.

## Reproducible synthetic qualification

Build Core's static product, then link the standalone qualification executable:

```sh
swift build --package-path packages/AIMCore
python3 scripts/direct/build-swift-probe.py --probe controller \
  --core-products packages/AIMCore/.build/out/Products/Debug \
  --module-cache /private/tmp/aim-direct-module-cache \
  --output /private/tmp/aim-direct-controller-probe
python3 scripts/direct/qualify-controller.py \
  --probe /private/tmp/aim-direct-controller-probe \
  --receipt /private/tmp/aim-direct-lan-receipt.json
```

For an explicitly running local coordinator add
`--coordinator ws://127.0.0.1:8789/v1/direct`. This forces coordinator signalling;
it cannot silently qualify LAN instead. Add `--relay` only with a real configured
local test TURN server; the probe requires selected native TURN candidates.
The probe uses synthetic identities, an isolated temporary directory, a simulated
explicit Mac confirmation, and a synthetic native job. It checks an encrypted
270 kB response, client-process exit, job continuation, reconnect/read and command
idempotence. It does not launch an app, call a model, or read user data. Its receipt
explicitly leaves app integration and physical-device qualification false.

Some sandboxed automation environments require permission to open local TCP/UDP
sockets and Bonjour. A sandbox socket denial is a failed qualification, not a
reason to substitute a mock transport. Temporary synthetic private keys/QR values
stay in the mode-0700 qualification directory; receipts contain no keys or text.

## Third-party licensing

AIM's code uses its repository license; linked third-party code retains its own
licenses, copied under `THIRD_PARTY_NOTICES`. libdatachannel is MPL-2.0:
redistribution must preserve its notices and make the exact MPL-covered sources
(and any modifications) available under MPL-2.0. The build fetches pinned upstream
sources at `https://github.com/paullouisageneau/libdatachannel` commit
`6b1e2e620f1e37f0eafeee702eaea0043cb305fd`. TLS is Mbed TLS 3.6.6,
`https://github.com/Mbed-TLS/mbedtls` commit
`0bebf8b8c7f07abe3571ded48a11aa907a1ffb20`, used under Apache-2.0;
its build configuration enables DTLS-SRTP for libdatachannel compatibility.
libjuice, usrsctp, plog and nlohmann/json retain their included notices.
The included MPL-2.0 patch `patches/relay-only-candidate-pairs.patch` adds a relay-only
candidate-pair policy to libjuice and passes it from libdatachannel. Upstream
v0.24.6 only filters advertised candidates; peer-reflexive discovery can otherwise
select a direct pair even with Relay configured. The patch forbids non-relayed
local pairs when Relay is requested and leaves the default All policy unchanged.
The original source checkouts stay unmodified. The build applies the reviewed
patch to a separate prepared tree, verifies its hash and each changed source file,
and rejects unreviewed changes or extra files before compilation. Include this
patch and the pinned source URLs with the MPL source notices when redistributing. Media,
WebSocket support and libsrtp are not linked in this transport build.

Application private mode closes admission to all direct network paths, including
LAN. Native WebRTC and Network.framework operations hold shared privacy leases
until actual native deletion or Network.framework cancellation is acknowledged;
a queued cancellation alone does not release a lease. New connection and send
boundaries recheck the policy. The controller observes the privacy fence and
closes listeners and sessions; WSS uses the managed URLSession registry. The
qualification executable is a dedicated qualification bundle with a temporary
home, so privacy probes never use the official app's preference suite or barrier.
