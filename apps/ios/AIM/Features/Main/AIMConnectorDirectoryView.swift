import AIMCore
import Observation
import SwiftUI

struct AIMConnectorDirectoryRemoteConnection: Identifiable {
    let id: String
    let name: String
    let identity: String
    let status: String
    init(_ descriptor: ConnectorDescriptor, available: Bool) {
        id = descriptor.id.uuidString; name = descriptor.name; identity = descriptor.identity
        let label: String = switch descriptor.status {
        case .connected: "Connected"
        case .saved: "Saved"
        case .disabled: "Disabled"
        case .unavailable: "Unavailable"
        }
        status = (available ? label : "Mac unavailable") + " · Selected Mac" + (descriptor.toolCount.map { " · \($0) actions" } ?? "")
    }
}

@MainActor @Observable final class AIMConnectorDirectoryStore {
    var webAccounts: [AIMConnector] = []
    var registry: [PortableConnector] = []
    var nextCursor: String?
    var loading = false
    var error: String?
    private var generation = UUID()
    private var loadedQuery: String?
    var catalogue: [PortableConnector] { ConnectorRegistry.merged(curated: ConnectorCatalog.connectors, discovered: registry) }

    func loadAccounts(_ service: (any CloudContentServicing)?) async {
        guard let service else { return }
        webAccounts = []
        do { webAccounts = try await service.loadConnectors() }
        catch { self.error = "Web accounts could not be refreshed. Existing connections are preserved." }
    }

    func search(_ query: String, loadMore: Bool = false) async {
        if loadMore && (loading || nextCursor == nil || loadedQuery != query) { return }
        let token = UUID(); generation = token
        loading = true; error = nil
        let cursor = loadMore ? nextCursor : nil
        if !loadMore { registry = []; nextCursor = nil; loadedQuery = query }
        defer { if generation == token { loading = false } }
        do {
            let (data, response) = try await AIMManagedNetworkSession.shared.data(from: ConnectorRegistry.requestURL(query: query, cursor: cursor))
            guard generation == token, !Task.isCancelled else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_000_000 else { throw URLError(.badServerResponse) }
            let page = try ConnectorRegistry.decode(data)
            registry = ConnectorRegistry.merged(curated: loadMore ? registry : [], discovered: page.connectors)
            nextCursor = page.nextCursor
        } catch is CancellationError { } catch {
            if generation == token { self.error = "The MCP registry is unavailable. The known catalogue remains available." }
        }
    }
}

/// Same directory in Settings and Personalization; account origins stay explicit.
struct AIMConnectorDirectoryView: View {
    let connectors: AIMWebConnectorStore
    var cloud: (any CloudContentServicing)? = nil
    var remote: [AIMConnectorDirectoryRemoteConnection] = []
    let open: (SettingsDestination) -> Void
    let openWebAccounts: (String?) -> Void
    @State private var store = AIMConnectorDirectoryStore()
    @State private var query = ""

    private var catalogue: [PortableConnector] {
        store.catalogue.filter { query.isEmpty || [$0.name, $0.category, $0.publisher, $0.description].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    var body: some View {
        AIMSettingsForm {
            Section {
                AIMSettingsAction(title: "Permissions", icon: "checkmark.shield", value: "Verified reads") { open(.connectorPermissions) }
            }
            if cloud != nil {
                Section {
                    ForEach(store.webAccounts) { account in
                        Button { openWebAccounts(account.id) } label: {
                            HStack(spacing: 12) {
                                AIMBrandLogo(identity: account.type)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.productName).foregroundStyle(.primary)
                                    Text(account.isActive ? "Active · Web account" : "Disabled · Web account").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.buttonStyle(AIMScrollSafeButtonStyle()).accessibilityIdentifier("web-account-row-" + account.id)
                    }
                    AIMSettingsAction(title: "Manage web accounts", icon: "person.crop.circle", action: { openWebAccounts(nil) })
                } header: { Text("Web accounts") } footer: { Text("These connections belong to the web account. They do not grant access to this iPhone or the selected Mac.") }
            }
            Section {
                ForEach(connectors.servers) { server in
                    Button { open(.connectorAccount(server.id)) } label: {
                        HStack(spacing: 12) {
                            AIMBrandLogo(identity: server.connectorID ?? server.name)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.displayName).foregroundStyle(.primary)
                                Text(!server.enabled ? "Disabled · This iPhone" : (connectors.loadedServerID == server.id ? "Connected · This iPhone" : "Saved · This iPhone")).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }.buttonStyle(AIMScrollSafeButtonStyle())
                }
                AIMSettingsAction(title: "Add HTTPS connector", icon: "plus") { connectors.draftConnector = nil; open(.newConnector) }
            } header: { Text("This iPhone") }
            Section {
                ForEach(remote) { connection in
                    HStack(spacing: 12) {
                        AIMBrandLogo(identity: connection.identity)
                        VStack(alignment: .leading, spacing: 3) { Text(connection.name); Text(connection.status).font(.footnote).foregroundStyle(.secondary) }
                    }.frame(minHeight: 44)
                }
                AIMSettingsAction(title: "Manage selected Mac", icon: "desktopcomputer") { open(.page(.selectedMac)) }
            } header: { Text("Selected Mac") } footer: { Text("Mac connections execute on that Mac and keep their credentials there.") }
            Section {
                TextField("Search connectors", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                ForEach(catalogue) { connector in
                    Button { open(.connector(connector)) } label: {
                        HStack(spacing: 12) {
                            AIMBrandLogo(identity: connector.id, fallbackURL: connector.logo.flatMap(URL.init(string:)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connector.name).foregroundStyle(.primary)
                                Text(connector.category + " · " + (connector.supportsIPhone ? "This iPhone" : (connector.soon ? "Unavailable" : "Mac required"))).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(AIMScrollSafeButtonStyle())
                }
                if store.loading { ProgressView().frame(maxWidth: .infinity) }
                if store.nextCursor != nil { Button("More from the MCP registry") { Task { await store.search(query, loadMore: true) } }.disabled(store.loading) }
            } header: { Text("Catalogue") } footer: { Text("Community registry entries are discovery results. Review their publisher and permissions before connecting.") }
            if let error = store.error { AIMSettingsMessage(text: error) }
        }
        .task { AIMLogoImageCache.shared.prewarmKnown(); await store.loadAccounts(cloud) }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); await store.search(query) } catch { }
        }
        .accessibilityIdentifier("shared-connector-directory")
    }
}
