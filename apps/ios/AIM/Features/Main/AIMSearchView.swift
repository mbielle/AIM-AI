import AIMCore
import Observation
import SwiftUI

@MainActor @Observable final class AIMSearchState {
    var query = ""
    var scrollID: String?
    let filters: AIMConversationFilters
    init(accountID: UUID) { filters = .init(accountID: accountID, surface: "search") }
}


/// Device-local preferences are deliberately scoped by account and surface.
@MainActor @Observable final class AIMConversationFilters {
    enum Kind: String, Codable, CaseIterable { case all, chat, code, agent }
    private struct Snapshot: Codable { var kind: Kind = .all; var unreadOnly = false; var deviceIDs: Set<String> = [] }
    private let key: String
    private let defaults: UserDefaults
    var kind: Kind { didSet { save() } }
    var unreadOnly: Bool { didSet { save() } }
    var deviceIDs: Set<String> { didSet { save() } }
    init(accountID: UUID, surface: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "aim.conversation-filters.\(accountID.uuidString.lowercased()).\(surface)"
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        kind = saved.kind; unreadOnly = saved.unreadOnly; deviceIDs = saved.deviceIDs
    }
    private func save() {
        if let data = try? JSONEncoder().encode(Snapshot(kind: kind, unreadOnly: unreadOnly, deviceIDs: deviceIDs)) { defaults.set(data, forKey: key) }
    }
    func includes(_ session: RemoteSession, status: ConversationActivityState) -> Bool {
        guard kind == .all || kind.rawValue == session.mode.rawValue else { return false }
        guard !unreadOnly || status == .unread else { return false }
        // Unknown provenance never masquerades as the current device.
        return deviceIDs.isEmpty || !(Set((session.executionDeviceIDs ?? []).map(AccountConversationIdentity.normalized)).intersection(Set(deviceIDs.map(AccountConversationIdentity.normalized)))).isEmpty
    }
}

struct AIMConversationFilterMenu: View {
    @Bindable var filters: AIMConversationFilters
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var machines: [RemoteMachine] = []
    var thisDeviceID: String? = nil
    var preparePresentation: () -> Void = {}
    @State private var showing = false
    @State private var measuredHeight: CGFloat = 330
    var body: some View {
        Button { preparePresentation(); showing = true } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: compact ? 14 : 19, weight: .medium))
                .frame(width: compact ? 30 : 44, height: compact ? 30 : 44).aimGlassCircle()
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary).tint(.primary)
            .accessibilityLabel("Filter conversations")
            .popover(isPresented: $showing, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                        ForEach(AIMConversationFilters.Kind.allCases, id: \.self) { kind in
                            Button { filters.kind = kind } label: {
                                HStack {
                                    Text(title(kind)); Spacer()
                                    if filters.kind == kind { Image(systemName: "checkmark") }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("conversation-filter-kind-\(kind.rawValue)")
                        }
                        Divider().padding(.vertical, 8)
                        Toggle("Unread only", isOn: $filters.unreadOnly).frame(minHeight: 44).tint(.green).accessibilityIdentifier("conversation-filter-unread")
                        if let thisDeviceID {
                            Divider().padding(.vertical, 8)
                            Text("Execution devices").font(.caption).foregroundStyle(.secondary)
                            device(String(localized: "This iPhone"), id: thisDeviceID).frame(minHeight: 44)
                            ForEach(machines) { machine in device(machine.name, id: machine.id).frame(minHeight: 44) }
                            Button("All devices") { filters.deviceIDs = [] }.frame(minHeight: 44).buttonStyle(.plain)
                        }
                    }.padding(20).background {
                        GeometryReader { proxy in Color.clear.preference(key: AIMFilterHeightKey.self, value: proxy.size.height) }
                    }
                }.frame(width: compact && !dynamicTypeSize.isAccessibilitySize ? 252 : 280)
                .frame(height: min(measuredHeight, max(180, min(480, UIScreen.main.bounds.height - 180))))
                .onPreferenceChange(AIMFilterHeightKey.self) { measuredHeight = $0 }
                    .font(.body).foregroundStyle(.primary).tint(.primary)
                    .presentationCompactAdaptation(.popover)
            }
            .aimBlocksBackgroundInteractions(showing)
    }
    private func title(_ kind: AIMConversationFilters.Kind) -> String {
        switch kind { case .all: String(localized: "All conversations"); case .chat: "Chat"; case .code: "Code"; case .agent: "Agent" }
    }
    private func device(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { filters.deviceIDs.contains(id) }, set: { enabled in
            if enabled { filters.deviceIDs.insert(id) } else { filters.deviceIDs.remove(id) }
        })).accessibilityIdentifier("conversation-filter-device-\(id)")
    }
}

struct AIMConversationStatusDot: View {
    let status: ConversationActivityState
    var body: some View {
        Group {
            if status == .idle { Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1.2) }
            else { Circle().fill(color) }
        }.frame(width: 8, height: 8).accessibilityLabel(label)
    }
    private var color: Color {
        switch status { case .running, .waiting: .green; case .unread: .blue; case .failed: .red; case .idle: .clear }
    }
    private var label: String {
        switch status {
        case .idle: String(localized: "Read")
        case .running: String(localized: "Generating")
        case .waiting: String(localized: "Request pending")
        case .unread: String(localized: "Unread response")
        case .failed: String(localized: "Last request failed")
        }
    }
}

struct AIMSearchView: View {
    @Bindable var state: AIMSearchState
    let safeBottom: CGFloat
    let sessions: [RemoteSession]
    let safeTop: CGFloat
    let machines: [RemoteMachine]
    let thisDeviceID: String
    let status: (RemoteSession) -> ConversationActivityState
    let openMenu: () -> Void
    let results: (String) -> [RemoteSession]
    let openSession: (RemoteSession) -> Void
    @FocusState private var searchFocused: Bool
    @State private var bottomOcclusion: CGFloat = 90
    private var matches: [RemoteSession] { results(state.query).filter { state.filters.includes($0, status: status($0)) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    if sessions.isEmpty {
                        ContentUnavailableView("search.empty.title", systemImage: "bubble.left.and.bubble.right", description: Text("search.empty.body"))
                    } else if matches.isEmpty {
                        ContentUnavailableView.search(text: state.query)
                    }
                    ForEach(matches) { session in
                        resultRow(session).id(session.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.top, safeTop + 76)
                .padding(.bottom, bottomOcclusion + 16)
            }
            .scrollPosition(id: $state.scrollID, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
            AIMConversationKeyboardDock(safeBottom: safeBottom, occlusion: $bottomOcclusion) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        TextField("search.placeholder", text: $state.query)
                            .font(.system(.body))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($searchFocused).submitLabel(.search)
                            .accessibilityIdentifier("conversation-search-field")
                        if !state.query.isEmpty {
                            Button { state.query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                            }.accessibilityLabel(Text("search.clear"))
                        }
                    }
                    .padding(.horizontal, 16).frame(minHeight: 52).aimGlassCapsule()
                    Button { searchFocused = false; openMenu() } label: {
                        Image(systemName: "xmark").font(.system(size: 22, weight: .medium)).frame(width: 52, height: 52).aimGlassCircle()
                    }.accessibilityLabel("Close search").accessibilityIdentifier("close-conversation-search")
                }
                .buttonStyle(.plain).foregroundStyle(.primary).padding(.horizontal, 16)
            }
            HStack {
            Button { searchFocused = false; openMenu() } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44).aimGlassCircle()
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityLabel(Text("sidebar.open"))
            Spacer()
            AIMConversationFilterMenu(filters: state.filters, machines: machines, thisDeviceID: thisDeviceID,
                preparePresentation: { searchFocused = false })
                .accessibilityIdentifier("search-conversation-filter")
            }.padding(.horizontal, 16).padding(.top, safeTop + 10)
        }
        .background(Color(uiColor: .systemBackground)).tint(.primary)
        .accessibilityElement(children: .contain).accessibilityIdentifier("search-screen")
        .onAppear { searchFocused = true }
    }

    private func resultRow(_ session: RemoteSession) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if session.mode == .agent { Image("LucideBot").renderingMode(.template).resizable().scaledToFit() }
                else { Image(systemName: icon(for: session.mode)).font(.system(size: 21)) }
            }.foregroundStyle(.secondary).frame(width: 26, height: 28)
            AIMConversationStatusDot(status: status(session))
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.body).lineLimit(1)
                if machines.count > 1 {
                    let names = machines.filter { machine in (session.executionDeviceIDs ?? []).contains { AccountConversationIdentity.matches($0, machine.id) } }.map(\.name)
                    if !names.isEmpty { Text(names.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
        .aimSwipeSafeTap { searchFocused = false; openSession(session) }
        .accessibilityIdentifier("search-result-\(session.id)")
    }
    private func icon(for mode: RemoteMode) -> String {
        switch mode { case .chat: "bubble.left"; case .code: "chevron.left.forwardslash.chevron.right"; case .agent: "cpu" }
    }
    private func modeName(_ mode: RemoteMode) -> LocalizedStringKey {
        switch mode { case .chat: "sidebar.chats"; case .code: "Code"; case .agent: "Agent" }
    }
}

private struct AIMFilterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 330
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
