import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import SwiftUI

struct WorkspaceExplorer: View {
    @Environment(AppModel.self) private var model
    let workspacePath: String?
    @State private var directory = "."
    @State private var entries: [WorkspaceEntry] = []
    @State private var preview: String?
    @State private var selectedPath: String?
    @State private var error: String?
    @State private var isLoading = false
    @State private var revision = 0
    @State private var selectionToken = UUID()
    @State private var editTarget: WorkspaceEditTarget?
    @State private var showSearch = false
    @State private var attachmentStatus: String?
    private let files = WorkspaceFileToolService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    selectedPath = nil; preview = nil; selectionToken = UUID()
                    error = nil; isLoading = false
                    if directory != "." {
                        let parent = (directory as NSString).deletingLastPathComponent
                        directory = parent.isEmpty ? "." : parent
                    }
                } label: { Image(systemName: "arrow.up") }
                .disabled(directory == "." && selectedPath == nil)
                .help("Parent folder")
                Text(selectedPath ?? (directory == "." ? "Workspace" : directory))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .disabled(workspacePath == nil).help("Search text in workspace files")
                if let workspacePath, let selectedPath, preview != nil {
                    Button {
                        if let preview, model.attachWorkspacePreview(preview, named: selectedPath, from: workspacePath) {
                            attachmentStatus = "Added to draft · sent only when you send the message"
                        }
                    } label: { Image(systemName: "plus.bubble") }
                    .disabled(!model.canImportAttachments)
                    .help("Attach this text snapshot to the next message")
                    Button {
                        editTarget = WorkspaceEditTarget(workspace: workspacePath, path: selectedPath)
                    } label: { Image(systemName: "pencil") }
                    .help("Prepare a local file edit")
                }
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh files")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 15)

            if workspacePath == nil {
                ContentUnavailableView("Choose a workspace", systemImage: "folder", description: Text("Select a folder from the composer to browse its files."))
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    if let attachmentStatus {
                        Text(attachmentStatus).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.bottom, 7)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview.isEmpty ? "(Empty file)" : preview)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).padding(16)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                List(entries) { entry in
                    Button { open(entry) } label: {
                        Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                            .font(.system(size: 12)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
                if entries.isEmpty { Text("No visible files").foregroundStyle(.secondary).padding(16) }
            }
            Text("Local files · UTF-8 · 1 MB maximum")
                .font(.caption2).foregroundStyle(.secondary).padding(15)
        }
        .task(id: "\(workspacePath ?? "")|\(directory)|\(revision)") { await reload() }
        .onChange(of: workspacePath) { _, _ in directory = "."; selectedPath = nil; preview = nil; attachmentStatus = nil; selectionToken = UUID() }
        .sheet(item: $editTarget) { target in
            WorkspaceEditView(target: target) { revision += 1 }
        }
        .sheet(isPresented: $showSearch) {
            if let workspace = workspacePath {
                WorkspaceSearchView(workspace: workspace) { entry in
                    guard workspacePath == workspace else { return }
                    open(entry)
                }.id(workspace)
            }
        }
    }

    private func reload() async {
        selectionToken = UUID(); selectedPath = nil; preview = nil; error = nil; attachmentStatus = nil
        guard let workspacePath else { return }
        isLoading = true
        do {
            let result = try await files.entries(workspace: workspacePath, path: directory)
            guard !Task.isCancelled else { return }
            entries = result; isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }

    private func open(_ entry: WorkspaceEntry) {
        if entry.isDirectory { directory = entry.path; return }
        let token = UUID()
        selectionToken = token; selectedPath = entry.path; isLoading = true; error = nil; attachmentStatus = nil
        Task {
            let result = await files.execute(ToolRequest(name: "read_file", arguments: ["path": entry.path], risk: .readOnly, workspacePath: workspacePath))
            guard selectionToken == token else { return }
            isLoading = false
            if result.isError { error = result.content } else { preview = result.content }
        }
    }
}
