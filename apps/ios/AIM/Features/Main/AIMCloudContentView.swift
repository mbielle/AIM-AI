import AIMCore
import ImageIO
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
private final class AIMCloudContentStore {
    var projects: [AIMProject] = []
    var media: [AIMMediaItem] = []
    var mediaKind: AIMMediaKind = .image
    var isLoading = false
    var error: String?

    private let service: any CloudContentServicing
    init(service: any CloudContentServicing) { self.service = service }
    fileprivate var serviceForChildren: any CloudContentServicing { service }

    func loadProjects() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { projects = try await service.loadProjects() }
        catch { self.error = String(localized: "cloud.error.load") }
    }

    func createProject(name: String, description: String?, instructions: String?) async -> Bool {
        do {
            let project = try await service.createProject(name: name, description: description, customContext: instructions)
            projects.insert(project, at: 0)
            return true
        } catch {
            self.error = String(localized: "cloud.error.save")
            return false
        }
    }

    func archive(_ project: AIMProject) async {
        do {
            try await service.archiveProject(id: project.id)
            projects.removeAll { $0.id == project.id }
        } catch { self.error = String(localized: "cloud.error.save") }
    }

    func rename(_ project: AIMProject, to name: String) async -> Bool {
        do {
            let updated = try await service.renameProject(id: project.id, name: name)
            replace(updated)
            return true
        } catch {
            self.error = String(localized: "cloud.error.save")
            return false
        }
    }

    func setFavorite(_ project: AIMProject, value: Bool) async {
        do { replace(try await service.setProjectFavorite(id: project.id, isFavorite: value)) }
        catch { self.error = String(localized: "cloud.error.save") }
    }

    func delete(_ project: AIMProject) async {
        do {
            try await service.deleteProject(id: project.id)
            projects.removeAll { $0.id == project.id }
        } catch { self.error = String(localized: "cloud.error.save") }
    }

    private func replace(_ project: AIMProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            projects.insert(project, at: 0)
            return
        }
        projects[index] = project
    }

    func loadMedia(kind: AIMMediaKind) async {
        mediaKind = kind; isLoading = true; error = nil
        defer { isLoading = false }
        do { media = try await service.loadMedia(kind: kind) }
        catch { self.error = String(localized: "cloud.error.load") }
    }

    func delete(_ item: AIMMediaItem) async -> Bool {
        do {
            try await service.deleteMedia(item)
            media.removeAll { $0.id == item.id }
            return true
        } catch {
            self.error = String(localized: "cloud.error.save")
            return false
        }
    }
}

@MainActor
@Observable
private final class AIMProjectDetailStore {
    var conversations: [AIMProjectConversation] = []
    var files: [AIMProjectFile] = []
    var messages: [AIMLegacyMessage] = []
    var selectedConversation: AIMProjectConversation?
    var isLoading = false
    var isMutatingFile = false
    var error: String?
    private let service: any CloudContentServicing

    init(service: any CloudContentServicing) { self.service = service }

    func load(projectID: String) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let conversationRows = service.loadProjectConversations(projectID: projectID)
            async let fileRows = service.loadProjectFiles(projectID: projectID)
            (conversations, files) = try await (conversationRows, fileRows)
        } catch { self.error = String(localized: "projects.detail.load_error") }
    }

    func open(_ conversation: AIMProjectConversation) async {
        withAnimation(.timingCurve(0.22, 0.72, 0.22, 1, duration: 0.3)) {
            selectedConversation = conversation
        }
        AIMHaptics.impact(.light)
        do { messages = try await service.loadLegacyMessages(conversationID: conversation.id) }
        catch { self.error = String(localized: "projects.detail.load_error") }
    }

    func closeConversation() {
        selectedConversation = nil
        messages = []
    }

    func upload(projectID: String, prepared: AIMPreparedProjectDocument) async -> Bool {
        isMutatingFile = true; error = nil
        defer { isMutatingFile = false }
        do {
            let file = try await service.uploadProjectFile(projectID: projectID, data: prepared.source,
                name: prepared.name, mimeType: prepared.mimeType, extractedText: prepared.text)
            files.removeAll { $0.id == file.id }; files.insert(file, at: 0)
            return true
        } catch is CancellationError { return false }
        catch { self.error = String(localized: "projects.detail.file_upload_error"); return false }
    }

    func delete(projectID: String, file: AIMProjectFile) async {
        isMutatingFile = true; error = nil
        defer { isMutatingFile = false }
        do {
            try await service.deleteProjectFile(projectID: projectID, fileID: file.id)
            files.removeAll { $0.id == file.id }
        } catch {
            self.error = String(localized: "projects.detail.file_delete_error")
        }
    }
}

private struct AIMProjectDetailView: View {
    let project: AIMProject
    let safeTop: CGFloat
    let close: () -> Void
    @State private var store: AIMProjectDetailStore
    @State private var fileToDelete: AIMProjectFile?

    init(project: AIMProject, service: any CloudContentServicing, safeTop: CGFloat, close: @escaping () -> Void) {
        self.project = project; self.safeTop = safeTop; self.close = close
        _store = State(initialValue: AIMProjectDetailStore(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                }
                .buttonStyle(.plain)
                .aimGlassCircle()
                Spacer()
                Text(project.name).font(AIMDesign.titleFont(size: 22)).lineLimit(1)
                Spacer()
                Color.clear.frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .padding(.horizontal, 16).padding(.top, safeTop + 10).padding(.bottom, 12)
            .aimTranslucentHeader()
            .zIndex(2)

            if store.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let description = project.description, !description.isEmpty {
                            Text(description).font(.body).foregroundStyle(.secondary)
                        }
                        if let context = project.customContext, !context.isEmpty {
                            detailSection(title: "projects.detail.instructions", icon: "text.alignleft") {
                                AIMMarkdownView(source: context, baseFont: .subheadline).textSelection(.enabled)
                            }
                        }
                        detailSection(title: "projects.detail.conversations", icon: "bubble.left.and.bubble.right") {
                            if store.conversations.isEmpty {
                                Text("projects.detail.no_conversations").foregroundStyle(.secondary)
                            } else {
                                ForEach(store.conversations) { conversation in
                                    HStack {
                                        Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(conversation.title).lineLimit(2)
                                            if let model = conversation.model { Text(model).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .accessibilityElement(children: .combine)
                                    .aimSwipeSafeTap { Task { await store.open(conversation) } }
                                    .accessibilityIdentifier("project-conversation-\(conversation.id)")
                                }
                            }
                        }
                        detailSection(title: "projects.detail.files", icon: "doc") {
                            AIMProjectDocumentImportButton(cloudUpload: true) { prepared in
                                await store.upload(projectID: project.id, prepared: prepared)
                            }.disabled(store.isMutatingFile)

                            if store.files.isEmpty {
                                Text("projects.detail.no_files").foregroundStyle(.secondary)
                            } else {
                                ForEach(store.files) { file in
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name).lineLimit(2)
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: file.status == "completed" ? "checkmark.circle.fill" : "clock")
                                            .foregroundStyle(file.status == "completed" ? Color.green : Color.secondary)
                                        Menu {
                                            Button("common.delete", systemImage: "trash", role: .destructive) {
                                                fileToDelete = file
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 7)
                                }
                            }
                        }
                        if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(18)
                }
                .refreshable { await store.load(projectID: project.id) }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await store.load(projectID: project.id) }
        .confirmationDialog(
            "projects.detail.delete_file_confirm",
            isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } })
        ) {
            Button("common.delete", role: .destructive) {
                guard let file = fileToDelete else { return }
                fileToDelete = nil
                Task { await store.delete(projectID: project.id, file: file) }
            }
            Button("common.cancel", role: .cancel) { fileToDelete = nil }
        }
        .overlay {
            if let conversation = store.selectedConversation {
                AIMLegacyConversationView(
                    conversation: conversation,
                    messages: store.messages,
                    close: {
                        withAnimation(.timingCurve(0.22, 0.72, 0.22, 1, duration: 0.3)) {
                            store.closeConversation()
                        }
                    }
                )
                .background(Color(uiColor: .systemBackground))
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
            }
        }
    }

    private func detailSection<Content: View>(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct AIMLegacyConversationView: View {
    let conversation: AIMProjectConversation
    let messages: [AIMLegacyMessage]
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty {
                        ContentUnavailableView("projects.detail.no_messages", systemImage: "bubble.left")
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role == "user" ? "projects.detail.you" : "AIM AI")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if let reasoning = message.reasoning, !reasoning.isEmpty {
                                DisclosureGroup("remote.message.reasoning") {
                                    Text(reasoning).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            AIMMarkdownView(source: message.content)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(message.role == "user" ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(16)
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.close") { close() } } }
        }
    }
}

private typealias AIMProjectFilter = AIMProjectScope

private extension AIMProjectScope {
    var title: LocalizedStringKey {
        switch self {
        case .all: "projects.filter.all"
        case .favorites: "projects.filter.favorites"
        case .recent: "projects.filter.recent"
        }
    }
}

struct AIMProjectsView: View {
    let safeTop: CGFloat
    let openMenu: () -> Void
    @State private var store: AIMCloudContentStore
    @State private var showingCreator = false
    @State private var projectToRename: AIMProject?
    @State private var projectToDelete: AIMProject?
    @State private var selectedProject: AIMProject?
    @State private var filter: AIMProjectFilter = .all
    @State private var search = ""
    @State private var searchVisible = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(service: any CloudContentServicing, safeTop: CGFloat, openMenu: @escaping () -> Void) {
        self.safeTop = safeTop
        self.openMenu = openMenu
        _store = State(initialValue: AIMCloudContentStore(service: service))
    }

    var body: some View {
        ZStack {
            projectList.opacity(selectedProject == nil ? 1 : 0)
                .allowsHitTesting(selectedProject == nil).accessibilityHidden(selectedProject != nil)
            if let selectedProject {
                AIMProjectDetailView(
                    project: selectedProject,
                    service: store.serviceForChildren,
                    safeTop: safeTop,
                    close: {
                        withAnimation(reduceMotion ? nil : .timingCurve(0.22, 0.72, 0.22, 1, duration: 0.32)) {
                            self.selectedProject = nil
                        }
                    }
                )
                .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
    }

    private var projectList: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                projectsHeader
            if store.isLoading && store.projects.isEmpty { ProgressView().frame(maxHeight: .infinity) }
            else if filteredProjects.isEmpty {
                ContentUnavailableView("projects.empty.title", systemImage: "folder", description: Text("projects.empty.body"))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredProjects) { project in projectCard(project) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 118)
                }
                .refreshable { await store.loadProjects() }
            }
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if searchVisible {
                        TextField("projects.search", text: $search)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 15)
                            .frame(height: 46)
                            .frame(maxWidth: 240)
                            .aimGlassCapsule()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Button { withAnimation(.snappy) { searchVisible.toggle(); if !searchVisible { search = "" } } } label: {
                        Image(systemName: searchVisible ? "xmark" : "magnifyingglass")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .aimGlassCircle()
                    .accessibilityLabel(Text("projects.search"))
                    .accessibilityIdentifier("projects-search-button")
                }
                Spacer()
                Button { showingCreator = true } label: {
                    Label("projects.new", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 20)
                        .frame(height: 54)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projects-new-button")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("projects-screen")
        .task { await store.loadProjects() }
        .sheet(isPresented: $showingCreator) {
            AIMProjectCreator { name, description, instructions in
                await store.createProject(name: name, description: description, instructions: instructions)
            }
            .aimUniversalPanelSurface()
        }
        .sheet(item: $projectToRename) { project in
            AIMProjectRenamePanel(project: project) { name in await store.rename(project, to: name) }
                .aimUniversalPanelSurface()
        }
        .confirmationDialog("projects.delete.confirm", isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })) {
            Button("common.delete", role: .destructive) {
                guard let project = projectToDelete else { return }
                projectToDelete = nil
                Task { await store.delete(project) }
            }
            Button("common.cancel", role: .cancel) { projectToDelete = nil }
        }
    }

    private var projectsHeader: some View {
        HStack {
            Button(action: openMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .buttonStyle(.plain).aimGlassCircle()
            .accessibilityIdentifier("projects-filter-button")
            Spacer()
            Text("sidebar.projects").font(.system(size: 23, weight: .semibold))
            Spacer()
            Menu {
                Picker("projects.filter", selection: $filter) {
                    ForEach(AIMProjectFilter.allCases) { option in Text(option.title).tag(option) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .buttonStyle(.plain).aimGlassCircle()
        }
        .padding(.horizontal, 16).padding(.top, safeTop + 10).padding(.bottom, 12)
        .aimTranslucentHeader()
        .zIndex(2)
    }

    private var filteredProjects: [AIMProject] {
        AIMProjectRules.filtered(store.projects, scope: filter, query: search)
    }

    private func projectCard(_ project: AIMProject) -> some View {
        HStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder").font(.system(size: 19)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.system(size: 19)).lineLimit(1)
                    Text([project.description?.trimmingCharacters(in: .whitespacesAndNewlines), relativeDate(project.updatedAt)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .aimSwipeSafeTap { selectedProject = project; AIMHaptics.impact(.light) }
            .accessibilityIdentifier("project-row-\(project.id)")
            Menu {
                Button { Task { await store.setFavorite(project, value: !project.isStarred) } } label: {
                    Label(project.isStarred ? "projects.unfavorite" : "projects.favorite", systemImage: project.isStarred ? "star.slash" : "star")
                }
                Button { projectToRename = project } label: { Label("projects.rename", systemImage: "pencil") }
                Button(role: .destructive) { projectToDelete = project } label: { Label("common.delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-actions-\(project.id)")
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct AIMLibraryView: View {
    let safeTop: CGFloat
    var media: AIMMediaStore? = nil
    let openMenu: () -> Void
    @State private var store: AIMCloudContentStore
    @State private var selected: AIMMediaItem?

    init(service: any CloudContentServicing, media: AIMMediaStore? = nil, safeTop: CGFloat, openMenu: @escaping () -> Void) {
        self.safeTop = safeTop; self.openMenu = openMenu; self.media = media
        _store = State(initialValue: AIMCloudContentStore(service: service))
    }

    private var items: [AIMMediaItem] {
        let local: [AIMMediaItem] = (media?.visibleAssets ?? []).compactMap { asset in
            guard (asset.kind == .image ? AIMMediaKind.image : .video) == store.mediaKind, let url = media?.localURL(asset: asset) else { return nil }
            return AIMMediaItem(id: asset.id.uuidString, kind: asset.kind == .image ? .image : .video, url: url, prompt: asset.title, model: asset.modelID, createdAt: asset.createdAt, expiresAt: .distantFuture, storagePath: asset.objectPath)
        }
        let localIDs = Set(local.map { $0.id.lowercased() })
        return (local + store.media.filter { !localIDs.contains($0.id.lowercased()) }).sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            AIMCloudHeader(title: "sidebar.library", safeTop: safeTop, openMenu: openMenu) {
                Picker("library.type", selection: Binding(get: { store.mediaKind }, set: { kind in Task { await store.loadMedia(kind: kind) } })) {
                    Label("library.images", systemImage: "photo").tag(AIMMediaKind.image)
                    Label("library.videos", systemImage: "video").tag(AIMMediaKind.video)
                }
                .labelsHidden()
                .pickerStyle(.menu).tint(.primary)
            }
            if store.isLoading && items.isEmpty { ProgressView().frame(maxHeight: .infinity) }
            else if items.isEmpty {
                ContentUnavailableView(store.mediaKind == .image ? "library.images.empty" : "library.videos.empty", systemImage: store.mediaKind == .image ? "photo.on.rectangle.angled" : "video")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            Button { selected = item } label: {
                                GeometryReader { geometry in
                                ZStack(alignment: .bottomLeading) {
                                    AIMLibraryThumbnail(url: item.url, video: item.kind == .video)
                                    .frame(width: geometry.size.width, height: geometry.size.width)
                                    .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                                    Text(item.prompt).font(.caption).foregroundStyle(.white).lineLimit(2).padding(10)
                                    if item.kind == .video { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
                                }
                                .frame(width: geometry.size.width, height: geometry.size.width).clipped()
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityElement(children: .ignore).accessibilityLabel(item.prompt)
                            .accessibilityIdentifier("library-tile-" + item.id)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await store.loadMedia(kind: store.mediaKind) }
            }
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain).accessibilityIdentifier("library-screen")
        .task { await store.loadMedia(kind: .image); await media?.synchronize() }
        .sheet(item: $selected) { item in AIMMediaDetail(item: item) {
            if let media, let id = UUID(uuidString: item.id), media.assets.contains(where: { $0.id == id }) { await media.delete(assetID: id); return true }
            return await store.delete(item)
        } }
    }
}

private struct AIMLibraryThumbnail: View {
    let url: URL
    let video: Bool
    @State private var preview: UIImage?
    var body: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().scaledToFill() }
            else if !video && !url.isFileURL { AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { placeholder } } }
            else { placeholder }
        }.task(id: url) {
            if video {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 480, height: 480)
                if let (image, _) = try? await generator.image(at: .zero) { preview = UIImage(cgImage: image) }
            } else if url.isFileURL { if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { preview = UIImage(cgImage: cg) } }
        }
    }
    private var placeholder: some View { Color.primary.opacity(0.06).overlay { Image(systemName: video ? "video" : "photo").foregroundStyle(.secondary) } }
}

private struct AIMCloudHeader<Trailing: View>: View {
    let title: LocalizedStringKey; let safeTop: CGFloat; let openMenu: () -> Void; @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack {
            Button(action: openMenu) { Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget) }.buttonStyle(.plain).aimGlassCircle().accessibilityLabel(Text("common.back")).accessibilityIdentifier("cloud-content-back")
            Spacer(); Text(title).font(AIMDesign.titleFont(size: 23)); Spacer(); trailing().frame(minWidth: AIMDesign.standardTouchTarget)
        }
        .padding(.horizontal, 16).padding(.top, safeTop + 10).padding(.bottom, 12)
        .aimTranslucentHeader()
        .zIndex(2)
    }
}

private struct AIMProjectCreator: View {
    let create: (String, String?, String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var description = ""; @State private var instructions = ""; @State private var saving = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                }
                .buttonStyle(.plain).aimGlassCircle()
                Spacer()
                Text("projects.new").font(.system(size: 20, weight: .semibold))
                Spacer()
                Color.clear.frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 14) {
                    TextField("projects.name", text: $name)
                        .textInputAutocapitalization(.words)
                        .padding(15).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
                    TextField("projects.description", text: $description, axis: .vertical)
                        .lineLimit(2...4).padding(15)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
                    TextField("projects.instructions", text: $instructions, axis: .vertical)
                        .lineLimit(3...8).padding(15)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
                    Button {
                        saving = true
                        Task {
                            if await create(name, description.nilIfEmpty, instructions.nilIfEmpty) { dismiss() }
                            saving = false
                        }
                    } label: {
                        Group { if saving { ProgressView() } else { Text("common.create") } }
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
                .padding(.horizontal, 18).padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct AIMProjectRenamePanel: View {
    let project: AIMProject
    let rename: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false

    init(project: AIMProject, rename: @escaping (String) async -> Bool) {
        self.project = project; self.rename = rename
        _name = State(initialValue: project.name)
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).aimGlassCircle()
                Spacer(); Text("projects.rename").font(.headline); Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            TextField("projects.name", text: $name)
                .textInputAutocapitalization(.words)
                .padding(15).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
            Button {
                saving = true
                Task { if await rename(name) { dismiss() }; saving = false }
            } label: {
                Group { if saving { ProgressView() } else { Text("projects.rename") } }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            Spacer(minLength: 0)
        }
        .padding(18)
        .presentationDetents([.height(270)])
        .presentationDragIndicator(.visible)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct AIMMediaDetail: View {
    let item: AIMMediaItem; let delete: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if item.kind == .image, item.url.isFileURL, let image = UIImage(contentsOfFile: item.url.path) { Image(uiImage: image).resizable().scaledToFit() }
                    else if item.kind == .image { AsyncImage(url: item.url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().frame(maxWidth: .infinity, minHeight: 220) } }
                    else { VideoPlayer(player: AVPlayer(url: item.url)).frame(height: 260) }
                    Text(item.prompt).font(AIMDesign.titleFont(size: 18)).textSelection(.enabled)
                    Text(item.model).font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }
            .tint(.primary)
            .navigationTitle(item.kind == .image ? "library.image" : "library.video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) { Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") } }
            }
            .confirmationDialog("library.delete.confirm", isPresented: $confirmingDelete) {
                Button("common.delete", role: .destructive) { Task { if await delete() { dismiss() } } }
                Button("common.cancel", role: .cancel) {}
            }
        }
    }
}
