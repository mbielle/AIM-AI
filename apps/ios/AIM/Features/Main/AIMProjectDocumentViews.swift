import AIMCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared local extraction and review. Only the final button calls the destination.
struct AIMProjectDocumentImportButton: View {
    let cloudUpload: Bool
    let commit: @MainActor (AIMPreparedProjectDocument) async -> Bool
    @State private var importing = false
    @State private var preparing = false
    @State private var saving = false
    @State private var pending: AIMPreparedProjectDocument?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { importing = true } label: { Label("projects.detail.add_file", systemImage: "plus") }
                .disabled(preparing || saving).accessibilityIdentifier("project-document-add")
            if preparing {
                HStack {
                    ProgressView()
                    Button("common.cancel") { cancel() }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            prepare(url)
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(pending.name).font(.headline)
                            Text(cloudUpload ? "project.files.cloud_review" : "project.files.local_review").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(pending.source.count), countStyle: .file))
                            Text(String(pending.text.prefix(40_000))).font(.callout).textSelection(.enabled)
                            if pending.text.count > 40_000 { Text("project.sources.preview_excerpt").font(.footnote).foregroundStyle(.secondary) }
                        }.padding()
                    }
                    .navigationTitle(Text("project.files.preview"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { self.pending = nil }.disabled(saving) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(cloudUpload ? "project.files.upload" : "project.files.keep") {
                                let token = generation
                                saving = true
                                task = Task { @MainActor in
                                    let saved = await commit(pending)
                                    guard !Task.isCancelled, token == generation else { return }
                                    saving = false
                                    if saved { self.pending = nil }
                                    else { error = String(localized: "projects.detail.file_upload_error"); self.pending = nil }
                                }
                            }.disabled(saving)
                        }
                    }
                    .interactiveDismissDisabled(saving)
                }
            }
        }
        .onDisappear { cancel(); pending = nil }
    }
    private func prepare(_ url: URL) {
        cancel(); preparing = true; error = nil
        let token = generation
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { try AIMPreparedProjectDocument.read(url) }
            do {
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                if cloudUpload { pending = prepared }
                else {
                    saving = true
                    let saved = await commit(prepared)
                    guard !Task.isCancelled, generation == token else { return }
                    saving = false
                    if !saved { error = String(localized: "project.sources.import_error") }
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
            }
            if generation == token { preparing = false }
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; preparing = false; saving = false }
}

/// Kept as a narrow compatibility entry point for existing callers.
struct AIMNativeProjectFilesView: View {
    let library: AIMProjectDocumentLibrary
    let projectID: UUID
    var body: some View { AIMProjectSourcesView(library: library, projectID: projectID) }
}
