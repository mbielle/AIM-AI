import AIMCore
import PhotosUI
import SwiftUI

/// Selecting a catalog model only opens this editor; Create is the billable action.
struct AIMMediaCreatorView: View {
    @Bindable var store: AIMMediaStore
    let model: MediaModel
    let conversationID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var options = MediaOptions()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var jobID: UUID?
    @State private var referenceError: String?
    @State private var referenceTask: Task<Void, Never>?
    private var currentModel: MediaModel { store.availableModel(id: model.id, route: model.route, kind: model.kind) ?? model }
    private var job: MediaJob? { store.jobs.first { $0.id == jobID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(model.kind == .image ? "Create an image" : "Create a video").font(.title2.bold())
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).aimGlassCircle() }.buttonStyle(.plain).accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentModel.name).font(.headline)
                    Text("This iPhone · \(currentModel.route.title)").font(.subheadline).foregroundStyle(.secondary)
                    Text(priceDescription).font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description").font(.headline)
                    TextEditor(text: $prompt).frame(minHeight: 150).padding(8)
                        .scrollContentBackground(.hidden).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.2)))
                        .accessibilityIdentifier("media-prompt")
                }
                if !currentModel.aspectRatios.isEmpty {
                    option("Format", values: currentModel.aspectRatios, selection: $options.aspectRatio)
                }
                if !currentModel.resolutions.isEmpty { option("Resolution", values: currentModel.resolutions, selection: $options.resolution) }
                if !currentModel.durations.isEmpty {
                    Picker("Duration", selection: $options.durationSeconds) {
                        Text("Provider default").tag(nil as Int?)
                        ForEach(currentModel.durations, id: \.self) { Text("\($0) seconds").tag(Optional($0)) }
                    }.tint(.primary)
                }
                if currentModel.supportsAudio {
                    Toggle("Generate audio", isOn: Binding(get: { options.generateAudio ?? true }, set: { options.generateAudio = $0 })).tint(.green)
                }
                if currentModel.acceptsReferences {
                    let referenceLabel = options.references.isEmpty ? "Add reference images" : "\(options.references.count) reference images"
                    PhotosPicker(selection: $photoItems, matching: .images) {
                        Label(referenceLabel, systemImage: "photo.badge.plus")
                            .padding(.horizontal, 16).frame(minHeight: 44)
                    }.buttonStyle(.plain).aimGlassCapsule()
                    if !options.references.isEmpty { Button("Remove references") { photoItems = []; options.references = [] }.tint(.primary) }
                }
                if let referenceError { Text(referenceError).font(.footnote).foregroundStyle(.red) }
                if !store.hasKey(currentModel.route) { Text("Connect \(currentModel.route.title) in Settings → Providers to create with this model.").font(.footnote).foregroundStyle(.secondary) }
                Button {
                    jobID = store.create(model: currentModel, prompt: prompt, options: options, conversationID: conversationID)
                } label: {
                    Text("Create").font(.headline).foregroundStyle(Color(uiColor: .systemBackground)).frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.primary, in: Capsule())
                }.buttonStyle(.plain).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.hasKey(currentModel.route) || isWorking)
                    .accessibilityIdentifier("media-create")
                if let job {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { if isWorking { ProgressView().tint(.primary) }; Text(statusTitle(job)).font(.headline) }
                        if let error = job.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                        if job.canResume { Button("Resume tracking") { store.resume(jobID: job.id) }.buttonStyle(.bordered).tint(.primary) }
                        if isWorking { Button("Stop tracking") { store.cancelTracking(jobID: job.id) }.buttonStyle(.bordered).tint(.primary) }
                        if let asset = store.assets.first(where: { $0.id == job.assetID }) {
                            Text("Saved to Library").font(.footnote).foregroundStyle(.secondary)
                            if let url = store.localURL(asset: asset) { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.tint(.primary) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
                } else if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                let earlier = store.jobs.filter { $0.id != jobID && $0.model.key == currentModel.key && ($0.canResume || $0.status == .uncertain) }
                if !earlier.isEmpty {
                    DisclosureGroup("Earlier creations") {
                        ForEach(earlier) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.prompt).font(.subheadline).lineLimit(2)
                                Text(statusTitle(item)).font(.footnote).foregroundStyle(.secondary)
                                if item.canResume {
                                    Button("Resume tracking") { jobID = item.id; prompt = item.prompt; options = item.options; store.resume(jobID: item.id) }.tint(.primary)
                                } else { Text("Submission outcome unknown. Check the provider dashboard; AIM will not resend it.").font(.footnote).foregroundStyle(.secondary) }
                            }.padding(.vertical, 8)
                        }
                    }.tint(.primary)
                }
            }.padding(16)
        }.background(Color(uiColor: .systemGroupedBackground)).tint(.primary)
            .task { await store.refreshCatalog(); await store.prepare(model: model); await store.synchronize() }
            .onChange(of: photoItems) { _, items in
                referenceTask?.cancel()
                referenceTask = Task {
                    var references: [MediaReference] = []
                    do {
                        for item in items {
                            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                                  let jpeg = image.jpegData(compressionQuality: 0.9) else { throw MediaGenerationError.invalidResponse }
                            references.append(try MediaReference(name: "Reference.jpg", mimeType: "image/jpeg", data: jpeg))
                        }
                        guard !Task.isCancelled else { return }
                        options.references = references; referenceError = nil
                    } catch { referenceError = "A reference image could not be prepared. Choose a smaller image or remove it." }
                }
            }
    }
    private var isWorking: Bool { job.map { [.submitting, .awaiting, .downloading].contains($0.status) } ?? false }
    private var priceDescription: String {
        guard let price = currentModel.priceUSD, let unit = currentModel.priceUnit else { return "Provider price unavailable. The provider bills this creation; no AIM spending limit is added unless you enabled a device budget." }
        return String(format: "$%.4g per %@ · billed by %@", price, unit, currentModel.route.title)
    }
    private func option(_ title: String, values: [String], selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Provider default").tag(nil as String?)
            ForEach(values, id: \.self) { Text($0).tag(Optional($0)) }
        }.tint(.primary)
    }
    private func statusTitle(_ job: MediaJob) -> String {
        switch job.status {
        case .submitting: "Submitting"
        case .awaiting: "Generating"
        case .downloading: "Saving result"
        case .completed: "Creation ready"
        case .paused: "Tracking paused"
        case .uncertain: "Submission needs verification"
        case .failed: "Creation unavailable"
        }
    }
}
