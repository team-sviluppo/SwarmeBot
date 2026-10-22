// Notifications made on the phone itself, no push needed: a bot finished, or
// waits on you, while its chat is not on screen; the app icon's badge counts
// the unread chats. A server's bots speak through the `notify` frames of the
// live stream — kept open for a while after the app leaves the screen — and,
// later in the background, through the app refreshes iOS grants now and then;
// the phone's own bots when their turn ends.
import BackgroundTasks
import CompanionCore
import UIKit
import UserNotifications

@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    /// Also in the app's `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let refreshTask = "it.hextra.swarmebot.refresh"

    private weak var model: AppModel?
    /// The app is on screen: in front, or under a system alert (not in the background).
    var active: Bool { UIApplication.shared.applicationState != .background }
    /// The chat on screen (`key(…)`), told by the chat views.
    var onScreen: String?

    static func key(server: String, chat: ChatRef) -> String {
        switch chat {
        case let .bot(id): return "\(server)/bot/\(id)"
        case let .room(id): return "\(server)/room/\(id)"
        }
    }

    static func key(phoneBot id: String) -> String { "phone/\(id)" }

    static func key(phoneRoom id: String) -> String { "phone/room/\(id)" }

    func start(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked when there is something to be told about (the first message,
    /// a paired server) and from the settings: once, the system remembers.
    func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            PushManager.shared.requestPermission()
        }
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // MARK: Telling

    private func deliver(title: String, body: String, chat: String, blocking: Bool, userInfo: [String: String]) {
        // the chat is on screen: nothing to tell
        if active, onScreen == chat, !blocking { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = chat
        content.userInfo = userInfo.merging(["swarme": "local"]) { a, _ in a }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A `notify` frame of a server's stream.
    func deliver(_ frame: NotificationFrame, from session: RemoteSession) {
        if session.state.bot(frame.botId)?.notifications == false { return }
        let title: String
        switch frame.kind {
        case "approval": title = tr("%@ chiede un'approvazione", frame.botName)
        case "question": title = tr("%@ ha una domanda", frame.botName)
        case "takeover": title = tr("%@ ha bisogno di te", frame.botName)
        case "routine-failed": title = tr("Una routine di %@ non è riuscita", frame.botName)
        default: title = tr("%@ ha finito", frame.botName)
        }
        let chat = Self.key(server: session.id, chat: .bot(frame.botId))
        deliver(title: title, body: frame.body, chat: chat, blocking: frame.isBlocking,
                userInfo: ["serverId": session.id, "botId": frame.botId])
        if frame.kind == "done" { seen[session.id, default: []].insert(Self.seenKey(frame.botId, frame.threadId)) }
    }

    /// A turn of one of the phone's bots ended with a reply.
    func deliver(phoneBot bot: LocalBot, reply: String) {
        deliver(title: tr("%@ ha finito", bot.name), body: Self.summarize(reply), chat: Self.key(phoneBot: bot.id), blocking: false,
                userInfo: ["phoneBotId": bot.id])
    }

    /// A channel of the phone's bots answered; the last reply says who.
    func deliver(phoneRoom room: LocalRoom, speaker: String, reply: String) {
        deliver(title: room.name, body: "\(speaker): \(Self.summarize(reply))", chat: Self.key(phoneRoom: room.id), blocking: false,
                userInfo: ["phoneRoomId": room.id])
    }

    static func summarize(_ text: String, max: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    // MARK: In the background

    /// The unread chats of each server already told about (or seen), by
    /// `seenKey`: a refresh tells only about the ones that turned unread since.
    private var seen: [String: Set<String>] {
        get { UserDefaults.standard.dictionary(forKey: "notify.seenUnread")?.compactMapValues { ($0 as? [String]).map(Set.init) } ?? [:] }
        set { UserDefaults.standard.set(newValue.mapValues { Array($0) }, forKey: "notify.seenUnread") }
    }

    private static func seenKey(_ botId: String, _ threadId: String) -> String { "\(botId)/\(threadId)" }

    /// The stream closes: what is unread now has been seen, or told about.
    func remember(_ session: RemoteSession) {
        seen[session.id] = Set(session.state.bots.filter(\.unread).map { Self.seenKey($0.id, $0.threadId) })
    }

    /// A server's bots fetched in the background: tell about every chat
    /// that turned unread since the stream closed.
    func reconcile(_ session: RemoteSession, bots: [Bot]) {
        let told = seen[session.id] ?? []
        let unread = bots.filter { $0.unread && $0.hidden != true }
        for bot in unread where bot.notifications && !told.contains(Self.seenKey(bot.id, bot.threadId)) {
            let last = bot.messages?.last { $0.kind == .text }
            deliver(title: tr("%@ ha finito", bot.name), body: Self.summarize(MessageRow.visibleText(last?.text ?? "")),
                    chat: Self.key(server: session.id, chat: .bot(bot.id)), blocking: false,
                    userInfo: ["serverId": session.id, "botId": bot.id])
        }
        seen[session.id] = Set(unread.map { Self.seenKey($0.id, $0.threadId) })
    }

    /// Ask iOS for the next background refresh; it picks the moment.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Opening

    fileprivate func open(_ userInfo: [AnyHashable: Any]) {
        guard let model else { return }
        if let botId = userInfo["phoneBotId"] as? String {
            model.openPhoneBot = botId
        } else if let roomId = userInfo["phoneRoomId"] as? String {
            model.openPhoneRoom = roomId
        } else if let serverId = userInfo["serverId"] as? String, let botId = userInfo["botId"] as? String {
            model.open = Route(serverId: serverId, chat: .bot(botId))
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// A tap on one of ours opens its chat; Consenti/Nega on a push answer
    /// the approval (a plain tap on a push is OneSignal's click).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["swarme"] as? String == "local" {
            await open(userInfo)
        } else {
            await PushManager.shared.handle(response)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // in front, the live stream already told about it: a push would say it twice
        notification.request.content.userInfo["swarme"] as? String == "local" ? [.banner, .sound, .list] : []
    }
}
