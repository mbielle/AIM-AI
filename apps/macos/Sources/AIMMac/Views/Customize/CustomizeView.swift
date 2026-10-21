import AIMApplication
import AIMMacPlatform
import AppKit
import SwiftUI

/// Customize (as in Claude): skills, connectors and plugins in one place, yours and a store
/// to discover more. It fills the main area, next to the sidebar.
struct CustomizeView: View {
    enum Tab: String, CaseIterable { case skills = "Skills", connectors = "Connectors", plugins = "Plugins" }
    enum Scope: String { case yours = "Yours", discover = "Discover" }
    enum Sort: String, CaseIterable { case popular = "Most installed", trending = "Trending", name = "Name" }
    enum Detail: Identifiable, Equatable {
        case skill(StoreSkill), connector(StoreConnector), plugin(StorePlugin)
        var id: String {
            switch self { case .skill(let s): "s:" + s.id; case .connector(let c): "c:" + c.id; case .plugin(let p): "p:" + p.id }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var tab = Tab.skills
    @State private var scope = Scope.discover
    @State private var query = ""
    @State private var sort = Sort.popular
    @State private var category: String?
    @State private var showAll = false
    @State private var showAdd = false
    @State private var showSort = false
    @State private var showFilter = false
    @State private var detail: Detail?
    @State private var message: String?
    @State private var busy: Set<String> = []

    // Data
    @State private var popular: [StoreSkill] = []
    @State private var trending: [StoreSkill] = []
    @State private var searchResults: [StoreSkill] = []
    @State private var skillPage = 0
    @State private var categoryCounts: [String: Int] = [:]
    @State private var installedSkills: [Skill] = []
    @State private var servers: [MCPServerConfiguration] = []
    @State private var serverStatus: [UUID: String] = [:]
    @State private var registry: [StoreConnector] = []
    @State private var registryCursor: String?
    @State private var plugins: [StorePlugin] = []
    @State private var installedPlugins: [InstalledPlugin] = []
    @State private var tokenFor: StoreConnector?
    @State private var tokenValue = ""
    @State private var creatingSkill = false
    @State private var addingConnector = false
    @State private var carousel = 0
    @State private var carouselStarted = Date.now
    @State private var carouselHovered = false

    private let store = CustomizeStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let message {
                    SettingsNotice(message, tone: .warning).padding(.bottom, 18)
                }
                if let detail {
                    CustomizeDetailPage(detail: detail, backTitle: tab.rawValue, installed: isInstalled(detail),
                                        installedServer: installedServer(detail), busy: busy.contains(detail.id),
                                        related: related(to: detail), isInstalled: isInstalled,
                                        install: { item in Task { await install(item) } }, remove: { Task { await uninstall(detail) } },
                                        open: { item in self.detail = item }, back: { self.detail = nil })
                        .id(detail.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                } else {
                Text("Customize").font(AIMTypography.title(34, weight: .medium)).padding(.bottom, 26)
                header.padding(.bottom, 22)
                Group {
                    switch (tab, scope) {
                    case (.skills, .discover): skillsDiscover
                    case (.skills, .yours): skillsYours
                    case (.connectors, .discover): connectorsDiscover
                    case (.connectors, .yours): connectorsYours
                    case (.plugins, .discover): pluginsDiscover
                    case (.plugins, .yours): pluginsYours
                    }
                }
                .transition(.opacity)
                }
            }
            .frame(maxWidth: 1_120, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(AIMTheme.background(scheme))
        .animation(.easeOut(duration: 0.18), value: tab)
        .animation(.easeOut(duration: 0.22), value: detail?.id)
        .animation(.easeOut(duration: 0.18), value: scope)
        .task { await reloadLocal(); await loadStore() }
        .task(id: "\(tab.rawValue)|\(query)") { await search() }
        .onChange(of: tab) { _, _ in query = ""; category = nil; showAll = false; detail = nil }
        .onChange(of: scope) { _, _ in category = nil; showAll = false }
        .sheet(item: $tokenFor) { connector in tokenSheet(connector) }
        .sheet(isPresented: $creatingSkill) {
            CreateSkillSheet { name, description, body in
                try createSkill(name: name, description: description, body: body)
                creatingSkill = false
                scope = .yours
            } cancel: { creatingSkill = false }
        }
        .sheet(isPresented: $addingConnector) {
            AddMCPServerSheet { configuration, secrets in
                for (name, value) in secrets { try? MCPSecretStore.save(value, name: name, serverID: configuration.id) }
                try? await model.mcpServerRepository.save(configuration)
                addingConnector = false
                await reloadLocal()
            } cancel: { addingConnector = false }
        }
        #if DEBUG
        .onAppear {
            if let menu = model.debugOpenMenu, menu.hasPrefix("customize-") {
                let parts = menu.split(separator: "-").map(String.init)
                if parts.count >= 3 {
                    tab = Tab.allCases.first { $0.rawValue.lowercased() == parts[1] } ?? .skills
                    scope = parts[2] == "yours" ? .yours : .discover
                }
                if menu.hasSuffix("-add") { showAdd = true }
                if menu.hasSuffix("-detail") { Task { @MainActor in
                    switch tab {
                    case .connectors: detail = CustomizeCatalog.connectors.first { $0.id == "figma" }.map { .connector($0) }
                    case .skills: detail = .skill(StoreSkill(source: "anthropics/skills", skillId: "pdf", name: "pdf", installs: 205_542,
                                                             description: "Read, fill, merge and create PDF files.",
                                                             weeklyInstalls: [9_100, 9_800, 10_200, 11_400, 12_100, 12_900, 13_300, 14_800]))
                    case .plugins: break
                    }
                } }
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                HStack(spacing: 4) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        CustomizeTabButton(title: item.rawValue, selected: tab == item) { tab = item }
                    }
                }
                Rectangle().fill(AIMTheme.cardBorder(scheme)).frame(width: 1, height: 22)
                AIMSegmentedControl(selection: $scope, options: [(.yours, "Yours"), (.discover, "Discover")], identifierPrefix: "customize-scope-")
                Spacer()
            }
            HStack(spacing: 10) {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(tab.rawValue.lowercased())", text: $query).textFieldStyle(.plain).focusEffectDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }
                .font(.system(size: 14)).padding(.horizontal, 12).frame(width: 320, height: 40)
                .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                iconButton("slider.horizontal.3", active: showFilter || category != nil, help: "Filter") { showFilter.toggle() }
                    .aimMenu(isPresented: $showFilter, alignment: .trailing) { filterMenu }
                if tab == .skills && scope == .discover {
                    iconButton("arrow.up.arrow.down", active: showSort, help: "Sort") { showSort.toggle() }
                        .aimMenu(isPresented: $showSort, alignment: .trailing) {
                            ForEach(Sort.allCases, id: \.self) { option in
                                AIMMenuItem(option.rawValue, checked: sort == option) { sort = option }
                            }
                        }
                }
                Button { showAdd.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        Text("Add").font(.system(size: 15, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 15).frame(height: 40)
                    .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .aimMenu(isPresented: $showAdd, alignment: .trailing) { addMenu }
            }
        }
    }

    private func iconButton(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 40, height: 40)
        }
        .buttonStyle(.aimHover(radius: 10, active: active)).aimTooltip(help).accessibilityLabel(help)
    }

    @ViewBuilder private var addMenu: some View {
        switch tab {
        case .skills, .plugins:
            AIMMenuItem("Import a skill", icon: "square.and.arrow.up") { importSkill() }
            AIMMenuItem("Create a skill", icon: "pencil") { creatingSkill = true }
            AIMMenuItem("Create with AIM", icon: "bubble.left.and.text.bubble.right") { Task { await model.createSkillWithAIM() } }
            AIMMenuItem("Record your screen · soon", icon: "video") {}.disabled(true)
        case .connectors:
            AIMMenuItem("Add a custom connector", icon: "plus.circle") { addingConnector = true }
            AIMMenuItem("Import JSON (Claude Desktop format)", icon: "curlybraces") { model.settingsSection = .connectors }
        }
    }

    @ViewBuilder private var filterMenu: some View {
        AIMMenuItem("All", checked: category == nil) { category = nil }
        switch tab {
        case .skills:
            ForEach(CustomizeCatalog.skillCategories, id: \.title) { item in
                AIMMenuItem(item.title, icon: item.icon, checked: category == item.title) { category = item.title }
            }
        case .connectors:
            ForEach(connectorCategories, id: \.self) { item in
                AIMMenuItem(item, checked: category == item) { category = item }
            }
        case .plugins:
            ForEach(pluginCategories, id: \.self) { item in
                AIMMenuItem(item.capitalized, checked: category == item) { category = item }
            }
        }
    }

    private var grid: [GridItem] { [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)] }

    // MARK: Skills

    private var skillsSource: [StoreSkill] {
        if !query.isEmpty { return searchResults }
        switch sort {
        case .popular: return popular
        case .trending: return trending.isEmpty ? popular : trending
        case .name: return popular.sorted { $0.name < $1.name }
        }
    }

    private func filtered(_ skills: [StoreSkill]) -> [StoreSkill] {
        guard let category else { return skills }
        return skills.filter { CustomizeCatalog.category(of: withDescription($0)) == category }
    }

    private func withDescription(_ skill: StoreSkill) -> StoreSkill { skill }

    @ViewBuilder private var skillsDiscover: some View {
        VStack(alignment: .leading, spacing: 40) {
            if query.isEmpty && category == nil && !showAll {
                featuredBanner
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "Essential skills")
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(CustomizeCatalog.featuredSkills) { skillCard($0) }
                    }
                }
                if !trending.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        StoreSectionHeader(title: "Trending this week", action: ("View all", { sort = .trending; showAll = true }))
                        LazyVGrid(columns: grid, spacing: 16) { ForEach(trending.prefix(6)) { skillCard($0) } }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "Most installed", action: ("View all", { sort = .popular; showAll = true }))
                    LazyVGrid(columns: grid, spacing: 16) { ForEach(popular.prefix(6)) { skillCard($0) } }
                }
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "Categories")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                        ForEach(CustomizeCatalog.skillCategories, id: \.title) { item in
                            StoreCategoryTile(title: item.title, icon: item.icon, count: categoryCounts[item.title] ?? 0) {
                                category = item.title
                            }
                        }
                    }
                }
                if popular.isEmpty { loadingRow }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if showAll || category != nil {
                            Button { showAll = false; category = nil } label: {
                                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Back") }.font(.system(size: 14))
                            }
                            .buttonStyle(TextLinkStyle()).padding(.trailing, 8)
                        }
                        StoreSectionHeader(title: !query.isEmpty ? "Results" : category ?? sort.rawValue, count: filtered(skillsSource).count)
                    }
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(filtered(skillsSource)) { skill in
                            skillCard(skill).onAppear {
                                if query.isEmpty, skill.id == skillsSource.last?.id { Task { await loadMoreSkills() } }
                            }
                        }
                    }
                }
            }
        }
    }

    private var featuredBanner: some View {
        let skill = CustomizeCatalog.featuredSkills[0]
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                Text("From AIM").font(.system(size: 13)).foregroundStyle(.black.opacity(0.6))
                Text("Documents").font(AIMTypography.title(30, weight: .medium)).foregroundStyle(.black.opacity(0.85))
                Text("Read, fill and create PDF, Word, Excel and PowerPoint files, the way professionals do.")
                    .font(.system(size: 15)).foregroundStyle(.black.opacity(0.7))
                Button {
                    Task { for item in CustomizeCatalog.featuredSkills.prefix(4) { await installSkill(item) } }
                } label: {
                    Text(CustomizeCatalog.featuredSkills.prefix(4).allSatisfy(isInstalled) ? "Added" : "Add")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36).background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).padding(.top, 6)
                .disabled(busy.contains(skill.id))
            }
            Spacer()
            Image(systemName: "doc.richtext").font(.system(size: 92, weight: .ultraLight)).foregroundStyle(.black.opacity(0.75))
                .padding(.trailing, 50)
        }
        .padding(34)
        .background(Color(red: 0.80, green: 0.85, blue: 0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func skillCard(_ skill: StoreSkill) -> some View {
        SkillStoreCard(skill: skill, installed: isInstalled(skill), busy: busy.contains("s:" + skill.id),
                       open: { described in detail = .skill(described) }, install: { Task { await installSkill(skill) } })
            .equatable()
    }

    @ViewBuilder private var skillsYours: some View {
        let mine = installedSkills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 30) {
            if installedSkills.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add your first skills").font(.system(size: 17, weight: .semibold))
                    Text("Skills teach AIM how you work. Add them from Discover or create your own.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    Button { scope = .discover } label: {
                        Text("Discover skills").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 38).background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain).padding(.top, 6)
                }
                .padding(26).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            let groups: [(String, [Skill])] = [
                ("From the store", mine.filter { $0.origin?.hasPrefix("store:") == true || $0.origin?.hasPrefix("plugin:") == true }),
                ("Created by you", mine.filter { $0.origin == nil && $0.source == .global }),
                ("Learned by AIM", mine.filter { $0.origin == "learned" }),
                ("In this workspace", mine.filter { $0.source == .workspace }),
            ]
            ForEach(groups, id: \.0) { group in
                if !group.1.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        StoreSectionHeader(title: group.0, count: group.1.count)
                        VStack(spacing: 0) {
                            ForEach(group.1) { skill in
                                installedSkillRow(skill)
                                if skill.id != group.1.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func installedSkillRow(_ skill: Skill) -> some View {
        let disabled = SkillPreferences.disabled.contains(skill.name)
        let origin = skill.origin.map { $0.hasPrefix("store:") ? "by " + StoreFormat.publisher(String($0.dropFirst(6))) : $0.hasPrefix("plugin:") ? "from a plugin" : $0 == "learned" ? "learned by AIM" : $0 } ?? "by you"
        let modified = (try? skill.directory.appendingPathComponent("SKILL.md").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return HStack(spacing: 16) {
            RemoteLogo(url: skill.origin.flatMap { origin in
                origin.hasPrefix("store:") ? CustomizeCatalog.ownerAvatar(String(origin.dropFirst(6).split(separator: "/").first ?? "")) : nil
            }, fallback: StoreFormat.skillIcon(skill.name), size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name).font(.system(size: 15, weight: .medium)).foregroundStyle(disabled ? .secondary : .primary)
                Text("\(origin) · \(skill.description)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 20)
            if let modified { Text(modified.formatted(.relative(presentation: .named))).font(.system(size: 13)).foregroundStyle(.tertiary) }
            if disabled { Text("Off").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            SkillRowMenu(skill: skill, disabled: disabled) { await reloadLocal() }
        }
        .padding(.vertical, 14)
    }

    // MARK: Connectors

    private var connectorCategories: [String] {
        Array(Set(CustomizeCatalog.connectors.map(\.category))).sorted()
    }

    private func matches(_ connector: StoreConnector) -> Bool {
        (category == nil || connector.category == category)
            && (query.isEmpty || connector.name.localizedCaseInsensitiveContains(query) || connector.description.localizedCaseInsensitiveContains(query))
    }

    @ViewBuilder private var connectorsDiscover: some View {
        VStack(alignment: .leading, spacing: 40) {
            if query.isEmpty && category == nil { connectorCarousel }
            VStack(alignment: .leading, spacing: 16) {
                StoreSectionHeader(title: query.isEmpty && category == nil ? "Most used connectors" : category ?? "Results",
                                   count: CustomizeCatalog.connectors.filter(matches).count)
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(CustomizeCatalog.connectors.filter(matches)) { connectorCard($0) }
                }
            }
            if !query.isEmpty || !registry.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "More from the MCP registry", count: registry.count)
                    Text("Community servers listed in the official MCP registry. Check the publisher before connecting.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(registry.filter { candidate in !CustomizeCatalog.connectors.contains { $0.url == candidate.url } }) { connectorCard($0) }
                    }
                    if registryCursor != nil {
                        Button("Load more") { Task { await loadRegistry(reset: false) } }.buttonStyle(.settings)
                    }
                }
            }
            if query.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "Categories")
                    FlowRow(spacing: 10) {
                        ForEach(connectorCategories, id: \.self) { item in
                            StoreChip(title: item, count: CustomizeCatalog.connectors.filter { $0.category == item }.count, selected: category == item) {
                                category = category == item ? nil : item
                            }
                        }
                    }
                }
            }
        }
    }

    private var carouselSets: [(title: String, subtitle: String, ids: [String])] {
        [("AIM for design", "Sketch, design and iterate with your creative tools.", ["canva", "figma", "webflow", "wix"]),
         ("AIM for engineering", "Issues, code, deployments and errors in one conversation.", ["github", "linear", "sentry", "vercel", "supabase"]),
         ("AIM for business", "Payments, customers and documents, without switching apps.", ["stripe", "hubspot", "notion", "paypal", "intercom"])]
    }

    private var connectorCarousel: some View {
        let set = carouselSets[carousel % carouselSets.count]
        return VStack(spacing: 14) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.96, green: 0.97, blue: 0.97), Color(red: 0.80, green: 0.88, blue: 0.87)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 14) {
                    Text("SELECTED BY AIM").font(.system(size: 12, weight: .medium)).kerning(0.6).foregroundStyle(.black.opacity(0.55))
                    Text(set.title).font(.system(size: 30, weight: .regular)).foregroundStyle(.black.opacity(0.85))
                    Text(set.subtitle).font(.system(size: 15)).foregroundStyle(.black.opacity(0.65))
                    HStack(spacing: 16) {
                        ForEach(set.ids, id: \.self) { id in
                            RemoteLogo(url: CustomizeCatalog.connectors.first { $0.id == id }?.logo, size: 64)
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        }
                    }
                    .padding(.vertical, 8)
                    Button { category = nil; query = ""; detail = CustomizeCatalog.connectors.first { $0.id == set.ids[0] }.map { .connector($0) } } label: {
                        Text("Explore").font(.system(size: 15, weight: .medium)).foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 20).frame(height: 40)
                            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 30)
                HStack {
                    carouselArrow("chevron.left") { showSlide(carousel - 1) }
                    Spacer()
                    carouselArrow("chevron.right") { showSlide(carousel + 1) }
                }
                .padding(.horizontal, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
            .animation(.easeInOut(duration: 0.35), value: carousel)
            .onHover { carouselHovered = $0 }
            // The active pill fills up until the next slide (it pauses under the pointer).
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: carouselHovered)) { context in
                let progress = min(1, context.date.timeIntervalSince(carouselStarted) / Self.slideSeconds)
                HStack(spacing: 6) {
                    ForEach(0..<carouselSets.count, id: \.self) { index in
                        if index == carousel {
                            Capsule().fill(Color.primary.opacity(0.15)).frame(width: 40, height: 8)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.45)).frame(width: max(8, 40 * progress), height: 8)
                                }
                        } else {
                            Button { showSlide(index) } label: { Circle().fill(Color.primary.opacity(0.15)).frame(width: 8, height: 8) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: progress >= 1) { _, done in if done { showSlide(carousel + 1) } }
            }
        }
    }

    static let slideSeconds: Double = 6

    private func showSlide(_ index: Int) {
        let count = carouselSets.count
        carousel = ((index % count) + count) % count
        carouselStarted = .now
    }

    private func carouselArrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.black.opacity(0.7))
                .frame(width: 44, height: 44).background(Color.white.opacity(0.9), in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }.buttonStyle(.plain)
    }

    private func connectorCard(_ connector: StoreConnector) -> some View {
        StoreCard(title: connector.name, verified: connector.category != "Registry", subtitle: connector.description,
                  footer: "by " + connector.publisher, installed: isInstalled(connector), soon: connector.soon,
                  busy: busy.contains("c:" + connector.id),
                  icon: { RemoteLogo(url: connector.logo, fallback: "powerplug", size: 48) },
                  open: { detail = .connector(connector) }, install: { Task { await installConnector(connector) } })
    }

    @ViewBuilder private var connectorsYours: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoreSectionHeader(title: "Your connectors", count: servers.count)
            if servers.isEmpty {
                Text("No connector yet. Add one from Discover to let AIM work with your apps.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            VStack(spacing: 0) {
                ForEach(servers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { server in
                    let known = CustomizeCatalog.connectors.first { $0.url == server.url }
                    HStack(spacing: 16) {
                        RemoteLogo(url: known?.logo, fallback: server.transport == .stdio ? "terminal" : "globe", size: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(known?.name ?? server.name).font(.system(size: 15, weight: .medium))
                            Text([server.transport == .stdio ? server.command : server.url, serverStatus[server.id]].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ConnectorRowActions(server: server) { await reloadLocal() }
                        SettingsSwitch(isOn: Binding(get: { server.enabled }, set: { value in
                            var updated = server; updated.enabled = value
                            Task { try? await model.mcpServerRepository.save(updated); await reloadLocal() }
                        }), label: "Enabled")
                    }
                    .padding(.vertical, 14)
                    Divider()
                }
            }
        }
    }

    // MARK: Plugins

    private var pluginCategories: [String] {
        Array(Set(plugins.compactMap(\.category))).sorted()
    }

    @ViewBuilder private var pluginsDiscover: some View {
        let shown = plugins.filter { plugin in
            (category == nil || plugin.category == category)
                && (query.isEmpty || plugin.title.localizedCaseInsensitiveContains(query) || plugin.description.localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                StoreSectionHeader(title: category?.capitalized ?? (query.isEmpty ? "Plugins" : "Results"), count: shown.count)
                Text("Plugins bundle skills and connectors for a job. AIM installs their skills and remote connectors; commands and sub-agents made for Claude Code are left out.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if plugins.isEmpty { loadingRow }
            LazyVGrid(columns: grid, spacing: 16) {
                ForEach(shown) { plugin in
                    StoreCard(title: plugin.title, subtitle: plugin.description,
                              footer: ["by " + (plugin.author ?? "Anthropic"), plugin.category?.capitalized].compactMap { $0 }.joined(separator: " · "),
                              installed: installedPlugins.contains { $0.id == plugin.id }, busy: busy.contains("p:" + plugin.id),
                              icon: { StoreIcon(symbol: StoreFormat.pluginIcon(plugin.category)) },
                              open: { detail = .plugin(plugin) }, install: { Task { await install(.plugin(plugin)) } })
                }
            }
            if query.isEmpty && !plugins.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    StoreSectionHeader(title: "Categories")
                    FlowRow(spacing: 10) {
                        ForEach(pluginCategories, id: \.self) { item in
                            StoreChip(title: item.capitalized, count: plugins.filter { $0.category == item }.count, selected: category == item) {
                                category = category == item ? nil : item
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var pluginsYours: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoreSectionHeader(title: "Your plugins", count: installedPlugins.count)
            if installedPlugins.isEmpty {
                Text("No plugin yet. Plugins add several skills and connectors at once.").font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(installedPlugins) { plugin in
                HStack(spacing: 16) {
                    StoreIcon(symbol: "puzzlepiece.extension", size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.title).font(.system(size: 15, weight: .medium))
                        Text("\(plugin.skills.count) skills · \(plugin.connectorIDs.count) connectors").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(plugin.installedAt.formatted(.relative(presentation: .named))).font(.system(size: 13)).foregroundStyle(.tertiary)
                    Button("Remove") { Task { await model.uninstallPlugin(plugin); await reloadLocal() } }.buttonStyle(.settings)
                }
                .padding(.vertical, 14)
                Divider()
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Loading the store…").foregroundStyle(.secondary) }
            .font(.system(size: 13)).padding(.vertical, 30).frame(maxWidth: .infinity)
    }

    // MARK: Data and actions

    private func isInstalled(_ skill: StoreSkill) -> Bool {
        installedSkills.contains { $0.origin == "store:\(skill.id)" || $0.name == skill.skillId || $0.name == skill.name }
    }

    private func isInstalled(_ connector: StoreConnector) -> Bool {
        connector.url != nil && servers.contains { $0.url == connector.url }
    }

    private func isInstalled(_ item: Detail) -> Bool {
        switch item {
        case .skill(let skill): isInstalled(skill)
        case .connector(let connector): isInstalled(connector)
        case .plugin(let plugin): installedPlugins.contains { $0.id == plugin.id }
        }
    }

    private func installedServer(_ item: Detail) -> MCPServerConfiguration? {
        guard case .connector(let connector) = item, let url = connector.url else { return nil }
        return servers.first { $0.url == url }
    }

    /// Same category first (as Claude's "Related connectors"), then the most popular.
    private func related(to item: Detail) -> [Detail] {
        switch item {
        case .connector(let connector):
            let same = CustomizeCatalog.connectors.filter { $0.id != connector.id && $0.category == connector.category }
            let others = CustomizeCatalog.connectors.filter { $0.id != connector.id && $0.category != connector.category && $0.featured }
            return (same + others).prefix(6).map { .connector($0) }
        case .skill(let skill):
            let category = CustomizeCatalog.category(of: skill)
            let sameOwner = popular.filter { $0.id != skill.id && $0.owner == skill.owner }
            let sameCategory = popular.filter { $0.id != skill.id && $0.owner != skill.owner && category != nil && CustomizeCatalog.category(of: $0) == category }
            return (sameOwner + sameCategory).prefix(6).map { .skill($0) }
        case .plugin(let plugin):
            return plugins.filter { $0.id != plugin.id && $0.category == plugin.category }.prefix(6).map { .plugin($0) }
        }
    }

    private func reloadLocal() async {
        installedSkills = SkillCatalog.discover(workspace: model.workspacePath, disabled: [])
        servers = (try? await model.mcpServerRepository.list()) ?? []
        installedPlugins = InstalledPlugins.all()
        for server in servers {
            switch await MCPServerManager.shared.status(of: server) {
            case .connected(let count): serverStatus[server.id] = "Connected · \(count) tools"
            case .failed: serverStatus[server.id] = "Needs attention"
            default: serverStatus[server.id] = MCPOAuth.storedTokens(serverID: server.id) != nil ? "Signed in" : nil
            }
        }
    }

    private func loadStore() async {
        do {
            async let top = store.skills(.allTime, page: 0)
            async let hot = store.skills(.trending, page: 0)
            popular = try await top
            trending = (try? await hot) ?? []
            categoryCounts = Dictionary(grouping: popular.compactMap { CustomizeCatalog.category(of: $0) }, by: { $0 }).mapValues(\.count)
            message = nil
        } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        plugins = (try? await store.plugins()) ?? []
    }

    private func loadMoreSkills() async {
        let next = skillPage + 1
        guard let more = try? await store.skills(sort == .trending ? .trending : .allTime, page: next), !more.isEmpty else { return }
        skillPage = next
        let known = Set(popular.map(\.id))
        if sort == .trending { trending += more.filter { !known.contains($0.id) } } else { popular += more.filter { !known.contains($0.id) } }
    }

    private func search() async {
        guard !query.isEmpty else { searchResults = []; if tab == .connectors { await loadRegistry(reset: true) }; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        switch tab {
        case .skills: searchResults = (try? await store.searchSkills(query)) ?? []
        case .connectors: await loadRegistry(reset: true)
        case .plugins: break
        }
    }

    private func loadRegistry(reset: Bool) async {
        guard let page = try? await store.searchRegistry(query, cursor: reset ? nil : registryCursor) else { return }
        registry = reset ? page.connectors : registry + page.connectors
        registryCursor = page.next
    }

    private func installSkill(_ skill: StoreSkill) async {
        guard !isInstalled(skill) else { return }
        busy.insert("s:" + skill.id)
        defer { busy.remove("s:" + skill.id) }
        do {
            try await store.install(skill)
            message = nil
            await reloadLocal()
        } catch { message = "\(skill.name): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }

    private func installConnector(_ connector: StoreConnector) async {
        guard !isInstalled(connector), !connector.soon else { return }
        if connector.auth == .token { tokenValue = ""; tokenFor = connector; return }
        busy.insert("c:" + connector.id)
        defer { busy.remove("c:" + connector.id) }
        do {
            try await model.installConnector(connector)
            message = nil
        } catch { message = "\(connector.name): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        await reloadLocal()
    }

    private func install(_ item: Detail) async {
        switch item {
        case .skill(let skill): await installSkill(skill)
        case .connector(let connector): await installConnector(connector)
        case .plugin(let plugin):
            busy.insert(item.id)
            defer { busy.remove(item.id) }
            do {
                let ignored = try await model.installPlugin(plugin)
                message = ignored.isEmpty ? nil : "\(plugin.title) installed. Not used by AIM: \(ignored.joined(separator: ", "))."
            } catch { message = "\(plugin.title): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            await reloadLocal()
        }
    }

    private func uninstall(_ item: Detail) async {
        switch item {
        case .skill(let skill):
            if let installed = installedSkills.first(where: { $0.origin == "store:\(skill.id)" || $0.name == skill.skillId }) {
                try? FileManager.default.trashItem(at: installed.directory, resultingItemURL: nil)
            }
        case .connector(let connector):
            if let server = servers.first(where: { $0.url == connector.url }) { await model.removeConnector(server) }
        case .plugin(let plugin):
            if let installed = installedPlugins.first(where: { $0.id == plugin.id }) { await model.uninstallPlugin(installed) }
        }
        await reloadLocal()
    }

    private func tokenSheet(_ connector: StoreConnector) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RemoteLogo(url: connector.logo, size: 40)
                Text("Connect \(connector.name)").font(.system(size: 17, weight: .semibold))
            }
            Text(connector.tokenHint ?? "This connector needs an access token. It is stored in the Keychain and sent only to \(connector.name).")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            SecureField("Token", text: $tokenValue).textFieldStyle(.settings)
            HStack {
                Spacer()
                Button("Cancel") { tokenFor = nil }.buttonStyle(.settings)
                Button("Connect") {
                    let token = tokenValue
                    tokenFor = nil
                    Task {
                        busy.insert("c:" + connector.id)
                        defer { busy.remove("c:" + connector.id) }
                        do { try await model.installConnector(connector, token: token) }
                        catch { message = "\(connector.name): \(error.localizedDescription)" }
                        await reloadLocal()
                    }
                }
                .buttonStyle(.settingsPrimary).disabled(tokenValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 460)
    }

    /// "Import a skill": a skill folder, a folder of skills, or a .zip.
    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a skill folder (with SKILL.md), a folder of skills, or a .zip"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "zip" {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("aim-import-" + UUID().uuidString)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", url.path, target.path]
                try process.run(); process.waitUntilExit()
                url = target
            }
            // A single skill folder: import it from its parent, by name.
            var names: Set<String>?
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path),
               let text = try? String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8),
               let parsed = SkillCatalog.parse(text) {
                names = [parsed.name]
                url = url.deletingLastPathComponent()
            } else if let only = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                        .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }),
                      SkillCatalog.scan(url, source: .global).isEmpty {
                url = only.deletingLastPathComponent()
            }
            let imported = try SkillCatalog.importSkills(from: url, names: names)
            message = imported.isEmpty ? "No new skill found there (a skill is a folder with a SKILL.md)." : nil
            scope = .yours
            Task { await reloadLocal() }
        } catch { message = error.localizedDescription }
    }

    private func createSkill(name: String, description: String, body: String) throws {
        guard let global = SkillCatalog.globalDirectory, SkillCatalog.isValidName(name) else { throw SkillError.invalidSkill }
        let folder = global.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw SkillError.invalidSkill }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oneLine = description.replacingOccurrences(of: "\n", with: " ")
        try "---\nname: \(name)\ndescription: \(oneLine)\n---\n\n\(body)\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        Task { await reloadLocal() }
    }
}

/// ⋯ on an installed skill: turn off/on, show in Finder, delete.
private struct SkillRowMenu: View {
    let skill: Skill
    let disabled: Bool
    let changed: () async -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
        }
        .buttonStyle(.aimHover(radius: 8, active: open))
        .aimMenu(isPresented: $open, alignment: .trailing) {
            AIMMenuItem(disabled ? "Turn on" : "Turn off", icon: disabled ? "power" : "poweroff") {
                var set = SkillPreferences.disabled
                if disabled { set.remove(skill.name) } else { set.insert(skill.name) }
                SkillPreferences.disabled = set
                Task { await changed() }
            }
            AIMMenuItem("Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([skill.directory]) }
            if skill.source == .global {
                AIMMenuDivider()
                AIMMenuItem("Delete", icon: "trash", destructive: true) {
                    try? FileManager.default.trashItem(at: skill.directory, resultingItemURL: nil)
                    Task { await changed() }
                }
            }
        }
    }
}

/// Sign in/out, test and remove for one connector.
private struct ConnectorRowActions: View {
    @Environment(AppModel.self) private var model
    let server: MCPServerConfiguration
    let changed: () async -> Void
    @State private var open = false
    @State private var editingPermissions = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
        }
        .buttonStyle(.aimHover(radius: 8, active: open))
        .aimMenu(isPresented: $open, alignment: .trailing) {
            if server.transport != .stdio && !server.secretNames.contains("AUTHORIZATION") {
                if MCPOAuth.storedTokens(serverID: server.id) == nil {
                    AIMMenuItem("Sign in…", icon: "person.badge.key") {
                        Task { try? await MCPOAuth.signIn(server: server); await MCPServerManager.shared.disconnect(server.id); await changed() }
                    }
                } else {
                    AIMMenuItem("Sign out", icon: "rectangle.portrait.and.arrow.right") {
                        MCPOAuth.signOut(serverID: server.id)
                        Task { await MCPServerManager.shared.disconnect(server.id); await changed() }
                    }
                }
            }
            AIMMenuItem("Action permissions…", icon: "checkmark.shield") { editingPermissions = true }
            AIMMenuDivider()
            AIMMenuItem("Remove", icon: "trash", destructive: true) { Task { await model.removeConnector(server); await changed() } }
        }
        .sheet(isPresented: $editingPermissions) {
            MCPActionPermissionsSheet(server: server) { updated in
                try await model.mcpServerRepository.save(updated); await MCPServerManager.shared.disconnect(server.id); editingPermissions = false; await changed()
            } cancel: { editingPermissions = false }
        }
    }
}
