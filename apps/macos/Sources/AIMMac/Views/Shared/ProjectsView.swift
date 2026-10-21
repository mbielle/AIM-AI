import AIMApplication
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectDraft()
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var status: String?
    @State private var pendingNavigation: Navigation?
    @State private var confirmingDiscard = false
    @State private var filesProject: AIMProject?
    private enum Navigation { case select(AIMProject?), close }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Projects").font(.title2)
                Spacer()
                Button("New project") { navigate(.select(nil)) }.disabled(busy)
                Button("Done") { navigate(.close) }.disabled(busy)
            }
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.projects) { project in
                            Button { navigate(.select(project)) } label: {
                                Label(project.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(draft.projectID == project.id ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if model.projects.isEmpty { Text("No projects yet").foregroundStyle(.secondary) }
                    }
                }.frame(width: 190).disabled(busy)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Project name", text: $draft.name)
                        .textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                    HStack {
                        Text("Instructions").font(.headline)
                        Spacer()
                        Text("\(draft.instructions.count) / 16,000").font(.caption)
                            .foregroundStyle(draft.instructions.count > 16_000 ? .red : .secondary)
                    }
                    TextEditor(text: $draft.instructions).font(.system(size: 13)).scrollContentBackground(.hidden)
                        .padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9)).frame(minHeight: 180)
                        .accessibilityLabel("Project instructions")
                    Text("Stored on this Mac. Instructions and imported text files are sent to the selected AI provider with every message in the project. Do not include secrets. Cloud project sync is not connected yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.caption) }
                    HStack {
                        if draft.projectID != nil {
                            Button("Files…") { filesProject = model.projects.first { $0.id == draft.projectID } }
                            Button("Delete project", role: .destructive) { confirmingDelete = true }
                        }
                        Spacer()
                        if draft.isDirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                        Button("Save") {
                            busy = true
                            Task {
                                let saved = await model.saveProject(id: draft.projectID, name: draft.name, instructions: draft.instructions)
                                busy = false
                                if saved { edit(nil); status = "Project saved." }
                                else { status = "Could not save. Check the name and instruction length, then retry." }
                            }
                        }.disabled(!draft.isValid || !draft.isDirty)
                    }
                }.disabled(busy || model.isSending)
            }
        }.padding(24).frame(width: 740, height: 470)
        .task { await model.loadProjects() }
        .interactiveDismissDisabled(busy || draft.isDirty)
        .sheet(item: $filesProject) { ProjectFilesView(project: $0) }
        .confirmationDialog("Discard unsaved project changes?", isPresented: $confirmingDiscard) {
            Button("Keep editing", role: .cancel) { pendingNavigation = nil }
            Button("Discard changes", role: .destructive) {
                if let navigation = pendingNavigation { perform(navigation) }
                pendingNavigation = nil
            }
        }
        .confirmationDialog("Delete this project? Conversations are kept and removed from the project.", isPresented: $confirmingDelete) {
            Button("Delete project", role: .destructive) {
                guard let id = draft.projectID else { return }
                busy = true
                Task { let deleted = await model.deleteProject(id); busy = false; if deleted { edit(nil) } }
            }
        }
    }

    private func edit(_ project: AIMProject?) {
        draft = ProjectDraft(project: project); status = nil
    }

    private func navigate(_ navigation: Navigation) {
        if draft.isDirty { pendingNavigation = navigation; confirmingDiscard = true }
        else { perform(navigation) }
    }

    private func perform(_ navigation: Navigation) {
        switch navigation {
        case let .select(project): edit(project)
        case .close: dismiss()
        }
    }
}
