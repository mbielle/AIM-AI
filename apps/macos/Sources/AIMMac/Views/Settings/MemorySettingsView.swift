import AIMApplication
import SwiftUI

struct MemorySettingsView: View {
    /// Inside Settings › Personalization (no page title of its own).
    var embedded = false
    @Environment(AppModel.self) private var model
    @State private var editing: MemoryItem?
    @State private var pendingDelete: MemoryItem?
    @State private var duplicateProposal: [UUID]?
    @State private var importing = false

    @ViewBuilder private var memoryContent: some View {
            SettingsGroup {
                SettingsToggleRow("Use saved memories", description: "Relevant entries may be included in later requests to your selected provider.", isOn: Binding(
                    get: { model.settings.memoryEnabled != false },
                    set: { model.setMemoryEnabled($0) }
                ))
                SettingsToggleRow("Remember from conversations", description: "After each answer, a light model of your provider reads the exchange and saves durable facts about you and your work (a small cost on your key). \"Remember that…\" is always saved. Review or delete entries here.", isOn: Binding(
                    get: { model.settings.externalMemoryCaptureEnabled != false },
                    set: { model.setExternalMemoryCaptureEnabled($0) }
                ))
                .disabled(model.settings.memoryEnabled == false)
            }
            if let error = model.memoryError { SettingsNotice(error, tone: .error) }
            if model.account.accessUser != nil {
                SettingsGroup("Earlier memories on this Mac", footer: "Review and select the entries to share with your account. The local originals are preserved.") {
                    SettingsRow("Import earlier memories") { Button("Review…") { importing = true }.buttonStyle(.settings) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Saved memories").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Add a memory…") {
                        editing = MemoryItem(kind: .fact, scope: "global", scopeKey: "self",
                                             subjectKey: "", content: "", status: .verified)
                    }.buttonStyle(.settings)
                }
                SettingsCard {
                    if active.isEmpty {
                        SettingsRow("No saved memories yet", description: "Add one yourself, or say \"remember that…\" in a conversation.")
                    }
                    ForEach(active) { item in memoryRow(item) }
                }
            }
            if !duplicateGroups.isEmpty {
                SettingsGroup("Duplicate proposals", description: "Only identical contents in the same scope and kind are grouped. Original evidence stays in archived entries.") {
                    ForEach(duplicateGroups, id: \.self) { group in
                        SettingsRow("\(group.count) identical memories", description: model.memories.first { $0.id == group.first }?.content) {
                            Button("Review…") { duplicateProposal = group }.buttonStyle(.settings)
                        }
                    }
                }
            }
            if !archived.isEmpty {
                SettingsGroup("Archived") {
                    ForEach(archived) { item in memoryRow(item) }
                }
            }
    }

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 28) { memoryContent }
            } else {
        SettingsPage("Memory", subtitle: model.account.accessUser == nil ? "Saved on this Mac. Relevant entries may be included in requests to your selected provider." : "Shared with your AIM account. Disabling memory keeps the entries and stops their use and capture.") { memoryContent }
            }
        }
        .task { await model.loadMemories() }
        .sheet(item: $editing) { item in MemoryEditor(item: item) }
        .sheet(isPresented: $importing) { LegacyMemoryImportView() }
        .sheet(isPresented: Binding(get: { duplicateProposal != nil }, set: { if !$0 { duplicateProposal = nil } })) {
            if let ids = duplicateProposal {
                DuplicateMemoryReview(items: model.memories.filter { ids.contains($0.id) })
            }
        }
        .confirmationDialog("Delete this memory permanently?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete memory", role: .destructive) {
                if let id = pendingDelete?.id { Task { await model.deleteMemory(id) } }
                pendingDelete = nil
            }
        } message: { Text("This cannot be undone.") }
    }

    private var duplicateGroups: [[UUID]] { HybridMemorySearch.duplicateGroups(model.memories) }
    private var active: [MemoryItem] { model.memories.filter { $0.status != .archived } }
    private var archived: [MemoryItem] { model.memories.filter { $0.status == .archived } }

    private func memoryRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.subjectKey).font(.system(size: 14, weight: .medium))
                    if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(item.content).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let quote = item.evidenceQuote, !quote.isEmpty {
                    Text("From your message: “\(quote)”").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("\(item.scope == "project" ? "Project" : "General") · \(item.status == .provisional ? "AI-extracted · not reviewed" : item.status.rawValue.capitalized)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if item.status == .archived {
                    Button("Restore") { Task { await model.restoreMemory(item) } }
                } else {
                    Button("Edit and verify…") { editing = item }
                    Button(item.isPinned ? "Unpin" : "Pin") { Task { await model.setMemoryPinned(item, !item.isPinned) } }
                    Button("Archive") { Task { await model.archiveMemory(item.id) } }
                }
                Button("Delete…", role: .destructive) { pendingDelete = item }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(item.subjectKey)")
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.vertical, SettingsMetrics.rowVertical)
    }
}

private struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: MemoryItem
    @State private var saving = false
    @State private var error: String?
    @State private var openedRevision: Int?
    @State private var openedOwner: AccountMemoryOwner = .local

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit memory").font(.title2)
            TextField("Subject", text: $item.subjectKey)
            Picker("Kind", selection: $item.kind) {
                ForEach(MemoryKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue.capitalized).tag(kind)
                }
            }
            Picker("Scope", selection: Binding(
                get: { item.scopeKey },
                set: { key in item.scopeKey = key; item.scope = key == "self" ? "global" : "project" }
            )) {
                Text("All conversations").tag("self")
                ForEach(model.projects) { project in Text(project.name).tag(project.id.uuidString) }
            }
            TextEditor(text: $item.content).frame(minHeight: 140).border(.quaternary)
                .accessibilityLabel("Memory content")
            Text("Editing verifies this memory. Keep it factual; do not save passwords or API keys. The selected provider may receive it when relevant.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do { try await model.saveMemory(item, expectedRevision: openedRevision, expectedOwner: openedOwner); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 560, height: 440).onAppear { openedRevision = model.accountMemoryRevision; openedOwner = model.memoryOwner }
    }
}

private struct LegacyMemoryImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var revision: Int?
    @State private var openedOwner: AccountMemoryOwner = .local
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import earlier memories").font(.title2)
            Text("Select the local entries to add to this account. Projects, source references and review states are kept.").foregroundStyle(.secondary)
            List(model.legacyMemoryPreview, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.subjectKey).fontWeight(.medium)
                    Text(item.content).font(.callout).lineLimit(4)
                    Text("\(item.scope) · \(item.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                }.tag(item.id)
            }
            if let error = model.memoryError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Importing…" : "Import \(selection.count) entries") { Task {
                    saving = true; defer { saving = false }
                    if await model.importLegacyMemories(selection, expectedRevision: revision, expectedOwner: openedOwner) { dismiss() }
                } }.disabled(saving || selection.isEmpty)
            }
        }.padding(24).frame(width: 640, height: 520)
        .task { openedOwner = model.memoryOwner; await model.loadMemories(); revision = model.accountMemoryRevision; await model.loadLegacyMemoryPreview() }
    }
}

private struct DuplicateMemoryReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [MemoryItem]
    @State private var keeper: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep one identical memory").font(.title2)
            Text("Choose the source to keep active. Other entries are archived with their evidence and can be restored.").foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack {
                    Button { keeper = item.id } label: { Image(systemName: keeper == item.id ? "largecircle.fill.circle" : "circle") }
                    VStack(alignment: .leading) {
                        Text(item.content)
                        if let quote = item.evidenceQuote { Text(quote).font(.caption).foregroundStyle(.secondary) }
                        Text(item.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Verify selected and archive duplicates") {
                    guard let keeper else { return }
                    Task { await model.consolidateDuplicateMemories(keeping: keeper, archiving: items.map(\.id).filter { $0 != keeper }); dismiss() }
                }.disabled(keeper == nil)
            }
        }.padding(24).frame(width: 620)
    }
}
