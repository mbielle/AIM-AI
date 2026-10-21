import AIMApplication
import SwiftUI

struct ProjectHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sortByName = false
    @State private var filesProject: AIMProject?
    @State private var editing = false
    @State private var name = ""
    @State private var instructions = ""
    @State private var editingID: UUID?
    @State private var saving = false
    @State private var usesGlobalMemory = true
    @State private var hoveredConversation: UUID?
    @State private var renameTarget: Conversation?
    @State private var deleteTarget: Conversation?
    @State private var conversationTitle = ""

    private var project: AIMProject? { model.projects.first { $0.id == model.selectedProjectID } }
    private var projects: [AIMProject] {
        model.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { sortByName ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let project { detail(project) } else { overview }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(item: $filesProject) { ProjectFilesView(project: $0) }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 18) {
                Text(editingID == nil ? "New project" : "Project instructions").font(.title2)
                TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                Text("Instructions").font(.headline)
                TextEditor(text: $instructions).frame(height: 180).accessibilityLabel("Project instructions")
                Toggle("Include general AIM memory", isOn: $usesGlobalMemory)
                Text("When off, only memories from this project are recalled. Your global memory setting still applies.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { editing = false }.disabled(saving)
                    Spacer()
                    Button("Save") {
                        saving = true
                        Task {
                            if await model.saveProject(id: editingID, name: name, instructions: instructions, usesGlobalMemory: usesGlobalMemory) { editing = false }
                            saving = false
                        }
                    }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 480).interactiveDismissDisabled()
        }
        .alert("Rename conversation", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $conversationTitle)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let id = renameTarget?.id { Task { await model.renameConversation(id, to: conversationTitle) } }
                renameTarget = nil
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete conversation", role: .destructive) {
                if let id = deleteTarget?.id { Task { await model.deleteConversation(id) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text("Its messages will be removed from this Mac and cannot be recovered.") }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Projects").font(AIMTypography.title(30))
                Spacer()
                Button("New project", systemImage: "plus") { edit(nil) }.buttonStyle(.settingsPrimary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search projects", text: $query).textFieldStyle(.plain)
                Picker("Sort", selection: $sortByName) {
                    Text("Recent activity").tag(false)
                    Text("Name").tag(true)
                }.labelsHidden().frame(width: 160)
            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18)], spacing: 18) {
                ForEach(projects) { project in
                    Button { Task { await model.openProjects(project.id) } } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                            Text(project.name).font(.title3.weight(.semibold)).lineLimit(2)
                            Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 20))
                            .contentShape(RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                }
            }
            if projects.isEmpty { ContentUnavailableView("No projects", systemImage: "folder", description: Text("Create a project to group conversations, instructions and sources.")) }
        }
    }
    private func detail(_ project: AIMProject) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Text(project.name).font(AIMTypography.title(30))
                Spacer()
                Button("Edit", systemImage: "pencil") { edit(project) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    conversationSection(project).frame(minWidth: 330)
                    contextSection(project).frame(width: 280)
                }
                VStack(alignment: .leading, spacing: 24) {
                    conversationSection(project)
                    contextSection(project)
                }
            }
        }
    }
    private func conversationSection(_ project: AIMProject) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            AIMComposer(placeholder: "How can I help with this project?")
            Text("Recent conversations").font(.headline)
            let conversations = model.conversations.filter { $0.projectID == project.id && ($0.mode == .code) == (model.mode == .code) }
            if conversations.isEmpty { Text("No conversations yet").foregroundStyle(.secondary) }
            if conversations.contains(where: { $0.pinnedAt != nil }) {
                Label("Pinned", systemImage: "pin").font(.subheadline).foregroundStyle(.secondary)
                ForEach(conversations.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }) { conversation in
                    projectConversationRow(conversation)
                }
            }
            ForEach(conversations.filter { $0.pinnedAt == nil }) { conversation in
                projectConversationRow(conversation)
            }
        }
    }

    private func projectConversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            Button { Task { await model.selectConversation(conversation.id) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: conversation.mode == .agent ? "sparkles" : conversation.mode == .code ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                    Text(conversation.title).lineLimit(1)
                    Spacer()
                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if hoveredConversation == conversation.id {
                Menu { projectConversationActions(conversation) } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }.menuStyle(.borderlessButton).fixedSize().aimTooltip("Conversation options")
            }
        }
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(hoveredConversation == conversation.id ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hoveredConversation = $0 ? conversation.id : nil }
        .contextMenu { projectConversationActions(conversation) }
    }

    @ViewBuilder private func projectConversationActions(_ conversation: Conversation) -> some View {
        Button("Rename…") { conversationTitle = conversation.title; renameTarget = conversation }
        Button(conversation.pinnedAt == nil ? "Pin" : "Unpin") { Task { await model.setPinned(conversation.id, conversation.pinnedAt == nil) } }
        Menu("Move to project") {
            Button("No project") { Task { await model.moveConversation(conversation.id, toProject: nil) } }
            ForEach(model.projects.filter { $0.id != conversation.projectID }) { project in
                Button(project.name) { Task { await model.moveConversation(conversation.id, toProject: project.id) } }
            }
        }
        Button("Archive") { Task { await model.setArchived(conversation.id, true) } }
        Divider()
        Button("Delete…", role: .destructive) { deleteTarget = conversation }
    }
    private func contextSection(_ project: AIMProject) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Instructions", systemImage: "doc.text").font(.headline)
                Spacer()
                Button { edit(project) } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
            }
            Text(project.instructions.isEmpty ? "Add instructions to guide AIM in this project." : project.instructions)
                .font(.callout).foregroundStyle(.secondary).lineLimit(8)
            Divider()
            Label("Memory", systemImage: "brain").font(.headline)
            Text(project.usesGlobalMemory == false ? "Project memories only" : "General and project memories").font(.callout).foregroundStyle(.secondary)
            Button("Change memory settings…") { edit(project) }
            Divider()
            Label("Sources", systemImage: "folder").font(.headline)
            Text("Link folders for read-only context, then explicitly allow Code access to any folder you want AIM to edit.").font(.callout).foregroundStyle(.secondary)
            Button("Manage sources…") { filesProject = project }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 20))
    }
    private func edit(_ project: AIMProject?) {
        editingID = project?.id; name = project?.name ?? ""; instructions = project?.instructions ?? ""
        usesGlobalMemory = project?.usesGlobalMemory != false
        editing = true
    }
}
