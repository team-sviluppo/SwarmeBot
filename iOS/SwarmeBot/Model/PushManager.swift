// Push notifications from remote engines (plan §6): the phone's APNs device
// token goes to the relay, which makes an Amazon SNS endpoint for it and
// answers a `pushToken`; the token is handed to every paired engine. A push
// names the bot and what happened, never the chat; tapping it opens the
// chat, and an approval answers Consenti/Nega from the lock screen.
//
// The relay belongs to one build of the app (§6.5): `SWARMEBOT_PUSH_RELAY`
// (iOS/Shared.xcconfig). Without it, pushes are off. The AWS credentials and
// the APNs key are not in the app: the first is on the relay, the second on AWS.
import AgentCore
import CompanionCore
import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushManager: NSObject {
    static let shared = PushManager()
    static let approvalCategory = "approval"
    static let allowAction = "allow"
    static let denyAction = "deny"

    private weak var model: AppModel?
    private var started = false
    /// APNs' token for this install, in hex, once iOS has handed it over.
    private var deviceToken: String?
    /// The relay's answer for the last registration, kept while the app runs: the app
    /// registers again on every launch, which also turns back on an endpoint APNs disabled.
    private var registered: (key: String, token: String)?

    let relayURL = (Bundle.main.object(forInfoDictionaryKey: "SwarmeBotPushRelay") as? String ?? "").trimmingSuffix("/")
    var isConfigured: Bool { URL(string: relayURL)?.host != nil }

    func start(_ model: AppModel) {
        self.model = model
        guard isConfigured, !started else { return }
        started = true
        // what the relay's first version kept: the OneSignal subscription and its token
        Keychain.remove("push.relayToken")
        UserDefaults.standard.removeObject(forKey: "push.subscriptionId")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [
                UNNotificationAction(identifier: Self.allowAction, title: tr("Consenti"), options: [.authenticationRequired]),
                UNNotificationAction(identifier: Self.denyAction, title: tr("Nega"), options: [.authenticationRequired, .destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "chat", actions: [], intentIdentifiers: []),
        ])
        // the delegate is the Notifier's, which hands the answers back here; the token
        // is delivered whether or not the person allowed notifications (they decide that apart)
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The AppDelegate's token: tell the relay and the paired engines.
    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await registerEverywhere() }
    }

    // MARK: Registration

    /// Which APNs this build talks to, from the provisioning profile it was signed with:
    /// `development` is the sandbox; the App Store and TestFlight have no profile in the
    /// bundle and use production. A token sent to the wrong one is refused by APNs.
    nonisolated static func environment(provisioningProfile data: Data?) -> String {
        guard let data, let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let aps = (plist["Entitlements"] as? [String: Any])?["aps-environment"] as? String else { return "production" }
        return aps == "development" ? "sandbox" : "production"
    }

    nonisolated static var environment: String {
        environment(provisioningProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) })
    }

    /// The relay's token for this phone: its SNS endpoint, in the app's language.
    private func relayToken() async -> String? {
        guard isConfigured, let deviceToken, let url = URL(string: relayURL + "/v1/register") else { return nil }
        let environment = Self.environment, language = Localizer.current.rawValue
        let key = "\(environment).\(language).\(deviceToken)"
        if let registered, registered.key == key { return registered.token }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSON.object(["deviceToken": .string(deviceToken), "environment": .string(environment), "language": .string(language)]).data
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 201,
              let token = try? JSON.parse(data)["pushToken"]?.string else { return nil }
        registered = (key, token)
        return token
    }

    /// Hand the token to every paired engine (each keeps it per device). Called again
    /// when the language changes: a push is worded in the language the relay was told.
    func registerEverywhere() async {
        guard started, let model, let token = await relayToken() else { return }
        for session in model.sessions { await session.subscribePush(token: token, relayUrl: relayURL) }
    }

    func register(_ session: RemoteSession) async {
        guard started, let token = await relayToken() else { return }
        await session.subscribePush(token: token, relayUrl: relayURL)
    }

    // MARK: Opening and answering

    /// The engine's data: the keys beside `aps` in the payload.
    nonisolated static func data(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        var data: [String: Any] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, key != "aps" { data[key] = value }
        }
        return data
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

    /// A tap on a push opens its chat; Consenti/Nega on an approval answers it.
    func handle(_ response: UNNotificationResponse) async {
        let data = Self.data(response.notification.request.content.userInfo)
        switch response.actionIdentifier {
        case Self.allowAction: await answer(data, allow: true)
        case Self.denyAction: await answer(data, allow: false)
        case UNNotificationDefaultActionIdentifier: open(data)
        default: break
        }
    }
}

/// APNs hands the device token to the app delegate, which SwiftUI's `App` does not have.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    // refused (the simulator, no network, a build without the push entitlement): there is no push, and nothing to do about it
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
