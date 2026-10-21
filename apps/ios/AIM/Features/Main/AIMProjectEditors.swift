import SwiftUI

struct AIMProjectNameEditor: View {
    let creating: Bool
    let save: (String, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var projectOnly: Bool
    @State private var error = false
    @FocusState private var nameFocused: Bool
    init(name: String, projectOnly: Bool, creating: Bool, save: @escaping (String, Bool) -> Bool) {
        self.creating = creating; self.save = save
        _name = State(initialValue: name); _projectOnly = State(initialValue: projectOnly)
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TextField("Project name", text: $name).font(.title2.weight(.medium)).focused($nameFocused)
                        .padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("project-name-editor")
                    VStack(alignment: .leading, spacing: 14) {
                        Text("project.editor.memory").font(.headline)
                        memoryOption(projectOnly: false, title: "project.editor.memory_default", body: "project.editor.memory_default_body")
                        memoryOption(projectOnly: true, title: "project.editor.memory_project", body: "project.editor.memory_project_body")
                    }
                    if error { Text("project.editor.save_error").font(.footnote).foregroundStyle(.red) }
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(creating ? "New project" : "project.home.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if save(name.trimmingCharacters(in: .whitespacesAndNewlines), projectOnly) { dismiss() } else { error = true }
                    }.disabled(!valid).accessibilityIdentifier("project-name-save")
                }
            }
        }.foregroundStyle(.primary).tint(.primary)
        .task { if creating { nameFocused = true } }
    }
    private func memoryOption(projectOnly value: Bool, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        Button { projectOnly = value } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: projectOnly == value ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityAddTraits(projectOnly == value ? [.isSelected] : [])
        .accessibilityIdentifier(value ? "project-memory-project-only" : "project-memory-default")
    }
}

struct AIMProjectInstructionsEditor: View {
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var instructions: String
    @State private var error = false
    init(instructions: String, save: @escaping (String) -> Bool) {
        self.save = save; _instructions = State(initialValue: instructions)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("project.editor.instructions_body").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $instructions).frame(minHeight: 280).padding(12).scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("project-instructions-editor")
                    Text("\(instructions.count.formatted()) / 16,000").font(.caption).foregroundStyle(instructions.count > 16_000 ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if error { Text("project.editor.save_error").font(.footnote).foregroundStyle(.red) }
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text("project.home.instructions")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save(instructions) { dismiss() } else { error = true } }.disabled(instructions.count > 16_000).accessibilityIdentifier("project-instructions-save")
                }
            }
        }.foregroundStyle(.primary).tint(.primary)
    }
}
