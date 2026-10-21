import AIMCore
import SwiftUI

struct AIMNativeProjectsView: View {
    let chat: NativeChatStore
    let service: any CloudContentServicing
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let openMenu: () -> Void
    @Binding var selectedProjectID: UUID?
    let openConversation: (UUID) -> Void
    let startChat: (UUID) -> Void
    let projectComposer: (NativeChatProject) -> AnyView
    var backFromProject: (() -> Void)? = nil
    @State private var creating = false
    @State private var searching = false
    @State private var query = ""
    @State private var alphabetical = false
    @State private var scrollID: UUID?
    @FocusState private var searchFocus: Bool

    private var projects: [NativeChatProject] {
        chat.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.instructions.localizedCaseInsensitiveContains(query) }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return alphabetical ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.updatedAt > $1.updatedAt
            }
    }
    var body: some View {
        ZStack {
            if let project = chat.projects.first(where: { $0.id == selectedProjectID }) {
                AIMNativeProjectHomeView(project: project, chat: chat, safeTop: safeTop, safeBottom: safeBottom,
                    back: { if let backFromProject { backFromProject() } else { selectedProjectID = nil } }, openConversation: openConversation,
                    startChat: { startChat(project.id) }, deleted: { selectedProjectID = nil },
                    composer: { projectComposer(project) })
                    .id(project.id)
                    .transition(.move(edge: .trailing))
            } else {
                list
            }
        }
        .background(Color(uiColor: .systemBackground)).tint(.primary)
        .sheet(isPresented: $creating) {
            AIMProjectNameEditor(name: "", projectOnly: false, creating: true) { name, projectOnly in
                var project = NativeChatProject(name: name, instructions: "")
                project.memoryScope = projectOnly ? .projectOnly : .default
                guard chat.saveProject(project) else { return false }
                creating = false; selectedProjectID = project.id
                return true
            }
            .presentationDetents([.large]).presentationDragIndicator(.visible).tint(.primary)
            .aimBlocksBackgroundInteractions(true)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("projects-screen")
    }
    private var list: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if projects.isEmpty {
                        ContentUnavailableView("projects.empty.title", systemImage: "folder", description: Text("projects.empty.body")).padding(.top, 44)
                    }
                    ForEach(projects) { project in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "folder").font(.system(size: 21)).foregroundStyle(.secondary)
                                .frame(width: 36, height: 36).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 7) {
                                    Text(project.name).font(.system(size: 18, weight: .medium)).lineLimit(1)
                                    if project.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                                }
                                AIMProjectRelativeDateLabel(date: project.updatedAt).font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("project-updated-\(project.id)")
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.tertiary).padding(.top, 10)
                        }
                        .padding(.vertical, 18).padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle()).accessibilityElement(children: .combine)
                        .aimSwipeSafeTap { selectedProjectID = project.id }.id(project.id)
                        .accessibilityIdentifier("native-project-\(project.id)")
                        Divider().padding(.leading, 74)
                    }
                    if let error = chat.syncMessage { Text(error).font(.footnote).foregroundStyle(.secondary).padding(22) }
                }.scrollTargetLayout().padding(.top, safeTop + 76).padding(.bottom, safeBottom + 100)
            }.scrollPosition(id: $scrollID, anchor: .top).scrollDismissesKeyboard(.interactively)
            VStack {
                HStack {
                    Button(action: openMenu) { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).aimGlassCircle() }.accessibilityLabel(Text("sidebar.open"))
                    Spacer(); Text("Projects").font(.system(size: 22, weight: .semibold)); Spacer()
                    Menu {
                        Button("Recent first") { alphabetical = false }
                        Button("Name") { alphabetical = true }
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).aimGlassCircle() }.accessibilityLabel("Project filters")
                }.padding(.horizontal, 16).padding(.top, safeTop + 10)
                Spacer()
                HStack(spacing: 12) {
                    if searching {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            TextField("Search projects", text: $query).focused($searchFocus).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { query = ""; searching = false; searchFocus = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close search")
                        }.padding(.leading, 16).frame(minHeight: 48).aimGlassCapsule()
                    } else {
                        Button { searching = true; searchFocus = true } label: { Image(systemName: "magnifyingglass").frame(width: 48, height: 48).aimGlassCircle() }.accessibilityLabel("Search projects")
                        Spacer()
                        Button { creating = true } label: {
                            Label("New project", systemImage: "plus").font(.system(size: 17, weight: .medium)).padding(.horizontal, 21).frame(minHeight: 48)
                                .foregroundStyle(Color(uiColor: .systemBackground)).background(Color.primary, in: Capsule())
                        }.accessibilityIdentifier("native-new-project")
                    }
                }.padding(.horizontal, 20).padding(.bottom, safeBottom + 16)
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}
