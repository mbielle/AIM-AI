import AIMMacPlatform
import SwiftUI

struct GitCommitView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: String
    let onCommitted: () -> Void
    @State private var service = GitCommitService()
    @State private var preview: GitCommitPreview?
    @State private var message = ""
    @State private var error: String?
    @State private var createdHash: String?
    @State private var loading = true
    @State private var committing = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Commit staged changes").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(committing)
            }
            Text("This creates a local commit from the reviewed Git index only. It does not stage working files or push to a remote. Git hooks and automatic commit signing are skipped.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("Reading staged changes…") }
            if let error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(committing)
                }.font(.callout)
            }
            if let preview {
                HStack {
                    Label(preview.branch, systemImage: "arrow.triangle.branch")
                    Spacer()
                    Text("\(preview.entries.count) staged files").foregroundStyle(.secondary)
                }.font(.callout)
                List(preview.entries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.status).font(.system(size: 11, design: .monospaced))
                        Text(entry.path).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(minHeight: 180)
                Text("Inspect each staged diff in the Git panel before committing. This list shows paths, not full contents. If the branch or index changes, this confirmation expires.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Commit message", text: $message).textFieldStyle(.roundedBorder)
                    .disabled(committing || createdHash != nil)
            }
            if let createdHash {
                Text("Local commit created: \(createdHash.prefix(12))")
                    .font(.callout).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if committing { ProgressView().controlSize(.small) }
                Button("Create local commit") { confirming = true }
                    .buttonStyle(.settingsPrimary)
                    .disabled(preview == nil || loading || committing || createdHash != nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 610, height: 500)
        .task {
            // Settings › Git: the commit message template.
            if message.isEmpty { message = IntegrationPreferences.commitTemplate }
            await refresh()
        }
        .confirmationDialog("Create this local commit?", isPresented: $confirming) {
            Button("Commit listed staged changes") { startCommit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the staged tree shown here will be committed. No remote push occurs; Git hooks and automatic signing will not run.")
        }
    }

    private func refresh() async {
        guard !committing else { return }
        loading = true; preview = nil; error = nil
        do { preview = try await service.preview(workspace: workspace) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func startCommit() {
        guard let preview, !committing else { return }
        committing = true; error = nil
        let subject = message
        Task {
            defer { committing = false }
            do {
                let hash = try await service.commit(workspace: workspace, expected: preview, message: subject)
                guard !Task.isCancelled else { return }
                createdHash = hash
                onCommitted()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.preview = nil
            }
        }
    }
}
