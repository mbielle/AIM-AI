import AIMCore
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AIMProjectAddSourceSheet: View {
    let files: () -> Void
    let photos: () -> Void
    let camera: () -> Void
    let text: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera) && ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    option("project.sources.photos", icon: "photo.on.rectangle", id: "project-source-photos", action: photos)
                    option("project.sources.camera", icon: "camera", id: "project-source-camera", detail: cameraAvailable ? nil : "project.sources.camera_unavailable", enabled: cameraAvailable, action: camera)
                    option("project.sources.files", icon: "folder", id: "project-source-files", action: files)
                    option("project.sources.text", icon: "text.alignleft", id: "project-source-text", action: text)
                    Divider().padding(.horizontal, 22).padding(.vertical, 9)
                    option("Google Drive", icon: "externaldrive", id: "project-source-drive", detail: "project.sources.drive_files", action: files)
                    option("Slack", icon: "bubble.left.and.bubble.right", id: "project-source-slack", detail: "project.sources.slack_unavailable", enabled: false, action: {})
                }.padding(.vertical, 8)
            }
            .navigationTitle(Text("project.sources.add_title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } } }
        }.foregroundStyle(.primary).tint(.primary)
    }
    private func option(_ title: LocalizedStringKey, icon: String, id: String, detail: LocalizedStringKey? = nil, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 17) {
                Image(systemName: icon).font(.system(size: 22, weight: .regular)).frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .medium))
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if enabled { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 24).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.48).accessibilityIdentifier(id)
    }
}

struct AIMProjectSourceNameEditor: View {
    let save: @MainActor (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    init(name: String, save: @escaping @MainActor (String) async -> Bool) {
        _name = State(initialValue: name); self.save = save
    }
    private var title: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !title.isEmpty && title.count <= 255 && title.utf8.count <= 1_024 && !title.contains("/") && !title.contains("\\")
            && title.rangeOfCharacter(from: .controlCharacters) == nil
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("project.sources.source_name", text: $name).textInputAutocapitalization(.none).autocorrectionDisabled()
                    .font(.title3.weight(.medium)).padding(16).disabled(saving)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("project-source-rename-name")
                Text("project.sources.rename_notice").font(.footnote).foregroundStyle(.secondary)
                if !valid { Text("project.sources.rename_invalid").font(.footnote).foregroundStyle(.red) }
                if saving { ProgressView() }
                if failed { Text("project.sources.rename_error").font(.footnote).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }.padding(22)
            .navigationTitle(Text("project.sources.rename")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: rename).disabled(!valid || saving).accessibilityIdentifier("project-source-rename-save")
                }
            }
        }.foregroundStyle(.primary).tint(.primary)
        .interactiveDismissDisabled(saving)
        .onDisappear(perform: cancel)
    }
    private func rename() {
        guard valid, !saving else { return }
        let value = title, token = generation
        saving = true; failed = false
        task = Task { @MainActor in
            let saved = await save(value)
            guard !Task.isCancelled, token == generation else { return }
            saving = false
            if saved { dismiss() } else { failed = true }
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; saving = false }
}

struct AIMProjectTextSourceEditor: View {
    let save: @MainActor (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var error = false
    @State private var rejectedText = false
    @State private var saving = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    private var valid: Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 240 && !title.contains("/") && !title.contains("\\") && !title.contains("\0")
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0") && text.utf8.count <= ProjectSourceStore.maximumTextBytes
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("project.sources.text_title", text: $name).font(.title3.weight(.medium)).padding(16).disabled(saving)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("project-text-source-name")
                    AIMProjectBoundedTextEditor(text: $text, rejected: { rejectedText = true }, accepted: { rejectedText = false })
                        .frame(height: 300).padding(8).disabled(saving)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("project-text-source-content")
                    Text("project.sources.text_notice").font(.footnote).foregroundStyle(.secondary)
                    if rejectedText { Text("project.sources.text_limit").font(.footnote).foregroundStyle(.red) }
                    if saving { ProgressView("project.sources.importing") }
                    if error { Text("project.sources.import_error").font(.footnote).foregroundStyle(.red) }
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text("project.sources.text")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("project.sources.add", action: add).disabled(!valid || saving).accessibilityIdentifier("project-text-source-add")
                }
            }
        }.foregroundStyle(.primary).tint(.primary)
        .interactiveDismissDisabled(saving)
        .onDisappear(perform: cancel)
    }
    private func add() {
        guard valid, !saving else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines), content = text, token = generation
        saving = true; error = false
        task = Task { @MainActor in
            let saved = await save(title, content)
            guard !Task.isCancelled, token == generation else { return }
            saving = false
            if saved { dismiss() } else { error = true }
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; saving = false }
}

/// Reject oversized paste before UIKit replaces the retained editor text; never silently truncate.
private struct AIMProjectBoundedTextEditor: UIViewRepresentable {
    @Binding var text: String
    let rejected: () -> Void
    let accepted: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear; view.textColor = .label
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 5, bottom: 10, right: 5)
        view.keyboardDismissMode = .interactive; view.delegate = context.coordinator
        view.accessibilityIdentifier = "project-text-source-content"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        if view.text != text { view.text = text }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AIMProjectBoundedTextEditor
        init(parent: AIMProjectBoundedTextEditor) { self.parent = parent }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let current = view.text ?? ""
            guard let removed = Range(range, in: current), !replacement.contains("\0"),
                  current.utf8.count - current[removed].utf8.count + replacement.utf8.count <= ProjectSourceStore.maximumTextBytes else {
                parent.rejected(); return false
            }
            return true
        }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; parent.accepted() }
    }
}

struct AIMProjectSourcePreview: View {
    let source: AIMProjectDocument
    let library: AIMProjectDocumentLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showingExcerpt = false
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16)) }
                    Text(source.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Label(source.useInChat ? "project.sources.available" : "project.sources.excluded", systemImage: source.useInChat ? "checkmark.circle" : "minus.circle").font(.footnote).foregroundStyle(.secondary)
                    if !source.hasOriginal { Text("project.sources.text_only").font(.footnote).foregroundStyle(.secondary) }
                    Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if showingExcerpt { Text("project.sources.preview_excerpt").font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }.padding(22)
            }
            .navigationTitle(Text("project.sources.preview")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.close") { dismiss() }.accessibilityIdentifier("project-source-preview-close") } }
        }.foregroundStyle(.primary).tint(.primary)
        .task {
            do {
                guard let store = library.sourceStore else { throw ProjectSourceError.unreadable }
                let id = source.id, includeImage = source.hasOriginal && source.mimeType.hasPrefix("image/")
                let worker = Task.detached(priority: .userInitiated) { () throws -> AIMProjectSourcePreviewContent in
                    try Task.checkCancellation()
                    let complete = try store.readText(id)
                    var thumbnail: Data?
                    if includeImage {
                        let bytes = try store.readOriginal(id)
                        try Task.checkCancellation()
                        if let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
                           let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                             kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                            let output = NSMutableData()
                            if let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) {
                                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                                if CGImageDestinationFinalize(destination) { thumbnail = output as Data }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    return .init(text: String(complete.prefix(40_000)), showingExcerpt: complete.count > 40_000, thumbnail: thumbnail)
                }
                let content = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                text = content.text; showingExcerpt = content.showingExcerpt
                if let bytes = content.thumbnail { image = UIImage(data: bytes) }
            } catch is CancellationError { }
            catch { self.error = String(localized: "project.sources.preview_error") }
        }
    }
}

private struct AIMProjectSourcePreviewContent: Sendable {
    let text: String
    let showingExcerpt: Bool
    let thumbnail: Data?
}

struct AIMProjectCameraCapture: UIViewControllerRepresentable {
    let captured: (Data) -> Void
    let cancelled: () -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(captured: captured, cancelled: cancelled, failed: failed) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera; picker.mediaTypes = [UTType.image.identifier]; picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let captured: (Data) -> Void
        let cancelled: () -> Void
        let failed: () -> Void
        init(captured: @escaping (Data) -> Void, cancelled: @escaping () -> Void, failed: @escaping () -> Void) {
            self.captured = captured; self.cancelled = cancelled; self.failed = failed
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { cancelled() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let bytes = image.jpegData(compressionQuality: 0.95) else { failed(); return }
            captured(bytes)
        }
    }
}
