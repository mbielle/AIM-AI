import AIMMacPlatform
import SwiftUI

struct GitWorktreeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: String
    var continueConversation = false
    @State private var service = GitWorktreeService()
    @State private var worktrees: [GitWorktree] = []
    @State private var loading = true
    @State private var selecting = false
    @State private var creating = false
    @State private var showingCreation = false
    @State private var showingCreationConfirmation = false
    @State private var folderName = ""
    @State private var branchName = ""
    @State private var creationPreview: GitWorktreeCreationPreview?
    @State private var createdPath: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Git worktrees").font(.title2)
                Spacer()
                Button(showingCreation ? "Hide new worktree" : "New worktree") {
                    showingCreation.toggle()
                    creationPreview = nil
                }.disabled(creating || selecting)
                Button("Refresh") { Task { await refresh() } }.disabled(loading || selecting || creating)
                Button("Done") { dismiss() }.disabled(selecting || creating)
            }
            Text("Open an existing worktree or create a new branch and sibling folder from the current commit. AIM never overwrites a branch or folder.")
                .font(.callout).foregroundStyle(.secondary)
            if showingCreation { creationForm }
            if loading { ProgressView("Reading worktrees…") }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let createdPath {
                Text("Created \(createdPath). Select Use workspace below when you are ready to switch.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(worktrees) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.isBare ? "externaldrive" : "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                            .font(.headline).lineLimit(1)
                        Text(entry.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Text(detail(for: entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if canonical(entry.path) == canonical(workspace) {
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Use workspace") { Task { await choose(entry) } }
                            .disabled(!entry.isAvailable || selecting || creating || loading || model.isSending || model.isLoadingConversation || model.isChangingWorkspace)
                    }
                }.padding(.vertical, 5)
            }
            .overlay {
                if !loading && error == nil && worktrees.isEmpty {
                    Text("No worktrees found").foregroundStyle(.secondary)
                }
            }
            Text("A missing, locked or prunable worktree cannot be selected. Finish an active response before switching workspaces.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 660, height: showingCreation ? 640 : 490)
        .task(id: workspace) {
            // Settings › Git: new branches start with the chosen prefix.
            if branchName.isEmpty { branchName = IntegrationPreferences.branchPrefix }
            await refresh()
        }
        .confirmationDialog("Create this Git worktree?", isPresented: $showingCreationConfirmation) {
            Button("Create new branch and worktree") { Task { await create() } }
        } message: {
            if let creationPreview {
                Text("Branch: \(creationPreview.branch)\nFolder: \(creationPreview.targetPath)\nFrom commit: \(creationPreview.startCommit)\nNo existing branch or folder will be overwritten.")
            }
        }
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("New sibling folder name", text: $folderName)
                    .accessibilityLabel("New worktree folder name")
                TextField("New branch name", text: $branchName)
                    .accessibilityLabel("New worktree branch name")
                Button("Review") { Task { await reviewCreation() } }
                    .disabled(folderName.isEmpty || branchName.isEmpty || creating || selecting || loading || model.isSending)
            }
            if let creationPreview {
                Text("\(creationPreview.targetPath) · \(creationPreview.branch) · \(creationPreview.startCommit.prefix(12))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Button("Create reviewed worktree") { showingCreationConfirmation = true }
                    .disabled(creating || selecting || model.isSending || model.isLoadingConversation || model.isChangingWorkspace)
            } else {
                Text("Choose an unused sibling folder and a new branch, such as codex/my-feature. Review the exact destination before creation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if creating { ProgressView("Creating worktree…").controlSize(.small) }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: folderName) { _, _ in creationPreview = nil }
        .onChange(of: branchName) { _, _ in creationPreview = nil }
    }

    private func reviewCreation() async {
        guard !creating, !selecting, !model.isSending else { return }
        error = nil; createdPath = nil; creationPreview = nil
        do {
            creationPreview = try await service.previewCreation(
                workspace: workspace, folderName: folderName, branch: branchName)
        } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        guard let creationPreview, !creating, !selecting, !model.isSending,
              !model.isLoadingConversation, !model.isChangingWorkspace,
              model.workspacePath == workspace else { return }
        creating = true; error = nil; createdPath = nil
        defer { creating = false }
        do {
            let entry = try await service.create(workspace: workspace, expected: creationPreview)
            createdPath = entry.path
            self.creationPreview = nil
            showingCreation = false
            worktrees = try await service.list(workspace: workspace)
        } catch {
            let message = error.localizedDescription
            self.creationPreview = nil
            await refresh()
            self.error = message
        }
    }

    private func detail(for entry: GitWorktree) -> String {
        if entry.isBare { return "Bare repository · cannot open as a workspace" }
        if let reason = entry.lockedReason { return "Locked · \(reason)" }
        if let reason = entry.prunableReason { return "Unavailable · \(reason)" }
        let branch = entry.branch.map { String($0.dropFirst("refs/heads/".count)) } ?? "Detached HEAD"
        return entry.head.map { "\(branch) · \($0.prefix(12))" } ?? branch
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func refresh() async {
        guard !selecting else { return }
        loading = true; error = nil
        do { worktrees = try await service.list(workspace: workspace) }
        catch { worktrees = []; self.error = error.localizedDescription }
        loading = false
    }

    private func choose(_ entry: GitWorktree) async {
        guard !selecting, !model.isSending, !model.isLoadingConversation, !model.isChangingWorkspace else { return }
        selecting = true; error = nil
        do {
            let validated = try await service.validatedWorkspace(currentWorkspace: workspace, selectedPath: entry.path)
            guard !model.isSending, !model.isLoadingConversation, !model.isChangingWorkspace,
                  model.workspacePath == workspace else {
                throw GitWorktreeError.changedSelection
            }
            if continueConversation {
                guard let last = model.messages.last, model.canBranchConversation else { throw GitWorktreeError.changedSelection }
                let original = model.selectedConversationID
                await model.branchConversation(at: last, edit: false)
                guard model.selectedConversationID != original else { throw GitWorktreeError.changedSelection }
            }
            if await model.chooseWorkspace(validated) { dismiss() }
        } catch { self.error = error.localizedDescription }
        selecting = false
    }
}
