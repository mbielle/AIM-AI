import AIMCore
import SwiftUI

struct AIMAgentLogo: View {
    let id: String
    var body: some View {
        Group {
            if let image = AIMLogoImageCache.shared.image(asset: id == "hermes" ? "hermesagent" : id == "openclaw" ? "openclaw" : "aim-logo") {
                Image(uiImage: image).resizable().scaledToFit()
            } else { Image(systemName: "sparkles") }
        }.frame(width: 28, height: 28).accessibilityHidden(true)
    }
}

/// The paired Mac owns the operation; browsing never changes the execution target.
struct AIMRemoteDownloadsView: View {
    let store: MainExperienceStore
    let machineID: String
    let machineName: String
    var agent: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var format = "gguf"
    @State private var models: [String] = []
    @State private var detail: RemoteJSONValue?
    @State private var proposal: [String: RemoteJSONValue]?
    @State private var jobs: RemoteJSONValue?
    @State private var error: String?
    @State private var busy = false
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(machineName, systemImage: "desktopcomputer")
                    Text("Downloads stay on this Mac. Agent installation does not start a task or grant permissions.").font(.footnote).foregroundStyle(.secondary)
                }
                if let agent {
                    Section {
                        HStack { AIMAgentLogo(id: agent); Text(agent == "hermes" ? "Hermes Agent" : "OpenClaw") }
                        Text("This installs the verified version and its isolated runtime on the selected Mac. OpenRouter is required to use this agent.").font(.footnote)
                        Button("Install on this Mac") {
                            proposal = ["operation": .string("agent"), "agent": .string(agent)]; confirming = true
                        }.disabled(busy)
                    }
                } else {
                    Section("Local models") {
                        Picker("Format", selection: $format) { Text("GGUF").tag("gguf"); Text("MLX").tag("mlx") }.pickerStyle(.segmented).disabled(busy).onChange(of: format) { _, _ in detail = nil; models = [] }
                        HStack {
                            TextField("Search Hugging Face", text: $query).submitLabel(.search).onSubmit { search() }
                            Button { search() } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.disabled(busy)
                        }
                        ForEach(models, id: \.self) { repo in
                            Button(repo) { run { detail = try await store.remoteDownload(["operation": .string("detail"), "repo": .string(repo), "format": .string(format)], machineID: machineID) } }
                        }
                    }
                    if let object = detail?.objectValue, let repo = object["repo"]?.stringValue, let revision = object["revision"]?.stringValue {
                        Section(repo) {
                            if object["gated"] == .bool(true) { Text("This repository requires authorization on the Mac.").foregroundStyle(.secondary) }
                            ForEach(Array((object["variants"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, value in
                                if let row = value.objectValue, let name = row["name"]?.stringValue, let bytes = row["bytes"]?.numberValue {
                                    Button {
                                        proposal = ["operation": .string("model"), "repo": .string(repo), "revision": .string(revision), "format": .string(format), "variant": .string(name), "bytes": .number(bytes)]
                                        confirming = true
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(name)
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " · " + (row["fit"]?.stringValue ?? "Unknown memory requirement")).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.disabled(busy || bytes <= 0 || object["gated"] == .bool(true))
                                }
                            }
                            Text("Downloading does not load the model. Activate the compatible local runtime on the Mac when ready.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let rows = jobs?.objectValue?["jobs"]?.objectValue {
                    Section("Downloads on this Mac") {
                        ForEach(rows.keys.sorted(), id: \.self) { key in
                            let row = rows[key]?.objectValue ?? [:]
                            VStack(alignment: .leading, spacing: 8) {
                                Text(key).font(.subheadline).lineLimit(2)
                                Text(row["message"]?.stringValue ?? "").font(.caption)
                                if row["state"]?.stringValue == "running" {
                                    ProgressView(value: row["progress"]?.numberValue ?? 0)
                                    Button("Cancel download") { run { jobs = try await store.remoteDownload(["operation": .string("cancel"), "key": .string(key)], mutate: true, machineID: machineID) } }
                                }
                            }
                        }
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .tint(.primary)
            .navigationTitle(agent == nil ? "Download a model" : "Install agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Download on \(machineName)?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { proposal = nil }
                Button("Download") { if let proposal { run { jobs = try await store.remoteDownload(proposal, mutate: true, machineID: machineID) } } }
            } message: {
                if let proposal, let repo = proposal["repo"]?.stringValue, let bytes = proposal["bytes"]?.numberValue {
                    Text(repo + " · " + (proposal["variant"]?.stringValue ?? "") + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "\n" + machineName + "\nNo model request will be sent.")
                } else { Text("The selected agent and dependencies will be downloaded on " + machineName + ". No task will be started.") }
            }
            .task {
                repeat {
                    do { jobs = try await store.remoteDownload(["operation": .string("status")], machineID: machineID) }
                    catch { self.error = error.localizedDescription; return }
                    try? await Task.sleep(for: .seconds(3))
                } while !Task.isCancelled
            }
        }.aimUniversalPanelSurface()
    }
    private func search() {
        detail = nil
        run {
            let result = try await store.remoteDownload(["operation": .string("search"), "query": .string(query), "format": .string(format)], machineID: machineID)
            models = (result.objectValue?["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}
