import AIMMacPlatform
import SwiftUI

struct GitPushView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: String
    let onPushed: () -> Void
    @State private var service = GitPushService()
    @State private var remotes: [GitPushRemote] = []
    @State private var selectedRemote = ""
    @State private var preview: GitPushPreview?
    @State private var error: String?
    @State private var loading = true
    @State private var pushing = false
    @State private var pushed = false
    @State private var confirming = false
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Push a branch").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(pushing)
            }
            Text("Push the current local branch to a selected Git remote. AIM never force-pushes, does not run repository hooks, and asks before network writes.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("Checking branch and remote…") }
            if let error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    Button("Refresh") { load() }.disabled(pushing)
                }.font(.callout)
            }
            if !remotes.isEmpty {
                Picker("Remote", selection: $selectedRemote) {
                    ForEach(remotes) { remote in Text(remote.name).tag(remote.name) }
                }.disabled(pushing || pushed)
            }
            if let preview {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow { Text("Destination").foregroundStyle(.secondary); Text(preview.remote.destination).textSelection(.enabled) }
                    GridRow { Text("Branch").foregroundStyle(.secondary); Text(preview.branch).textSelection(.enabled) }
                    GridRow { Text("Local commit").foregroundStyle(.secondary); Text(preview.head).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    GridRow { Text("Remote branch").foregroundStyle(.secondary); Text(preview.branch) }
                }.font(.callout)
                Text("This does not fetch or merge remote changes. Git will reject a non-fast-forward push. Authentication uses your existing Git/SSH setup; no Git credential is stored by AIM.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pushed, let preview {
                Label("Pushed \(preview.head.prefix(12)) to \(preview.remote.name)/\(preview.branch)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if pushing { ProgressView().controlSize(.small) }
                Button("Push branch…") { confirming = true }
                    .buttonStyle(.settingsPrimary)
                    .disabled(preview == nil || loading || pushing || pushed)
            }
        }
        .padding(24).frame(width: 650, height: 390)
        .task { load() }
        .onChange(of: selectedRemote) { _, name in
            if !loading && !name.isEmpty { loadPreview(remote: name) }
        }
        .onDisappear { operation?.cancel(); requestID = UUID() }
        .confirmationDialog("Push this branch to the selected remote?", isPresented: $confirming) {
            if let preview {
                Button("Push \(preview.branch) to \(preview.remote.name)") { push(preview) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(preview.map { "Destination: \($0.remote.destination)\nCommit: \($0.head)\nNo force push." } ?? "Refresh the preview before pushing.")
        }
    }

    private func load() {
        operation?.cancel()
        let id = UUID(); requestID = id
        loading = true; preview = nil; error = nil
        operation = Task {
            do {
                let found = try await service.remotes(workspace: workspace)
                guard requestID == id, !Task.isCancelled else { return }
                remotes = found
                let chosen = found.contains(where: { $0.name == selectedRemote }) ? selectedRemote : found[0].name
                selectedRemote = chosen
                preview = try await service.preview(workspace: workspace, remote: chosen)
            } catch {
                if requestID == id, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if requestID == id { loading = false; operation = nil }
        }
    }

    private func loadPreview(remote: String) {
        operation?.cancel()
        let id = UUID(); requestID = id
        loading = true; preview = nil; error = nil
        operation = Task {
            do {
                let checked = try await service.preview(workspace: workspace, remote: remote)
                guard requestID == id, selectedRemote == remote, !Task.isCancelled else { return }
                preview = checked
            } catch {
                if requestID == id, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if requestID == id { loading = false; operation = nil }
        }
    }

    private func push(_ expected: GitPushPreview) {
        operation?.cancel()
        let id = UUID(); requestID = id
        pushing = true; error = nil
        operation = Task {
            do {
                try await service.push(workspace: workspace, expected: expected)
                guard requestID == id, !Task.isCancelled else { return }
                pushed = true
                onPushed()
            } catch {
                if requestID == id, !Task.isCancelled {
                    self.error = error.localizedDescription
                    preview = nil
                }
            }
            if requestID == id { pushing = false; operation = nil }
        }
    }
}
