import AIMMacPlatform
import SwiftUI

struct GitHistoryView: View {
    let workspacePath: String?
    @Environment(\.dismiss) private var dismiss
    @State private var service = GitReviewService()
    @State private var commits: [GitCommitSummary] = []
    @State private var selection: String?
    @State private var loading = false
    @State private var error: String?
    @State private var detail = AttributedString()
    @State private var loadingDetail = false
    @State private var showingDiff = false

    private struct Selection: Equatable { let workspace: String?; let hash: String?; let diff: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Commit history").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Latest 100 commits on the current branch affecting this workspace. Local and read-only.")
                .font(.caption).foregroundStyle(.secondary)
            if loading {
                ProgressView("Reading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                Text("No commits affect this workspace.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(commits, selection: $selection) { commit in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject).lineLimit(2)
                            Text("\(commit.hash.prefix(8)) · \(commit.authoredAt.prefix(10))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(commit.hash)
                    }.frame(minWidth: 220, idealWidth: 260)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Commit display", selection: $showingDiff) {
                            Text("Summary").tag(false)
                            Text("Changes").tag(true)
                        }.pickerStyle(.segmented).padding(.horizontal, 8)
                        if showingDiff {
                            Text("Compared with the first parent; root commits use the empty tree. Renames appear as removal/addition. Binary contents are not shown.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        }
                        if loadingDetail { ProgressView("Reading commit…") }
                        else {
                            ScrollView([.horizontal, .vertical]) {
                                Text(detail).font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                            }
                        }
                    }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20).frame(minWidth: 720, idealWidth: 850, minHeight: 460, idealHeight: 580)
        .task(id: workspacePath) {
            commits = []; selection = nil; error = nil; loading = true
            defer { if !Task.isCancelled { loading = false } }
            guard let workspacePath else { return }
            do {
                let result = try await service.history(workspace: workspacePath)
                try Task.checkCancellation()
                commits = result; selection = result.first?.hash
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: Selection(workspace: workspacePath, hash: selection, diff: showingDiff)) {
            detail = AttributedString(); loadingDetail = false
            guard let workspacePath, let selection else { return }
            loadingDetail = true
            defer { if !Task.isCancelled { loadingDetail = false } }
            do {
                let result = try await showingDiff
                    ? service.commitDiff(workspace: workspacePath, hash: selection)
                    : service.commitSummary(workspace: workspacePath, hash: selection)
                try Task.checkCancellation()
                detail = showingDiff ? GitDiffText.format(result) : AttributedString(result)
            } catch { if !Task.isCancelled { detail = AttributedString(error.localizedDescription) } }
        }
    }
}
