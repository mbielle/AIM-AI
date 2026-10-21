import AIMCore
import SwiftUI

struct AIMNativeProjectHomeView<Composer: View>: View {
    let project: NativeChatProject
    let chat: NativeChatStore
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let back: () -> Void
    let openConversation: (UUID) -> Void
    let startChat: () -> Void
    let deleted: () -> Void
    @ViewBuilder let composer: () -> Composer
    @State private var headerHeight: CGFloat = 130
    @State private var tab: ProjectTab = .chats
    @State private var editingProject = false
    @State private var editingInstructions = false
    @State private var confirmingDelete = false

    private enum ProjectTab { case chats, sources }
    private var conversations: [NativeChatConversation] {
        chat.conversations.filter { $0.projectID.flatMap(UUID.init(uuidString:)) == project.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        AIMConversationScaffold(safeTop: safeTop, safeBottom: safeBottom) { bottomOcclusion in
            if tab == .chats {
                chats(top: headerHeight, bottom: bottomOcclusion)
            } else {
                AIMProjectSourcesView(library: chat.projectDocuments, projectID: project.id,
                    contentTop: headerHeight, contentBottom: bottomOcclusion + 16)
            }
        } header: {
            VStack(spacing: 0) { header; tabs }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: AIMProjectHomeHeaderHeight.self, value: proxy.size.height)
                    }
                }
        } composer: {
            composer()
        }
        .onPreferenceChange(AIMProjectHomeHeaderHeight.self) { value in
            if value.isFinite && value > 0 { headerHeight = value }
        }
        .background(Color(uiColor: .systemBackground)).foregroundStyle(.primary).buttonStyle(.plain)
        .onAppear(perform: startChat)
        .accessibilityElement(children: .contain).accessibilityIdentifier("project-home-\(project.id)")
        .sheet(isPresented: $editingProject) {
            AIMProjectNameEditor(name: project.name, projectOnly: project.memoryScope == .projectOnly, creating: false) { name, projectOnly in
                guard var latest = chat.projects.first(where: { $0.id == project.id }) else { return false }
                latest.name = name; latest.memoryScope = projectOnly ? .projectOnly : .default; latest.updatedAt = .now
                return chat.saveProject(latest)
            }.presentationDetents([.large]).presentationDragIndicator(.visible).aimBlocksBackgroundInteractions(true)
        }
        .sheet(isPresented: $editingInstructions) {
            AIMProjectInstructionsEditor(instructions: project.instructions) { instructions in
                guard var latest = chat.projects.first(where: { $0.id == project.id }) else { return false }
                latest.instructions = instructions; latest.updatedAt = .now
                return chat.saveProject(latest)
            }.presentationDetents([.large]).presentationDragIndicator(.visible).aimBlocksBackgroundInteractions(true)
        }
        .alert("project.home.delete_confirm", isPresented: $confirmingDelete) {
            Button("common.delete", role: .destructive) { if chat.deleteProject(project.id) { deleted() } }
            Button("common.cancel", role: .cancel) { }
        } message: { Text("project.home.delete_message") }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44).aimGlassCircle()
            }.accessibilityLabel("Back").accessibilityIdentifier("project-home-back")
            Text(project.name).font(.system(size: 20, weight: .semibold)).lineLimit(1).multilineTextAlignment(.center).frame(maxWidth: .infinity).accessibilityIdentifier("project-home-title")
            Menu {
                Button { chat.togglePinnedProject(project.id) } label: {
                    Label(project.isPinned ? "project.home.unpin" : "project.home.pin", systemImage: project.isPinned ? "pin.slash" : "pin")
                }
                Button { editingProject = true } label: { Label("project.home.edit", systemImage: "pencil") }
                Button { editingInstructions = true } label: { Label("project.home.instructions", systemImage: "text.alignleft") }
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: { Label("common.delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .medium)).frame(width: 44, height: 44).aimGlassCircle()
            }.accessibilityLabel(Text("project.home.actions")).accessibilityIdentifier("project-home-actions")
        }.padding(.horizontal, 10).padding(.top, safeTop + 8).padding(.bottom, 8)
    }
    private var tabs: some View {
        HStack(spacing: 8) {
            tabButton("project.home.chats", selected: .chats, identifier: "project-tab-chats")
            tabButton("project.home.sources", selected: .sources, identifier: "project-tab-sources")
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
    }
    private func tabButton(_ title: LocalizedStringKey, selected: ProjectTab, identifier: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { tab = selected } } label: {
            Text(title).font(.system(size: 17, weight: tab == selected ? .semibold : .medium))
                .foregroundStyle(tab == selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 20).frame(minHeight: 44)
                .background(tab == selected ? Color.primary.opacity(0.05) : Color.clear, in: Capsule())
        }.accessibilityIdentifier(identifier).accessibilityAddTraits(tab == selected ? [.isSelected] : [])
    }
    private func chats(top: CGFloat, bottom: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if conversations.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "folder").font(.system(size: 33, weight: .light)).foregroundStyle(.secondary)
                        Text("project.home.empty_chats_title").font(.title3.weight(.medium))
                            .accessibilityIdentifier("project-chats-empty-title")
                        Text("project.home.empty_chats_body").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("project-chats-empty-body")
                    }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.top, 64).padding(.bottom, 32)
                    // An excluded document is still a source the user has already added.
                    if chat.projectDocuments.files(for: project.id).isEmpty {
                        Button { tab = .sources } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "doc.badge.plus").font(.system(size: 22)).frame(width: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("project.sources.context_title").font(.subheadline.weight(.medium))
                                    Text("project.sources.context_short").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                        }.padding(.horizontal, 20).accessibilityIdentifier("project-chat-add-context")
                    }
                } else {
                    HStack {
                        Text("project.home.chats").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: startChat) { Image(systemName: "square.and.pencil").font(.system(size: 20)).frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("project.home.new_chat")).accessibilityIdentifier("project-new-chat")
                    }.padding(.horizontal, 22).padding(.top, 8)
                    ForEach(conversations) { conversation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conversation.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            if let text = conversation.messages.last(where: { $0.text.contains(where: { !$0.isWhitespace }) })?.text {
                                Text(AIMProjectChatPreview.text(text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 13)
                        .contentShape(Rectangle()).accessibilityElement(children: .combine)
                        .aimSwipeSafeTap { openConversation(conversation.id) }
                        .accessibilityIdentifier("project-chat-\(conversation.id)")
                    }
                }
            }.padding(.top, top).padding(.bottom, bottom + 24)
        }.scrollDismissesKeyboard(.interactively)
    }
}

private enum AIMProjectHomeHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Display-only excerpt: preserve stored messages while keeping paragraphs on one flow.
enum AIMProjectChatPreview {
    static func text(_ source: String) -> String {
        var result = ""
        var pendingSpace = false
        var count = 0
        let renderedText = AIMMarkdownPlainText.string(source)
        for character in renderedText {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" "); count += 1; pendingSpace = false
                if count == 180 { break }
            }
            result.append(character); count += 1
            if count == 180 { break }
        }
        return result
    }

}
