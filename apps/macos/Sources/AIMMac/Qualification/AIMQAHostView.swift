#if DEBUG
import AIMCore
import AIMApplication
import SwiftUI

/// The production coordinator and host bridge, with isolated data and an
/// explicit on-screen Mac confirmation. No automatic permission grant.
struct AIMQAHostView: View {
    let context: AIMQAContext
    let model: AppModel
    @State private var direct: MacDirectRemoteCoordinator?
    @State private var status = "Preparing isolated host"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AIM — isolated Remote qualification").font(.title)
            Text(status).accessibilityIdentifier("qa-host-status")
            if let direct {
                if let message = direct.message { Text(message).accessibilityIdentifier("qa-host-error") }
                Text(direct.statusText)
                ForEach(direct.pending, id: \.id) { client in
                    Button("Confirm QA iPhone") {
                        Task {
                            try? context.receipt(["status": "clicked"], name: "host-confirmation-attempt")
                            await direct.confirm(client.id, permissions: [.read, .chat])
                            if let pair = direct.records.first(where: { $0.pair.client.id == client.id && !$0.pair.revoked }) {
                                try? context.receipt(["status": "confirmed", "pair_id": pair.pair.id.uuidString], name: "host-confirmation")
                            } else {
                                try? context.receipt(["status": "failed", "stage": "explicit-confirmation"], name: "host-confirmation")
                            }
                        }
                    }.accessibilityIdentifier("qa-confirm-client")
                }
                Text("Paired devices: \(direct.records.filter { !$0.pair.revoked }.count)")
                    .accessibilityIdentifier("qa-pair-count")
            }
        }.padding(32)
        .task { await prepare() }
        .task {
            while !Task.isCancelled {
                await direct?.refresh()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    @MainActor private func prepare() async {
        guard direct == nil else { return }
        do {
            let store = try context.store("host")
            guard let profile = model.account.localProfile else { throw DirectRemoteError.invalidConfiguration }
            let conversation = Conversation(title: context.marker, provider: .local, modelID: "aim-qa-model")
            try await model.conversationRepository.save(conversation)
            try await model.conversationRepository.append(.init(conversationID: conversation.id, role: .assistant,
                content: context.marker, sequence: 1))
            model.conversations = [conversation]
            model.connectedProviders = [.local]
            model.settings.favoriteModels = [try .init(provider: .local, modelID: "aim-qa-model", name: "QA deterministic provider")]
            try await ModelCatalogCache.shared.save([.init(id: "aim-qa-model", name: "QA deterministic provider")], for: .local)
            let coordinator = try MacDirectRemoteCoordinator(model: model, profile: profile, secureStore: store)
            direct = coordinator
            await coordinator.setEnabled(true)
            await coordinator.createInvite(coordinator: "")
            guard let invite = coordinator.invitation else { throw DirectRemoteError.unavailable("invitation_unavailable") }
            let url = try invite.qrURL()
            // This private file is consumed only by the local driver. Never add
            // it to public receipts, screenshots or the owner evidence bundle.
            let privateURL = context.directory.appendingPathComponent("invite.private")
            try Data(url.absoluteString.utf8).write(to: privateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
            let models = await RemoteHostBridge(model: model).remoteCapabilities().models
            try context.receipt(["status": "ready", "models_sha256": try AIMQAContext.catalogDigest(models),
                "model_boundary": "deterministic", "confirmation": "required-on-Mac"], name: "host-ready")
            status = "Ready for QA iPhone — Mac confirmation required"
        } catch {
            status = "Host preparation failed: \(String(describing: type(of: error)))"
            try? context.receipt(["status": "failed", "stage": "host-prepare"], name: "host-ready")
        }
    }
}
#endif
