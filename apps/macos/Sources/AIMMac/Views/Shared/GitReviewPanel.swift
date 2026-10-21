import AIMMacPlatform
import SwiftUI

struct GitReviewPanel: View {
    let workspacePath: String?
    @State private var service = GitReviewService()
    @State private var indexService = GitIndexService()
    @State private var snapshot: GitReviewSnapshot?
    @State private var selectedPath: String?
    @State private var staged = false
    @State private var revision = 0
    @State private var loading = false
    @State private var error: String?
    @State private var diff = AttributedString()
    @State private var rawDiff = ""
    @State private var loadingDiff = false
    @State private var filter = ""
    @State private var showingHistory = false
    @State private var showingWorktrees = false
    @State private var showingCommit = false
    @State private var showingPush = false
    @State private var showingIndexConfirmation = false
    @State private var pendingIndexChange: GitChange?
    @State private var pendingIndexDiff = ""
    @State private var pendingIndexWorkspace: String?
    @State private var pendingIndexStaged = false
    @State private var updatingIndex = false
    @State private var indexError: String?
    @State private var showingIndexError = false

    private struct LoadKey: Equatable { let workspace: String?; let revision: Int }
    private struct DiffKey: Equatable { let workspace: String?; let path: String?; let staged: Bool; let revision: Int }
    private var changes: [GitChange] {
        snapshot?.changes.filter {
            (staged ? $0.isStaged : $0.isUnstaged) &&
            (filter.isEmpty || $0.path.localizedStandardContains(filter) || ($0.originalPath?.localizedStandardContains(filter) ?? false))
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot?.branch ?? "Local changes")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(snapshot?.branch ?? "Local changes")
                Spacer()
                Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).help("Browse commit history")
                    .accessibilityLabel("Browse commit history")
                    .disabled(workspacePath == nil)
                Button { showingWorktrees = true } label: { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.plain).help("Browse Git worktrees")
                    .accessibilityLabel("Browse Git worktrees")
                    .disabled(workspacePath == nil)
                Button { showingCommit = true } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain).help("Commit staged changes")
                    .accessibilityLabel("Commit staged changes")
                    .disabled(workspacePath == nil || loading || !(snapshot?.changes.contains(where: \.isStaged) ?? false))
                Button { showingPush = true } label: { Image(systemName: "arrow.up.to.line") }
                    .buttonStyle(.plain).help("Push current branch")
                    .accessibilityLabel("Push current branch")
                    .disabled(workspacePath == nil || loading)
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh Git review")
                    .accessibilityLabel("Refresh Git review")
                    .disabled(workspacePath == nil || loading)
            }
            if workspacePath == nil {
                message("Choose a workspace in the composer to review its changes.")
            } else if loading {
                ProgressView("Reading Git status…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                message(error)
            } else if let snapshot, snapshot.changes.isEmpty {
                message("No local changes in this workspace.")
            } else {
                Picker("Changes", selection: $staged) {
                    Text("Working tree (\(snapshot?.changes.filter(\.isUnstaged).count ?? 0))").tag(false)
                    Text("Staged (\(snapshot?.changes.filter(\.isStaged).count ?? 0))").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter files…", text: $filter).textFieldStyle(.plain)
                        .accessibilityLabel("Filter Git changes")
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear file filter")
                    }
                }.font(.system(size: 12)).padding(7)
                if changes.isEmpty {
                    message(!filter.isEmpty ? "No files match this filter." : (staged ? "No staged changes." : "No working tree changes."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(changes) { change in
                                Button { selectedPath = change.path } label: {
                                    HStack(spacing: 8) {
                                        Text(change.status).font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(change.isConflicted ? .red : .secondary)
                                        Text(change.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(8)
                                    .background(selectedPath == change.path ? Color.primary.opacity(0.07) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
                                .accessibilityLabel("\(change.path), \(change.isConflicted ? "conflict" : change.status)")
                            }
                        }
                    }.frame(maxHeight: 180)
                    if loadingDiff {
                        ProgressView("Reading differences…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(diff).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let change = changes.first(where: { $0.path == selectedPath }), !rawDiff.isEmpty {
                        HStack {
                            Text("Only this reviewed file · Git index only")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button(staged ? "Unstage file" : "Stage file") {
                                pendingIndexChange = change
                                pendingIndexDiff = rawDiff
                                pendingIndexWorkspace = workspacePath
                                pendingIndexStaged = staged
                                showingIndexConfirmation = true
                            }
                            .disabled(loadingDiff || updatingIndex)
                        }
                    }
                }
            }
            Text("Review, stage, commit locally, then push only after confirming the remote")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .sheet(isPresented: $showingHistory) {
            GitHistoryView(workspacePath: workspacePath)
        }
        .sheet(isPresented: $showingWorktrees) {
            if let workspacePath { GitWorktreeView(workspace: workspacePath) }
        }
        .sheet(isPresented: $showingCommit) {
            if let workspacePath {
                GitCommitView(workspace: workspacePath) { revision += 1 }
            }
        }
        .sheet(isPresented: $showingPush) {
            if let workspacePath {
                GitPushView(workspace: workspacePath) { revision += 1 }
            }
        }
        .confirmationDialog(pendingIndexStaged ? "Unstage this file?" : "Stage this file?",
                            isPresented: $showingIndexConfirmation) {
            Button(pendingIndexStaged ? "Unstage reviewed file" : "Stage reviewed file") {
                Task { await updateIndex() }
            }
        } message: {
            Text("\(pendingIndexChange?.path ?? "Selected file")\nThe file status and preview will be checked again. Git may run repository-configured filters while staging.")
        }
        .alert("Git update failed", isPresented: $showingIndexError) {
            Button("OK", role: .cancel) { }
        } message: { Text(indexError ?? "The Git index could not be updated.") }
        .task(id: LoadKey(workspace: workspacePath, revision: revision)) { await refresh() }
        .task(id: DiffKey(workspace: workspacePath, path: selectedPath, staged: staged, revision: revision)) {
            await loadDiff()
        }
        .onChange(of: staged) { _, _ in selectedPath = changes.first?.path }
        .onChange(of: filter) { _, _ in
            if !changes.contains(where: { $0.path == selectedPath }) { selectedPath = changes.first?.path }
        }
        .onChange(of: workspacePath) { _, _ in showingIndexConfirmation = false }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func refresh() async {
        snapshot = nil; selectedPath = nil; error = nil; diff = AttributedString(); rawDiff = ""
        guard let workspacePath else { loading = false; return }
        loading = true
        do {
            let result = try await service.snapshot(workspace: workspacePath)
            try Task.checkCancellation()
            snapshot = result
            selectedPath = changes.first?.path
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func loadDiff() async {
        diff = AttributedString(); rawDiff = ""; loadingDiff = false
        guard let workspacePath, let selectedPath else { return }
        loadingDiff = true
        do {
            let result = try await service.diff(workspace: workspacePath, path: selectedPath, staged: staged)
            try Task.checkCancellation()
            rawDiff = result
            diff = GitDiffText.format(result)
        } catch {
            guard !Task.isCancelled else { return }
            diff = AttributedString(error.localizedDescription)
        }
        loadingDiff = false
    }

    @MainActor private func updateIndex() async {
        guard !updatingIndex, let change = pendingIndexChange,
              let pendingIndexWorkspace, workspacePath == pendingIndexWorkspace else { return }
        updatingIndex = true
        defer { updatingIndex = false }
        do {
            if pendingIndexStaged {
                try await indexService.unstage(workspace: pendingIndexWorkspace, change: change, reviewedDiff: pendingIndexDiff)
            } else {
                try await indexService.stage(workspace: pendingIndexWorkspace, change: change, reviewedDiff: pendingIndexDiff)
            }
            if workspacePath == pendingIndexWorkspace { revision += 1 }
        } catch {
            indexError = error.localizedDescription
            showingIndexError = true
        }
    }

}
