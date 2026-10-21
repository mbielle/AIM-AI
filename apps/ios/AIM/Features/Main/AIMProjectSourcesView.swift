import AIMCore
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AIMProjectSourcesView: View {
    let library: AIMProjectDocumentLibrary
    let projectID: UUID
    var contentTop: CGFloat = 0
    var contentBottom: CGFloat = 0
    @State private var showingAdd = false
    private enum SourceAction { case files, photos, camera, text }
    @State private var pendingAction: SourceAction?
    @State private var showingFiles = false
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingText = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: AIMProjectDocument?
    @State private var deleting: AIMProjectDocument?
    @State private var renaming: AIMProjectDocument?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var importing = false
    @State private var error: String?
    private var sources: [AIMProjectDocument] { library.files(for: projectID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sources.isEmpty {
                    empty
                } else {
                    HStack {
                        Text(sources.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        addButton
                    }.padding(.horizontal, 22).padding(.top, 16)
                    LazyVStack(spacing: 0) {
                        ForEach(sources) { source in
                            sourceRow(source)
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                if importing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("project.sources.importing").font(.footnote)
                        Spacer()
                        Button("common.cancel", action: cancelImport).font(.footnote.weight(.medium))
                    }.padding(.horizontal, 22).accessibilityIdentifier("project-source-importing")
                }
                if let error = error ?? library.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 22) }
                Text("project.sources.usage_notice").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 24)
            }.padding(.top, contentTop).padding(.bottom, contentBottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityElement(children: .contain).accessibilityIdentifier("project-sources")
        .sheet(isPresented: $showingAdd, onDismiss: openPendingSource) {
            AIMProjectAddSourceSheet(files: { pendingAction = .files; showingAdd = false },
                photos: { pendingAction = .photos; showingAdd = false },
                camera: { pendingAction = .camera; showingAdd = false },
                text: { pendingAction = .text; showingAdd = false })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.data]) { result in
            switch result {
            case let .success(url): importURL(url)
            case let .failure(failure):
                if (failure as NSError).code != NSUserCancelledError { error = String(localized: "project.sources.import_error") }
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, selection in if let selection { importPhoto(selection) } }
        .sheet(isPresented: $showingCamera) {
            AIMProjectCameraCapture(captured: { bytes in
                showingCamera = false; importCamera(bytes)
            }, cancelled: { showingCamera = false }, failed: {
                showingCamera = false; error = String(localized: "project.sources.camera_unavailable")
            }).ignoresSafeArea()
        }
        .sheet(isPresented: $showingText) {
            AIMProjectTextSourceEditor { name, text in
                let saved = await library.addPrepared(.init(name: name + ".txt", mimeType: "text/plain", source: Data(text.utf8), text: text), projectID: projectID)
                if saved { error = nil }
                return saved
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: $preview) { source in
            AIMProjectSourcePreview(source: source, library: library).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(item: $renaming) { source in
            AIMProjectSourceNameEditor(name: source.name) { title in
                await library.rename(source.id, projectID: projectID, name: title)
            }.presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .alert("projects.detail.delete_file_confirm", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("common.delete", role: .destructive) { if let deleting { library.delete(deleting.id) }; deleting = nil }
            Button("common.cancel", role: .cancel) { deleting = nil }
        }
        .onDisappear { cancelImport(); photo = nil }
    }
    private var addButton: some View {
        Button { showingAdd = true } label: {
            Label("project.sources.add", systemImage: "plus").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 22).frame(minHeight: 46)
                .foregroundStyle(Color(uiColor: .systemBackground)).background(Color.primary, in: Capsule())
        }.disabled(importing).accessibilityIdentifier("project-document-add")
    }
    private var empty: some View {
        VStack(spacing: 18) {
            AIMProjectSourceIllustration().padding(.bottom, 7)
            Text("project.sources.context_title").font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("project-sources-empty")
            Text("project.sources.context_body").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            addButton.padding(.top, 6)
        }.padding(.horizontal, 36).padding(.top, 64).padding(.bottom, 20).frame(maxWidth: .infinity)
    }
    private func sourceRow(_ source: AIMProjectDocument) -> some View {
        HStack(spacing: 0) {
            Button { preview = source } label: {
                HStack(spacing: 14) {
                    Image(systemName: source.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                        .font(.system(size: 23, weight: .light)).frame(width: 32, height: 40).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(source.sourceBytes), countStyle: .file))
                            if !source.useInChat { Text("project.sources.excluded").foregroundStyle(.orange) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 24).padding(.vertical, 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(source.name)
            .accessibilityValue(Text(source.useInChat ? "project.sources.available" : "project.sources.excluded"))
            .accessibilityIdentifier("project-source-\(source.id)")
            Menu {
                Button { preview = source } label: { Label("project.sources.preview", systemImage: "doc.text.magnifyingglass") }
                Button { renaming = source } label: { Label("project.sources.rename", systemImage: "pencil") }
                    .accessibilityIdentifier("project-source-rename-\(source.id)")
                Button {
                    library.setUse(source.id, enabled: !source.useInChat)
                } label: {
                    Label(source.useInChat ? "project.sources.exclude" : "project.sources.use", systemImage: source.useInChat ? "minus.circle" : "checkmark.circle")
                }
                Button(role: .destructive) { deleting = source } label: { Label("common.delete", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel(Text("project.sources.actions")).accessibilityIdentifier("project-source-actions-\(source.id)")
        }.padding(.trailing, 10)
    }
    private func openPendingSource() {
        let action = pendingAction; pendingAction = nil
        switch action {
        case .files: showingFiles = true
        case .photos: showingPhotos = true
        case .camera: showingCamera = true
        case .text: showingText = true
        case nil: break
        }
    }
    private func importURL(_ url: URL) {
        beginImport { try await Self.prepare(url) }
    }
    private func importPhoto(_ selection: PhotosPickerItem) {
        beginImport {
            guard let picked = try await selection.loadTransferable(type: AIMProjectPickedPhoto.self) else { throw AIMProjectDocumentImportError.unsupported }
            return picked.document
        }
    }
    private func importCamera(_ bytes: Data) {
        beginImport {
            let worker = Task.detached(priority: .userInitiated) {
                let directory = FileManager.default.temporaryDirectory.appending(path: "aim-project-camera-\(UUID())", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appending(path: "Photo.jpg")
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
                return try AIMPreparedProjectDocument.read(url)
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
    private func beginImport(_ operation: @escaping @Sendable () async throws -> AIMPreparedProjectDocument) {
        cancelImport(); importing = true; error = nil
        let token = generation
        task = Task { @MainActor in
            do {
                let document = try await operation()
                guard !Task.isCancelled, token == generation else { return }
                let saved = await library.addPrepared(document, projectID: projectID)
                guard !Task.isCancelled, token == generation else { return }
                if !saved { error = library.error ?? String(localized: "project.sources.import_error") }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { importing = false; photo = nil }
        }
    }
    private func cancelImport() { generation = UUID(); task?.cancel(); task = nil; importing = false }
    private nonisolated static func prepare(_ url: URL) async throws -> AIMPreparedProjectDocument {
        let worker = Task.detached(priority: .userInitiated) { try AIMPreparedProjectDocument.read(url) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private struct AIMProjectPickedPhoto: Transferable {
    let document: AIMPreparedProjectDocument
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let worker = Task.detached(priority: .userInitiated) { try AIMPreparedProjectDocument.read(received.file) }
            let document = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            return Self(document: document)
        }
    }
}

private struct AIMProjectSourceIllustration: View {
    var body: some View {
        ZStack {
            paper("doc.text", rotation: -16).offset(x: -34, y: 6)
            paper("photo", rotation: 12).offset(x: 34, y: 0)
            paper("text.alignleft", rotation: -2).offset(y: 19)
        }.frame(width: 170, height: 126).accessibilityHidden(true)
    }
    private func paper(_ symbol: String, rotation: Double) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .systemBackground))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.13), lineWidth: 1) }
            .overlay { Image(systemName: symbol).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.secondary) }
            .frame(width: 70, height: 89).rotationEffect(.degrees(rotation))
    }
}
