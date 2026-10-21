import AIMCore
import SwiftUI
import UIKit

struct AIMAccountActivityImportView: View {
    let chat: NativeChatStore
    @State private var preview: [AccountActivityImportItem] = []
    @State private var selected: Set<UUID> = []
    @State private var message: String?
    @State private var importing = false
    private var candidates: [AccountActivityImportItem] {
        AccountActivityImportItem.preview(conversations: chat.conversations, existing: chat.activityRecords,
            accountID: chat.accountID, deviceID: chat.deviceID, deviceName: UIDevice.current.name)
    }
    var body: some View {
        AIMSettingsForm {
            Section {
                Text("Choose the earlier responses to attach to this AIM account. Original conversations are kept.").font(.footnote).foregroundStyle(.secondary)
                Text("Older responses may not identify their device, model or full task duration. Missing measurements stay unavailable.").font(.footnote).foregroundStyle(.secondary)
                Button("Refresh preview") { preview = candidates; selected = []; message = nil }.foregroundStyle(.primary)
            }
            Section("Preview · \(preview.count) responses") {
                if preview.isEmpty { Text("No earlier activity to import").foregroundStyle(.secondary) }
                ForEach(preview) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in if value { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline)
                            Text("\(item.record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.record.totalTokens?.formatted() ?? "—") tokens").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(.green).disabled(importing)
                }
            }
            Section {
                Button(importing ? "Importing…" : "Import \(selected.count) selected responses") { Task { await runImport() } }
                    .foregroundStyle(.primary).disabled(selected.isEmpty || importing)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }.onAppear { preview = candidates }
    }
    private func runImport() async {
        importing = true; defer { importing = false }
        do {
            let rows = try AccountActivityImportItem.selected(selected, from: preview, current: candidates, accountID: chat.accountID)
            if await chat.importActivity(rows) { message = "Activity imported. Original conversations were kept."; preview = candidates; selected = [] }
            else { message = chat.accountDataError ?? "The import could not sync. Local records were kept." }
        } catch { message = "Earlier activity changed. Refresh the preview before importing." }
    }
}
