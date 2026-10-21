#if DEBUG
import AIMCore
import SwiftUI

/// Debug-only panel driving the same connection store and RPC service as AIM.
/// The ordinary connection UI is covered separately by AIMUITests.
struct AIMQAClientView: View {
    let context: AIMQAContext
    @State private var direct: AIMDirectConnectionStore?
    @State private var status = "Preparing QA client"
    @State private var verified = false
    @State private var catalogMatches = false
    @State private var pairID = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("AIM isolated Remote qualification").font(.headline)
            Text(status).accessibilityIdentifier("qa-client-status")
            if let direct {
                Text(direct.statusText).accessibilityIdentifier("qa-connection-state")
                Text(pairID).accessibilityIdentifier("qa-pair-id")
                Button("Pair QA Mac") { Task { await pair(direct) } }.accessibilityIdentifier("qa-pair")
                Button("Verify remote data") { Task { await verify(direct) } }.accessibilityIdentifier("qa-verify")
                Button("Disconnect QA Mac") { Task { await direct.disconnect(); verified = false } }
                    .accessibilityIdentifier("qa-disconnect")
                Button("Reconnect QA Mac") {
                    Task { if let id = direct.records.first?.pair.id { await direct.connect(id) } }
                }.accessibilityIdentifier("qa-reconnect")
                Text(verified ? "read-ok" : "read-pending").accessibilityIdentifier("qa-read-result")
                Text(catalogMatches ? "catalog-ok" : "catalog-pending").accessibilityIdentifier("qa-catalog-result")
            }
        }.padding(24)
        .task { await prepare() }
    }

    @MainActor private func prepare() async {
        do {
            let store = try context.store("phone")
            let profile = try LocalProfile.loadOrCreate(store: store)
            let value = try AIMDirectConnectionStore(profile: profile, secureStore: store)
            direct = value
            await value.start()
            pairID = value.records.first?.pair.id.uuidString ?? "unpaired"
            status = "QA client ready"
        } catch { status = "QA client preparation failed" }
    }

    @MainActor private func pair(_ direct: AIMDirectConnectionStore) async {
        guard let text = context.invitation, let url = URL(string: text),
              let invitation = try? DirectRemoteInvite.decodeQR(url) else {
            status = "QA invitation missing"; return
        }
        status = "Waiting for explicit Mac confirmation"
        await direct.pair(invitation)
        pairID = direct.records.first?.pair.id.uuidString ?? "unpaired"
        status = direct.records.isEmpty ? "Pairing failed" : "QA client ready"
    }

    @MainActor private func verify(_ direct: AIMDirectConnectionStore) async {
        do {
            let overview = try await direct.service.loadOverview()
            guard let machine = overview.machines.first,
                  let session = overview.sessions.first(where: { $0.title == context.marker }) else {
                throw DirectRemoteError.unavailable("synthetic_session_missing")
            }
            let messages = try await direct.service.loadMessages(sessionID: session.id, machineID: machine.id)
            verified = messages.contains { $0.content == context.marker }
            let digest = try AIMQAContext.catalogDigest(machine.capabilities?.models ?? [])
            catalogMatches = digest == context.expectedCatalog && !context.injectCatalogMismatch
            status = !verified ? "Remote content mismatch" : !catalogMatches ? "Catalog mismatch" : "Remote verification passed"
            try context.receipt(["status": verified && catalogMatches ? "passed" : "failed",
                "read_matches": String(verified), "catalog_matches": String(catalogMatches),
                "models_sha256": digest, "pair_id": pairID, "execution_device": "mac",
                "observed_transport": direct.statusText,
                "stage": !catalogMatches ? "catalog" : "read"], name: "client-result")
        } catch {
            status = "Remote verification failed"
            try? context.receipt(["status": "failed", "stage": "read-or-connect"], name: "client-result")
        }
    }
}
#endif
