import AIMApplication
import AIMMacPlatform
import Charts
import SwiftUI

/// A store item's page (as in Claude): it replaces the store in the main area, with the
/// presentation on the left, facts on the right, tools or files, and related items below.
struct CustomizeDetailPage: View {
    let detail: CustomizeView.Detail
    let backTitle: String
    let installed: Bool
    /// The saved server when this connector is installed (to list its tools).
    var installedServer: MCPServerConfiguration?
    let busy: Bool
    let related: [CustomizeView.Detail]
    let isInstalled: (CustomizeView.Detail) -> Bool
    let install: (CustomizeView.Detail) -> Void
    let remove: () -> Void
    let open: (CustomizeView.Detail) -> Void
    let back: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var markdown: String?
    @State private var files: [String] = []
    @State private var facts: CustomizeStore.RepositoryFacts?
    @State private var contents: CustomizeStore.PluginContents?
    @State private var tools: [String] = []
    @State private var toolsNote: String?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) { HStack(spacing: 8) { Image(systemName: "arrow.left"); Text(backTitle) }.font(.system(size: 15)) }
                .buttonStyle(TextLinkStyle()).padding(.bottom, 26)
            header.padding(.bottom, 26)
            Divider().padding(.bottom, 30)
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 30) { mainColumn }
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 26) { factsColumn }
                    .frame(width: 270, alignment: .leading)
            }
            if !related.isEmpty {
                Divider().padding(.vertical, 40)
                Text(relatedTitle).font(.system(size: 26, weight: .regular)).padding(.bottom, 20)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(related.prefix(6)) { item in relatedCard(item) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: markdown != nil)
        .animation(.easeOut(duration: 0.2), value: files.count)
        .animation(.easeOut(duration: 0.2), value: facts != nil)
        .task(id: detail.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 26) {
            bigIcon
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(title).font(AIMTypography.title(44, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                    if verified { Image(systemName: "checkmark.seal").font(.system(size: 22)).foregroundStyle(.secondary) }
                }
                Text(tagline).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 24)
            primaryButton
        }
    }

    @ViewBuilder private var bigIcon: some View {
        switch detail {
        case .connector(let connector): RemoteLogo(url: connector.logo, fallback: "powerplug", size: 96)
        case .skill(let skill): RemoteLogo(url: CustomizeCatalog.ownerAvatar(skill.owner), fallback: "scroll", size: 96)
        case .plugin(let plugin): RemoteLogo(url: CustomizeCatalog.ownerAvatar(plugin.repository.split(separator: "/").first.map(String.init) ?? ""),
                                             fallback: StoreFormat.pluginIcon(plugin.category), size: 96)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if isSoon {
            Text("Coming soon").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).frame(height: 46).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else if installed {
            HStack(spacing: 10) {
                Label(addedTitle, systemImage: "checkmark").font(.system(size: 15, weight: .medium)).foregroundStyle(.green)
                Button("Remove", role: .destructive, action: remove).buttonStyle(.settingsDestructive)
            }
        } else {
            Button { install(detail) } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(actionTitle)
                }
                .font(.system(size: 16, weight: .medium)).foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 22).frame(height: 48)
                .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain).disabled(busy)
        }
    }

    // MARK: Main column

    @ViewBuilder private var mainColumn: some View {
        if about != tagline {
            Text(about).font(.system(size: 16)).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        switch detail {
        case .connector(let connector):
            if let features = CustomizeCatalog.connectorDetails[connector.id]?.features {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Key features").font(.system(size: 16, weight: .semibold))
                    ForEach(features, id: \.self) { feature in
                        HStack(alignment: .firstTextBaseline, spacing: 10) { Text("•"); Text(feature) }.font(.system(size: 15.5))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Tools").font(.system(size: 26, weight: .regular))
                if tools.isEmpty {
                    Text(toolsNote ?? "The tools appear here once the connector is connected.").font(.system(size: 14)).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(tools, id: \.self) { tool in
                            Text(tool).font(.system(size: 14, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            notice("Only use connectors from developers you trust. AIM does not control the tools a developer makes available and cannot guarantee they work as described or won't change. AIM allows only reviewed reads without confirmation. Changes, sends and unknown actions require confirmation. Server annotations alone are never proof, and results remain external data, never instructions.")
        case .skill:
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What's inside").font(.system(size: 16, weight: .semibold))
                    FlowRow(spacing: 8) {
                        ForEach(files.prefix(24), id: \.self) { file in
                            Label(file, systemImage: Self.isScript(file) ? "terminal" : file.hasSuffix(".md") ? "doc.text" : "doc")
                                .font(.system(size: 12.5, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
            }
            if let markdown {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Instructions").font(.system(size: 26, weight: .regular))
                    NativeMarkdownView(source: Self.body(markdown), appearance: ConversationAppearance(typeface: .system, textSize: 14))
                        .padding(22)
                        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                }
            } else if loadError == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Instructions").font(.system(size: 26, weight: .regular))
                    LoadingBlock(height: 320)
                }
            }
            notice(files.contains(where: Self.isScript)
                   ? "This skill includes scripts. They never run on their own: the Agent runs them only through its commands, which ask for your approval. Install skills from authors you trust."
                   : "Skills are instructions and reference files: AIM reads them when a task matches. Install skills from authors you trust.")
        case .plugin:
            if let contents {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Included").font(.system(size: 26, weight: .regular))
                    includedRow("Skills", icon: "scroll", values: contents.skillFolders.map { String($0.split(separator: "/").last ?? "") })
                    includedRow("Connectors", icon: "powerplug", values: contents.servers.map(\.name))
                    if !contents.ignored.isEmpty {
                        includedRow("Not used by AIM", icon: "minus.circle", values: contents.ignored.map { $0 + " (Claude Code)" })
                    }
                }
            } else if loadError == nil {
                LoadingBlock(height: 160)
            }
        }
        if let loadError { SettingsNotice(loadError, tone: .warning) }
    }

    private func includedRow(_ title: String, icon: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
            if values.isEmpty { Text("None").font(.system(size: 13.5)).foregroundStyle(.secondary) }
            else {
                FlowRow(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        Text(value).font(.system(size: 13.5)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 14.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }

    // MARK: Facts column

    @ViewBuilder private var factsColumn: some View {
        switch detail {
        case .connector(let connector):
            fact("Developed by") { Text(connector.publisher).font(.system(size: 15)) }
            fact("Categories") { chips([connector.category]) }
            fact("Connection") {
                Text(connector.auth == .oauth ? "Your \(connector.publisher) account" : connector.auth == .token ? "Access token" : "Not needed")
                    .font(.system(size: 15))
            }
            if let url = connector.url {
                fact("Connector URL") { Text(url).font(.system(size: 13.5, design: .monospaced)).textSelection(.enabled) }
            }
            if let docs = CustomizeCatalog.connectorDetails[connector.id]?.docs, let link = URL(string: docs) {
                fact("More info") { Link(destination: link) { linkLabel("Documentation") } }
            }
        case .skill(let skill):
            fact("Developed by") {
                Link(destination: URL(string: "https://github.com/\(skill.owner)")!) { linkLabel(StoreFormat.publisher(skill.source)) }
            }
            if let installs = skill.installs {
                fact("Installs") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(installs.formatted()).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        if let weekly = skill.weeklyInstalls, weekly.count > 1 { trend(weekly) }
                    }
                }
            }
            if let facts {
                fact("GitHub") {
                    HStack(spacing: 14) {
                        Label(facts.stars.formatted(), systemImage: "star").font(.system(size: 15)).monospacedDigit()
                        Label(facts.forks.formatted(), systemImage: "arrow.triangle.branch").font(.system(size: 15)).monospacedDigit()
                    }
                }
                if let license = facts.license { fact("License") { Text(license).font(.system(size: 15)) } }
                if let pushed = facts.pushedAt { fact("Updated") { Text(pushed.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 15)) } }
            }
            if let category = CustomizeCatalog.category(of: skill) { fact("Category") { chips([category]) } }
            if !files.isEmpty {
                fact("Files") {
                    Text("\(files.count) files" + (files.contains(where: Self.isScript) ? " · includes scripts" : "")).font(.system(size: 15))
                }
            }
            fact("More info") { Link(destination: URL(string: "https://github.com/\(skill.source)")!) { linkLabel("Repository") } }
        case .plugin(let plugin):
            fact("Developed by") { Text(plugin.author ?? "Anthropic").font(.system(size: 15)) }
            if let category = plugin.category { fact("Category") { chips([category.capitalized]) } }
            fact("Marketplace") { Text(plugin.marketplace).font(.system(size: 14, design: .monospaced)) }
            if let facts { fact("GitHub") { Label(facts.stars.formatted(), systemImage: "star").font(.system(size: 15)) } }
            if let link = URL(string: plugin.homepage ?? "https://github.com/\(plugin.repository)") {
                fact("More info") { Link(destination: link) { linkLabel("Source") } }
            }
        }
    }

    private func fact<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.system(size: 12, weight: .medium)).kerning(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    private func chips(_ values: [String]) -> some View {
        FlowRow(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(value).font(.system(size: 14)).padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
            }
        }
    }

    private func linkLabel(_ text: String) -> some View {
        HStack(spacing: 4) { Text(text).underline(); Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
            .font(.system(size: 15)).foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.86))
    }

    private func trend(_ weekly: [Int]) -> some View {
        Chart(Array(weekly.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("Week", point.offset), y: .value("Installs", point.element))
                .foregroundStyle(Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.15)).interpolationMethod(.monotone)
            LineMark(x: .value("Week", point.offset), y: .value("Installs", point.element))
                .foregroundStyle(Color(red: 0.25, green: 0.47, blue: 0.85)).interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(height: 44)
        .help("Installs per week, last \(weekly.count) weeks")
    }

    private func relatedCard(_ item: CustomizeView.Detail) -> some View {
        StoreCard(title: Self.title(item), verified: { if case .connector = item { return true }; return false }(),
                  subtitle: Self.subtitle(item), footer: Self.footer(item), installed: isInstalled(item), soon: Self.soon(item),
                  icon: { Self.icon(item) }, open: { open(item) }, install: { install(item) })
    }

    // MARK: Text

    private var title: String { Self.title(detail) }
    private var verified: Bool { if case .connector(let connector) = detail { return connector.category != "Registry" }; return false }
    private var isSoon: Bool { Self.soon(detail) }

    private var tagline: String {
        switch detail {
        case .connector(let connector): connector.description
        case .skill(let skill): skill.description ?? "A skill by \(StoreFormat.publisher(skill.source))"
        case .plugin(let plugin): "A plugin by \(plugin.author ?? "Anthropic")"
        }
    }

    private var about: String {
        switch detail {
        case .connector(let connector): CustomizeCatalog.connectorDetails[connector.id]?.about ?? connector.description
        case .skill(let skill): facts?.description.flatMap { $0 == skill.description ? nil : "From the \(skill.source) repository: " + $0 } ?? skill.description ?? "A skill teaches AIM how to do a task: instructions, and sometimes scripts and reference files, used when the task matches."
        case .plugin(let plugin): plugin.description
        }
    }

    private var actionTitle: String {
        switch detail {
        case .connector(let connector): connector.auth == .oauth ? "Connect to AIM" : "Add to AIM"
        default: "Add to AIM"
        }
    }

    private var addedTitle: String { if case .connector = detail { return "Connected" }; return "Added" }

    private var relatedTitle: String {
        switch detail { case .connector: "Related connectors"; case .skill: "Related skills"; case .plugin: "Related plugins" }
    }

    static func title(_ item: CustomizeView.Detail) -> String {
        switch item { case .connector(let c): c.name; case .skill(let s): s.name; case .plugin(let p): p.title }
    }

    static func subtitle(_ item: CustomizeView.Detail) -> String {
        switch item { case .connector(let c): c.description; case .skill(let s): s.description ?? " "; case .plugin(let p): p.description }
    }

    static func footer(_ item: CustomizeView.Detail) -> String {
        switch item {
        case .connector(let c): "by " + c.publisher
        case .skill(let s): (["by " + StoreFormat.publisher(s.source), StoreFormat.installs(s.installs)].compactMap { $0 }).joined(separator: " · ")
        case .plugin(let p): "by " + (p.author ?? "Anthropic")
        }
    }

    static func soon(_ item: CustomizeView.Detail) -> Bool { if case .connector(let c) = item { return c.soon }; return false }

    @ViewBuilder static func icon(_ item: CustomizeView.Detail) -> some View {
        switch item {
        case .connector(let c): RemoteLogo(url: c.logo, fallback: "powerplug", size: 48)
        case .skill(let s): RemoteLogo(url: CustomizeCatalog.ownerAvatar(s.owner), fallback: "scroll", size: 48)
        case .plugin(let p): StoreIcon(symbol: StoreFormat.pluginIcon(p.category))
        }
    }

    static func isScript(_ file: String) -> Bool {
        ["py", "sh", "js", "ts", "rb", "pl", "bash", "zsh"].contains((file as NSString).pathExtension.lowercased())
    }

    /// SKILL.md without its front matter.
    static func body(_ text: String) -> String {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Loading

    private func load() async {
        let store = CustomizeStore.shared
        switch detail {
        case .skill(let skill):
            async let factsTask = store.repositoryFacts(skill.source)
            async let filesTask = store.skillFiles(skill)
            do { markdown = try await store.skillMarkdown(skill).text }
            catch { loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            facts = await factsTask
            files = await filesTask
        case .plugin(let plugin):
            async let factsTask = store.repositoryFacts(plugin.repository)
            do { contents = try await store.contents(plugin) }
            catch { loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            facts = await factsTask
        case .connector(let connector):
            await loadTools(connector)
        }
    }

    /// Tools come from the server itself: right away for connectors without sign-in, after
    /// connecting for the others.
    private func loadTools(_ connector: StoreConnector) async {
        guard let url = connector.url else { toolsNote = "Not available yet."; return }
        let configuration = MCPServerConfiguration(name: "store-preview", transport: url.hasSuffix("/sse") ? .sse : .http, url: url)
        if connector.auth == .none || installedServer != nil {
            do {
                tools = try await MCPServerManager.shared.tools(of: installedServer ?? configuration).map(\.name).sorted()
                if installedServer == nil { await MCPServerManager.shared.disconnect(configuration.id) }
            } catch {
                toolsNote = installedServer != nil ? "Sign in to see this connector's tools." : "The tools could not be listed right now."
            }
        }
    }
}

/// Text that darkens and grows slightly on hover ("View all", "Back"): no box around it.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TextLink(configuration: configuration) }

    private struct TextLink: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovered ? Color.primary : Color.primary.opacity(0.72))
                .scaleEffect(configuration.isPressed ? 0.98 : hovered ? 1.03 : 1, anchor: .leading)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.14), value: hovered)
        }
    }
}

/// "Create a skill": name, when to use it, and the instructions.
struct CreateSkillSheet: View {
    let save: (String, String, String) throws -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a skill").font(.system(size: 20, weight: .semibold))
            Text("A skill teaches AIM how you do a task. AIM reads its description to know when to use it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 13, weight: .medium))
                TextField("weekly-report", text: $name).textFieldStyle(.settings)
                Text("Lowercase letters, digits and hyphens.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("When to use it").font(.system(size: 13, weight: .medium))
                TextField("Writes my weekly report from the week's notes and tasks", text: $description).textFieldStyle(.settings)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.system(size: 13, weight: .medium))
                TextEditor(text: $instructions).font(.system(size: 13)).scrollContentBackground(.hidden).focusEffectDisabled()
                    .padding(8).frame(minHeight: 200)
                    .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.settings)
                Button("Create") {
                    do { try save(name.trimmingCharacters(in: .whitespaces), description, instructions) }
                    catch { self.error = "Choose another name (letters, digits, hyphens; not already used)." }
                }
                .buttonStyle(.settingsPrimary)
                .disabled(!SkillCatalog.isValidName(name.trimmingCharacters(in: .whitespaces))
                          || description.trimmingCharacters(in: .whitespaces).isEmpty
                          || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 560)
    }
}
