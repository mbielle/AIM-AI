import AIMApplication
import SwiftUI
import UniformTypeIdentifiers

struct ConversationExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var format: ConversationExport.Format = .text
    @State private var includeAttachments = false
    @State private var includeImages = false
    @State private var snapshot: ConversationExport?
    @State private var document: ConversationExportDocument?
    @State private var error: String?
    @State private var preparing = true
    @State private var showSave = false
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export conversation").font(.title2)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(conversation.title).lineLimit(2)
            Text("Saved messages only. Drafts, tool history, project instructions, workspace paths and API keys are not included. Message text may still contain private information: review before sharing.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Format", selection: $format) {
                Text("Plain text (.txt)").tag(ConversationExport.Format.text)
                Text("JSON (.json)").tag(ConversationExport.Format.json)
            }.pickerStyle(.segmented)
            Toggle("Include attached text and PDF text snapshots", isOn: $includeAttachments)
            if format == .json {
                Toggle("Include image bytes in JSON", isOn: $includeImages)
                if includeImages {
                    Text("Images may contain private details. The JSON stores their full original bytes as base64; review before sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Images are excluded from plain-text exports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preparing { ProgressView("Preparing export…") }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                Text(document.map { String(decoding: $0.data.prefix(32_000), as: UTF8.self) } ?? "")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Preview limited to 32 KB. The saved export contains the full snapshot.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save export…") { showSave = true }
                    .disabled(document == nil || preparing).buttonStyle(.settingsPrimary)
            }
        }.padding(24).frame(width: 680, height: 560)
        .task {
            do {
                let loaded = try await model.conversationExport(conversation.id)
                try Task.checkCancellation()
                snapshot = loaded
            }
            catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            prepare()
        }
        .onChange(of: format) { _, _ in prepare() }
        .onChange(of: includeAttachments) { _, _ in prepare() }
        .onChange(of: includeImages) { _, _ in prepare() }
        .onDisappear { preparationTask?.cancel() }
        .fileExporter(isPresented: $showSave, document: document, contentType: format == .json ? .json : .plainText,
                      defaultFilename: "AIM conversation") { result in
            if case .failure = result { error = "The export could not be saved. Choose a writable location and try again." }
        }
    }

    private func prepare() {
        preparationTask?.cancel()
        document = nil
        guard let snapshot else { preparing = false; return }
        preparing = true
        let selectedFormat = format
        let attachments = includeAttachments
        let images = includeImages && selectedFormat == .json
        preparationTask = Task {
            let result = await Task.detached {
                Result { try snapshot.data(format: selectedFormat, includeAttachments: attachments, includeImages: images) }
            }.value
            guard !Task.isCancelled else { return }
            preparing = false
            switch result {
            case .success(let data): document = ConversationExportDocument(data: data); error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

private struct ConversationExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
