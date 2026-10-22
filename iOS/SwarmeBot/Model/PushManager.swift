// Push notifications from remote engines (plan §6): OneSignal on the phone,
// the relay for a `pushToken`, the token handed to every paired engine. A
// push names the bot and what happened, never the chat; tapping it opens the
// chat, and an approval answers Consenti/Nega from the lock screen.
//
// The OneSignal app and the relay belong to one build of the app (§6.5):
// `SWARMEBOT_PUSH_APP_ID` (iOS/Shared.xcconfig) and `SWARMEBOT_PUSH_RELAY`.
// Without the app id, pushes are off; without the relay, OneSignal knows the
// phone (a test push from its dashboard arrives) but no engine is told.
import AgentCore
import CompanionCore
import Foundation
import OneSignalFramework
import UserNotifications

@MainActor
final class PushManager: NSObject {
    static let shared = PushManager()
    static let approvalCategory = "approval"
    static let allowAction = "allow"
    static let denyAction = "deny"

    private weak var model: AppModel?
    private var started = false

    let appId = Bundle.main.object(forInfoDictionaryKey: "SwarmeBotPushAppId") as? String ?? ""
    let relayURL = (Bundle.main.object(forInfoDictionaryKey: "SwarmeBotPushRelay") as? String ?? "").trimmingSuffix("/")
    var isConfigured: Bool { !appId.isEmpty }
    var hasRelay: Bool { URL(string: relayURL)?.host != nil }

    private static let tokenKey = "push.relayToken"
    private static let subscriptionKey = "push.subscriptionId"

    func start(_ model: AppModel) {
        self.model = model
        guard isConfigured, !started else { return }
        started = true
        #if DEBUG
        OneSignal.Debug.setLogLevel(.LL_WARN)
        #endif
        OneSignal.initialize(appId, withLaunchOptions: nil)
        OneSignal.Notifications.addClickListener(self)
        OneSignal.User.pushSubscription.addObserver(self)
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [
                UNNotificationAction(identifier: Self.allowAction, title: tr("Consenti"), options: [.authenticationRequired]),
                UNNotificationAction(identifier: Self.denyAction, title: tr("Nega"), options: [.authenticationRequired, .destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "chat", actions: [], intentIdentifiers: []),
        ])
        center.delegate = self
        Task { await registerEverywhere() }
    }

    /// Asked once a server is paired: there is something to be notified about.
    func requestPermission() {
        guard isConfigured else { return }
        OneSignal.Notifications.requestPermission({ _ in }, fallbackToSettings: false)
    }

    // MARK: Registration

    /// The relay's token for this phone's OneSignal subscription, cached.
    private func relayToken() async -> String? {
        // `local-…` ids are not registered with OneSignal yet
        guard hasRelay, let subscription = OneSignal.User.pushSubscription.id, !subscription.isEmpty,
              !subscription.hasPrefix("local-") else { return nil }
        if UserDefaults.standard.string(forKey: Self.subscriptionKey) == subscription, let token = Keychain.get(Self.tokenKey) { return token }
        guard let url = URL(string: relayURL + "/v1/register") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSON.object(["subscriptionId": .string(subscription)]).data
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 201,
              let token = try? JSON.parse(data)["pushToken"]?.string else { return nil }
        try? Keychain.set(token, for: Self.tokenKey)
        UserDefaults.standard.set(subscription, forKey: Self.subscriptionKey)
        return token
    }

    /// Hand the token to every paired engine (each keeps it per device).
    func registerEverywhere() async {
        guard isConfigured, let model, let token = await relayToken() else { return }
        for session in model.sessions { await session.subscribePush(token: token, relayUrl: relayURL) }
    }

    func register(_ session: RemoteSession) async {
        guard isConfigured, let token = await relayToken() else { return }
        await session.subscribePush(token: token, relayUrl: relayURL)
    }

    // MARK: Opening and answering

    /// The engine's data, as OneSignal delivers it (`custom.a`).
    nonisolated static func data(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        ((userInfo["custom"] as? [String: Any])?["a"] as? [String: Any]) ?? [:]
    }

    private func session(for data: [String: Any]) -> RemoteSession? {
        let server = (data["server"] as? String)?.trimmingSuffix("/")
        return model?.sessions.first { $0.server.chatURL.trimmingSuffix("/") == server } ?? (model?.sessions.count == 1 ? model?.sessions.first : nil)
    }

    private func open(_ data: [String: Any]) {
        guard let model, let session = session(for: data), let botId = data["botId"] as? String else { return }
        model.open = Route(serverId: session.id, chat: .bot(botId))
    }

    private func answer(_ data: [String: Any], allow: Bool) async {
        guard let session = session(for: data), let threadId = data["threadId"] as? String,
              let requestId = data["requestId"] as? String else { return }
        await session.respond(threadId: threadId, requestId: requestId, allow: allow)
    }
}

extension PushManager: OSNotificationClickListener {
    nonisolated func onClick(event: OSNotificationClickEvent) {
        let data = event.notification.additionalData as? [String: Any] ?? [:]
        Task { @MainActor in self.open(data) }
    }
}

extension PushManager: OSPushSubscriptionObserver {
    nonisolated func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
        guard state.current.id != nil else { return }
        Task { @MainActor in await self.registerEverywhere() }
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// Consenti/Nega on an approval; the plain tap is OneSignal's click.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == Self.allowAction || action == Self.denyAction else { return }
        let data = Self.data(response.notification.request.content.userInfo)
        await answer(data, allow: action == Self.allowAction)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
