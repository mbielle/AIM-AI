import AIMApplication
import SwiftUI

struct LocalHistoryCopyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preview: AccountChatSync.LocalCopyPreview?
    @State private var selected: Set<UUID> = []
    @State private var busy = false
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy local conversations to your account").font(.title2)
            Text("Destination: \(model.account.accessUser?.email ?? "signed-in account"). Selected messages, input attachments and project names/instructions will become separate account copies and synchronize with your configured backend. Local originals stay on this Mac. Code, Agent runs, generated media, memory, credentials and linked project files are excluded.")
                .font(.callout).foregroundStyle(.secondary)
            if let preview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(preview.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                                })) { Text(item.title).fontWeight(.medium) }
                                DisclosureGroup("Review \(item.messages.count) messages" + (item.projectName.map { " · " + $0 } ?? "")) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        if let instructions = item.projectInstructions, !instructions.isEmpty {
                                            Text("Project instructions\n" + instructions).textSelection(.enabled)
                                        }
                                        ForEach(item.messages) { row in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(row.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                                Text(row.text).textSelection(.enabled)
                                                ForEach(row.attachments ?? []) { input in
                                                    Text("Attachment: " + input.name).font(.caption)
                                                }
                                            }
                                        }
                                    }.font(.callout).padding(.top, 6)
                                }.padding(.leading, 20)
                            }
                        }
                        if preview.items.isEmpty { Text("No portable local conversations to copy.").foregroundStyle(.secondary) }
                    }
                }
                if preview.skippedConversations > 0 {
                    Text("\(preview.skippedConversations) local conversations are not portable chat histories and remain on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            } else if busy { ProgressView("Loading local history…") }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh preview") { Task { await load() } }.disabled(busy)
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
                Button("Copy \(selected.count) selected…") { confirm = true }.disabled(busy || selected.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 720, height: 640)
        .task { await load() }
        .onChange(of: model.account.accessUser?.id) { _, _ in preview = nil; selected = []; dismiss() }
        .confirmationDialog("Copy the selected local histories to this account?", isPresented: $confirm) {
            Button("Copy to account") { Task { await copy() } }
        } message: {
            Text("These separate copies can be uploaded to your configured account backend. The local originals are preserved.")
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        selected = []; message = nil
        do { preview = try await model.localHistoryCopy.preview() }
        catch { preview = nil; message = "The local history could not be reviewed safely. No conversations were copied." }
    }
    private func copy() async {
        guard let preview else { return }
        busy = true; defer { busy = false }
        do {
            let count = try await model.localHistoryCopy.copy(preview, selectedIDs: selected)
            selected = []; message = "\(count) separate account copies are available. Local originals were preserved."
        } catch {
            message = "Copy stopped because the account or reviewed history changed, or storage is unavailable. Local originals are preserved. Any completed account copies are kept; retrying this preview does not duplicate them."
        }
    }
}
