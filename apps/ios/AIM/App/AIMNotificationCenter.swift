import AIMCore
import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable final class AIMNotificationCenter {
    static let shared = AIMNotificationCenter()
    var status = "Not configured"
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingConversation: UUID?
    var attention = ConversationAttention()
    var arrivalRevision = 0
    private var hapticTask: Task<Void, Never>?
    var notice: String?
    var noticeConversation: UUID?
    private let defaults: UserDefaults
    private let registerRemote: @MainActor () -> Void
    private let unregisterRemote: @MainActor () -> Void
    private let authorize: @MainActor () async throws -> Bool
    private let readAuthorization: @MainActor () async -> UNAuthorizationStatus
    private var service: (any AccountNotificationServicing)?
    private var accountID: UUID?
    private var installation = UUID()
    private var token: String?
    private var viewed: UUID?
    private var foreground = true
    private var concealed = false
    private var heartbeat: Task<Void, Never>?
    private var seenEvents: Set<UUID> = []
    private var seenOrder: [UUID] = []
    private var eventCursor: AccountNotificationCursor?
    private var continuationCursor: AccountNotificationCursor?
    private var polling = false
    private var registrationGeneration = 0
    private var preferenceGeneration = 0
    private var needsRegistrationSync = false
    private var syncingRegistration = false
    private var launchNotification: (account: UUID, conversation: UUID, event: UUID?)?

    init(defaults: UserDefaults = .standard,
         registerRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         unregisterRemote: @escaping @MainActor () -> Void = { UIApplication.shared.unregisterForRemoteNotifications() },
         authorize: @escaping @MainActor () async throws -> Bool = { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) },
         readAuthorization: @escaping @MainActor () async -> UNAuthorizationStatus = { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }) {
        self.defaults = defaults; self.registerRemote = registerRemote; self.unregisterRemote = unregisterRemote
        self.authorize = authorize; self.readAuthorization = readAuthorization
    }
    private var attentionKey: String? { accountID.map { "aim.attention.v1." + $0.uuidString.lowercased() } }
    private func saveAttention() {
        if let key = attentionKey, let data = try? JSONEncoder().encode(attention) { defaults.set(data, forKey: key) }
    }
    func consult(_ conversation: UUID) { attention.consult(conversation); saveAttention() }
    func reconcileAttention(_ values: [(RemoteSession, ConversationActivityState)], visible: UUID?) {
        for (session, state) in values {
            guard !session.readState.blocksReading, let id = UUID(uuidString: session.id) else { continue }
            let kind: ConversationAttention.Kind?
            switch state { case .failed: kind = .failure; case .waiting: kind = .approval; case .unread: kind = .response; default: kind = nil }
            if session.pendingApproval == nil && state != .waiting { attention.resolveApproval(id) }
            if state == .idle, session.latestResponseVersion != nil { attention.acknowledgeResponse(id) }
            if let kind {
                attention.record(.init(conversation: id, version: session.id + ":" + (session.latestResponseVersion?.id ?? String(session.updatedAt.timeIntervalSince1970)) + ":" + kind.rawValue, kind: kind))
            }
            if visible == id { attention.consult(id) }
        }
        saveAttention()
    }
    private func recordAttention(id: UUID, event: UUID, kind: AIMNotificationCategory, live: Bool) {
        let category: ConversationAttention.Kind = kind == .failure ? .failure : [.approval, .question].contains(kind) ? .approval : .response
        attention.record(.init(conversation: id, version: event.uuidString, kind: category))
        if viewed == id && foreground && !concealed { attention.consult(id) }
        saveAttention()
        guard live, foreground, !concealed, viewed != id, hapticTask == nil else { return }
        hapticTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { self.hapticTask = nil }
            guard self.foreground, !self.concealed else { return }
            self.arrivalRevision += 1
            AIMHaptics.selection()
        }
    }
    private var enabled: Bool { defaults.bool(forKey: "aim.notifications.enabled") }
    var categories: [AIMNotificationCategory] {
        AIMNotificationCategory.allCases.filter { defaults.object(forKey: "aim.notifications." + $0.rawValue) as? Bool ?? true }
    }
    private func unregisterKey(_ owner: UUID) -> String { "aim.push.pending-unregister." + owner.uuidString }
    private func cursorKey(_ owner: UUID) -> String { "aim.push.cursor." + owner.uuidString }
    private func seenKey(_ owner: UUID) -> String { "aim.push.seen." + owner.uuidString }
    private func pendingUnregistration(_ owner: UUID) -> UUID? {
        defaults.string(forKey: unregisterKey(owner)).flatMap(UUID.init(uuidString:))
    }
    private func remember(_ event: UUID, persist: Bool = true) {
        guard seenEvents.insert(event).inserted else { return }
        seenOrder.append(event)
        if seenOrder.count > 1000 { seenEvents.remove(seenOrder.removeFirst()) }
        if persist { persistSeen() }
    }
    private func persistSeen() {
        if let owner = accountID { defaults.set(seenOrder.map(\.uuidString), forKey: seenKey(owner)) }
    }
    func bind(accountID: UUID, service: (any AccountNotificationServicing)?) async {
        if self.accountID != accountID {
            pendingConversation = nil; notice = nil; noticeConversation = nil; continuationCursor = nil
            seenOrder = (defaults.stringArray(forKey: seenKey(accountID)) ?? []).compactMap(UUID.init(uuidString:))
            seenEvents = Set(seenOrder)
            eventCursor = defaults.data(forKey: cursorKey(accountID)).flatMap { try? JSONDecoder().decode(AccountNotificationCursor.self, from: $0) }
        }
        if self.accountID != accountID {
            attention = defaults.data(forKey: "aim.attention.v1." + accountID.uuidString.lowercased()).flatMap { try? JSONDecoder().decode(ConversationAttention.self, from: $0) } ?? .init()
        }
        self.accountID = accountID; self.service = service; registrationGeneration += 1
        if let launchNotification {
            if launchNotification.account == accountID {
                pendingConversation = launchNotification.conversation
                if let event = launchNotification.event { remember(event) }
            }
            self.launchNotification = nil
        }
        let key = "aim.push.installation." + accountID.uuidString
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) { installation = id }
        else { installation = UUID(); defaults.set(installation.uuidString, forKey: key) }
        needsRegistrationSync = enabled || pendingUnregistration(accountID) != nil
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, let self else { return }
                await self.synchronizeRegistration()
                await self.presence(foreground: self.foreground, conversation: self.viewed, concealed: self.concealed)
                await self.pollEvents()
            }
        }
        if service != nil, enabled { registerRemote() }
        await synchronizeRegistration()
    }
    func receiveToken(_ data: Data) async { token = data.map { String(format: "%02x", $0) }.joined(); await updateRegistration() }
    func refreshAuthorization() async { authorizationStatus = await readAuthorization() }
    func requestEnabled(_ requested: Bool) async {
        preferenceGeneration += 1
        let request = preferenceGeneration
        if !requested {
            // Persist the user's choice and stop local registration before any fallible network operation.
            defaults.set(false, forKey: "aim.notifications.enabled")
            unregisterRemote(); notice = nil; noticeConversation = nil; status = "Disabled"
            if let owner = accountID { defaults.set(installation.uuidString, forKey: unregisterKey(owner)) }
            await updateRegistration()
            return
        }
        do {
            let permitted = try await authorize()
            await refreshAuthorization()
            guard preferenceGeneration == request else { return }
            defaults.set(permitted, forKey: "aim.notifications.enabled")
            if permitted { registerRemote(); await updateRegistration() }
            else { await requestEnabled(false); status = "Disabled in iOS Settings" }
        } catch {
            await refreshAuthorization()
            if preferenceGeneration == request { status = "Could not update notifications. Try again." }
        }
    }
    func updateRegistration() async {
        registrationGeneration += 1; needsRegistrationSync = true
        await synchronizeRegistration()
    }
    // Serializes preference/token/category changes across awaits; a stale unregister cannot win over re-enabling.
    func synchronizeRegistration() async {
        guard !syncingRegistration else { return }
        syncingRegistration = true; defer { syncingRegistration = false }
        while needsRegistrationSync {
            guard let owner = accountID, let service else { return }
            let generation = registrationGeneration, currentInstallation = installation, desired = enabled
            let pending = pendingUnregistration(owner)
            if !desired && pending == nil { needsRegistrationSync = false; return }
            if desired && token == nil { status = "Waiting for Apple registration"; return }
            do {
                if desired, let token {
                    let environment = Bundle.main.object(forInfoDictionaryKey: "AIMAPNsEnvironment") as? String ?? "sandbox"
                    try await service.register(installation: currentInstallation, token: token,
                        topic: Bundle.main.bundleIdentifier ?? "com.aimai.ios", environment: environment, categories: categories)
                } else if let pending {
                    try await service.unregister(installation: pending)
                }
                guard accountID == owner, registrationGeneration == generation else { continue }
                defaults.removeObject(forKey: unregisterKey(owner))
                needsRegistrationSync = false; status = desired ? "Registered with AIM" : "Disabled"
                if desired { await presence(foreground: foreground, conversation: viewed, concealed: concealed) }
            } catch {
                guard accountID == owner, registrationGeneration == generation else { continue }
                status = desired ? "AIM notifications need the server and Apple push configuration." : "Disabled on this iPhone. Server update pending."
                return // Keep retry intent for heartbeat/reconnection; never roll back the local choice.
            }
        }
    }
    func presence(foreground: Bool, conversation: UUID?, concealed: Bool) async {
        self.foreground = foreground; viewed = conversation; self.concealed = concealed
        if foreground, !concealed, let conversation { consult(conversation) }
        if concealed || noticeConversation == conversation { notice = nil; noticeConversation = nil }
        guard enabled, let service, token != nil else { return }
        try? await service.presence(installation: installation, foreground: foreground, conversation: conversation)
    }
    func received(account: String?, conversation: String?, event: String? = nil, category: String? = nil, tapped: Bool) {
        guard let account, let owner = UUID(uuidString: account),
              let conversation, let id = UUID(uuidString: conversation) else { return }
        let eventID = event.flatMap(UUID.init(uuidString:))
        if tapped, accountID == nil { launchNotification = (owner, id, eventID); return }
        guard owner == accountID else { return }
        if tapped {
            if let eventID { remember(eventID) }
            pendingConversation = id // Explicit tap still opens an old alert; it never authorizes an action.
            return
        }
        guard enabled, !concealed, let eventID, let category, let kind = AIMNotificationCategory(rawValue: category) else { return }
        guard !seenEvents.contains(eventID) else { return }
        remember(eventID)
        guard categories.contains(kind) else { return }
        recordAttention(id: id, event: eventID, kind: kind, live: true)
    }
    func notify(accountID: UUID, event: UUID, task: UUID, conversation: UUID, category: AIMNotificationCategory) async {
        guard self.accountID == accountID else { return }
        if !seenEvents.contains(event) {
            remember(event)
            recordAttention(id: conversation, event: event, kind: category, live: true)
        }
        guard let service else { return }
        do { try await service.notify(accountID: accountID, event: event, task: task, conversation: conversation, category: category) }
        catch { if self.accountID == accountID { status = "Notification delivery unavailable" } }
    }
    func disconnect() async {
        let previousService = service, owner = accountID, previousInstallation = installation
        if let owner { defaults.set(previousInstallation.uuidString, forKey: unregisterKey(owner)) }
        unregisterRemote(); registrationGeneration += 1; preferenceGeneration += 1
        heartbeat?.cancel(); heartbeat = nil
        accountID = nil; service = nil; pendingConversation = nil; notice = nil; noticeConversation = nil
        attention = .init(); hapticTask?.cancel(); hapticTask = nil
        seenEvents = []; seenOrder = []; eventCursor = nil; continuationCursor = nil; launchNotification = nil; needsRegistrationSync = false
        if let owner, let previousService {
            do { try await previousService.unregister(installation: previousInstallation); defaults.removeObject(forKey: unregisterKey(owner)) }
            catch { /* The server also checks live sessions; pending intent is retried when this account returns. */ }
        }
    }
    func pollEvents() async {
        guard !polling, foreground, !concealed, let service, let owner = accountID, enabled else { return }
        polling = true; defer { polling = false }
        var cursor = continuationCursor ?? eventCursor
        var overlap = continuationCursor == nil
        // Bounded catch-up; unfinished pagination continues next heartbeat without skipping the remaining rows.
        for _ in 0..<10 {
            let page: AccountNotificationPage
            do { page = try await service.eventPage(after: cursor, overlap: overlap) }
            catch { return }
            guard accountID == owner, foreground, !concealed, enabled else { return }
            let unseen = page.events.filter { !seenEvents.contains($0.id) }
            for event in unseen where categories.contains(event.category) { recordAttention(id: event.conversation, event: event.id, kind: event.category, live: false) }
            for event in page.events { remember(event.id, persist: false) }
            persistSeen()
            if let next = page.cursor {
                if page.hasMore && next == cursor { status = "Could not refresh AIM updates. Try again."; return }
                cursor = next; eventCursor = next
                if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: cursorKey(owner)) }
            } else if page.hasMore { status = "Could not refresh AIM updates. Try again."; return }
            continuationCursor = page.hasMore ? cursor : nil
            if !page.hasMore { break }
            overlap = false
        }
    }
    func openNotice() {
        guard !concealed, let id = noticeConversation else { return }
        pendingConversation = id; notice = nil; noticeConversation = nil
    }
}

final class AIMApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self; return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AIMNotificationCenter.shared.receiveToken(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AIMNotificationCenter.shared.status = "Apple push registration unavailable" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let account = notification.request.content.userInfo["aim_account"] as? String
        let conversation = notification.request.content.userInfo["aim_conversation"] as? String
        let event = notification.request.content.userInfo["aim_event"] as? String
        let category = notification.request.content.userInfo["aim_category"] as? String
        Task { @MainActor in AIMNotificationCenter.shared.received(account: account, conversation: conversation, event: event, category: category, tapped: false) }
        completionHandler([])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let account = response.notification.request.content.userInfo["aim_account"] as? String
        let conversation = response.notification.request.content.userInfo["aim_conversation"] as? String
        let event = response.notification.request.content.userInfo["aim_event"] as? String
        let category = response.notification.request.content.userInfo["aim_category"] as? String
        Task { @MainActor in AIMNotificationCenter.shared.received(account: account, conversation: conversation, event: event, category: category, tapped: true) }
        completionHandler()
    }
}
