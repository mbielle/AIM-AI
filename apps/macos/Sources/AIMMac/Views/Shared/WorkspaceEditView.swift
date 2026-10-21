import AIMMacPlatform
import SwiftUI

struct WorkspaceEditTarget: Identifiable {
    let id = UUID()
    let workspace: String
    let path: String
}

struct WorkspaceEditView: View {
    let target: WorkspaceEditTarget
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var service = WorkspaceEditService()
    @State private var old = ""
    @State private var replacement = ""
    @State private var proposal: WorkspaceEditService.Proposal?
    @State private var applied = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review file edit").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
            }
            Text(target.path).font(.caption).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red) }
            if let proposal {
                HStack(alignment: .top, spacing: 20) {
                    textPanel("Before", text: proposal.before)
                    textPanel("After", text: proposal.after)
                }
                Text(applied ? "Saved locally. Undo is available here until this panel closes; it will refuse to overwrite subsequent changes." : "Review both versions. Apply replaces this file only if it still matches the captured version.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if applied {
                        Button("Undo this edit") { perform {
                            try await service.undo(proposal.id)
                            self.proposal = nil; applied = false; onChange()
                        } }
                    } else {
                        Button("Revise") { perform {
                            await service.discard(proposal.id); self.proposal = nil
                        } }
                        Spacer()
                        Button("Apply to file") { perform {
                            try await service.apply(proposal.id)
                            applied = true; onChange()
                        } }.buttonStyle(.settingsPrimary)
                    }
                }.disabled(busy)
            } else {
                Text("Text to replace (exactly one occurrence)").font(.callout)
                TextEditor(text: $old).font(.system(size: 12, design: .monospaced)).frame(minHeight: 110)
                Text("Replacement").font(.callout)
                TextEditor(text: $replacement).font(.system(size: 12, design: .monospaced)).frame(minHeight: 110)
                HStack {
                    Text("Local only · existing UTF-8 files · no upload").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview changes") { perform {
                        proposal = try await service.prepare(workspace: target.workspace, path: target.path, replacing: old, with: replacement)
                    } }.disabled(old.isEmpty || busy)
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(24).frame(width: 760, height: 580)
        .interactiveDismissDisabled(busy)
    }

    private func textPanel(_ title: String, text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
