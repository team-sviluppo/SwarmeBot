// System notifications and the Dock badge.
//
// Only what blocks on the user (an approval, a question) or reports a
// finished turn, and only for bots that have notifications on — the same
// `notify` frames the Electron app turned into notifications. Clicking one
// opens that chat.
import AppKit
import CompanionCore
import SwarmeKit
import UserNotifications

@MainActor
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterBridge()
    weak var model: AppModel?

    /// UNUserNotificationCenter aborts the process outside an app bundle,
    /// which is exactly what `swift run` is.
    private var supported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func install(on model: AppModel) {
        self.model = model
        model.onUnreadChange = { count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        model.onNotify = { [weak self] frame in self?.deliver(frame) }
        guard supported else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func deliver(_ frame: NotificationFrame) {
        guard supported, let model else { return }
        if let bot = model.state.bot(frame.botId), !bot.notifications { return }
        // the chat is on screen and the app is in front: nothing to tell
        if NSApp.isActive, model.selection == .bot(frame.botId), !frame.isBlocking { return }
        let content = UNMutableNotificationContent()
        content.title = frame.title.isEmpty ? frame.botName : frame.title
        content.body = frame.body
        content.sound = frame.isBlocking ? .default : nil
        content.userInfo = ["botId": frame.botId]
        content.threadIdentifier = frame.threadId
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let botId = response.notification.request.content.userInfo["botId"] as? String
        Task { @MainActor in
            if let botId { self.model?.selection = .bot(botId) }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
