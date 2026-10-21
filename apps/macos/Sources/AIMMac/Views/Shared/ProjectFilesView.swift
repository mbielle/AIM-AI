import AIMApplication
import SwiftUI
import UniformTypeIdentifiers

struct ProjectFilesView: View {
    let project: AIMProject
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [ProjectDocument] = []
    @State private var sources: [ProjectSource] = []
    @State private var importing = false
    @State private var folderImporting = false
    @State private var busy = false
    @State private var error: String?
    @State private var removal: ProjectDocument?
    @State private var sourceRemoval: ProjectSource?
    @State private var writeConsent: ProjectSource?
    @State private var preview: ProjectDocument?
    @State private var scanSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Files · \(project.name)").font(.title2).lineLimit(1)
                Spacer()
                Button("Link folder…") { folderImporting = true }.disabled(busy || model.isSending)
                Button("Add text or PDF…") { importing = true }.disabled(busy || model.isSending)
                Button("Done") { dismiss() }.disabled(busy)
            }
            Text("Linked folders start read-only. Grant Code access separately for each folder you want to use as a working directory; revoking it does not remove the read-only index. Only relevant excerpts are sent to your BYOK model. Hidden, dependency, binary and likely secret files are excluded, but no filter is perfect. Imported text/PDF copies below are included in every project request.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if let scanSummary { Text(scanSummary).font(.callout).foregroundStyle(.secondary) }
            List {
                Section("Linked folders · relevant excerpts only") {
                    if sources.isEmpty { Text("No linked folders").foregroundStyle(.secondary) }
                    ForEach(sources) { source in
                        HStack {
                            Label(source.displayName, systemImage: "folder").lineLimit(1)
                            Spacer()
                            Text(source.lastScannedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not indexed")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(source.writeAccessGranted ? "Revoke Code access" : "Allow Code access") {
                                if source.writeAccessGranted { setWriteAccess(source, granted: false) }
                                else { writeConsent = source }
                            }.disabled(busy || model.isSending)
                            Button("Rescan") { indexFolder(URL(fileURLWithPath: source.canonicalPath)) }.disabled(busy || model.isSending)
                            Button("Remove") { sourceRemoval = source }.disabled(busy || model.isSending)
                        }
                    }
                }
                Section("Imported copies · included in every request") {
                    if documents.isEmpty { Text("No text files imported").foregroundStyle(.secondary) }
                    ForEach(documents) { document in
                        HStack {
                            Button { preview = document } label: {
                                Label(document.name, systemImage: "doc.text").lineLimit(1)
                            }.buttonStyle(.plain)
                            Spacer()
                            Text("\(document.content.utf8.count) bytes").font(.caption).foregroundStyle(.secondary)
                            Button("Remove") { removal = document }.disabled(busy || model.isSending)
                        }
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }.padding(24).frame(width: 760, height: 500)
        .task { await refresh() }
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case let .success(url):
                busy = true; error = nil
                Task {
                    do { try await model.importProjectDocument(url, projectID: project.id); await refresh() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            case .failure: error = "The file could not be selected."
            }
        }
        .fileImporter(isPresented: $folderImporting, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): indexFolder(url)
            case .failure: error = "The folder could not be selected."
            }
        }
        .confirmationDialog("Remove this imported copy? The original file is not changed.", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { document in
            Button("Remove copy", role: .destructive) {
                removal = nil; busy = true
                Task {
                    do { try await model.removeProjectDocument(document.id, projectID: project.id); await refresh() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        }
        .confirmationDialog("Remove this folder's local index? The original folder is not changed.", isPresented: Binding(get: { sourceRemoval != nil }, set: { if !$0 { sourceRemoval = nil } }), presenting: sourceRemoval) { source in
            Button("Remove index", role: .destructive) {
                sourceRemoval = nil; busy = true
                Task {
                    do { try await model.removeProjectSource(source); await refresh() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        }
        .confirmationDialog("Allow Code to modify files in this folder?", isPresented: Binding(get: { writeConsent != nil }, set: { if !$0 { writeConsent = nil } }), presenting: writeConsent) { source in
            Button("Allow Code access") { writeConsent = nil; setWriteAccess(source, granted: true) }
            Button("Cancel", role: .cancel) { writeConsent = nil }
        } message: { source in
            Text("\(source.displayName) will become selectable as a working folder. File edits follow the approval mode; shell commands still require separate approval because they are not confined to this folder.")
        }
        .sheet(item: $preview) { document in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(document.name).font(.headline); Spacer(); Button("Done") { preview = nil } }
                ScrollView {
                    Text(document.content.isEmpty ? "(Empty file)" : document.content)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24).frame(width: 640, height: 450)
        }
    }
    private func refresh() async {
        do {
            documents = try await model.documents(for: project.id)
            sources = try await model.sources(for: project.id)
        } catch { self.error = "Project files could not be loaded." }
    }

    private func indexFolder(_ url: URL) {
        busy = true; error = nil; scanSummary = nil
        Task {
            do {
                let scan = try await model.indexProjectFolder(url, projectID: project.id)
                scanSummary = "Indexed \(scan.indexedFiles) text files locally. Skipped \(scan.skippedFiles)." + (scan.isPartial ? " This index is incomplete; large or inaccessible files were skipped." : "") + (scan.hasReadErrors ? " Some entries could not be read; resolve this before sending." : "")
                await refresh()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func setWriteAccess(_ source: ProjectSource, granted: Bool) {
        busy = true; error = nil
        Task {
            do { try await model.setProjectSourceWriteAccess(source, granted: granted); await refresh() }
            catch { self.error = "Could not update folder access: \(error.localizedDescription)" }
            busy = false
        }
    }
}
