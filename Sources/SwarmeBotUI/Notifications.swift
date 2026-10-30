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
import OSLog

@MainActor
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterBridge()
    weak var model: AppModel?
    var showMainWindow: (() -> Void)?
    private let log = Logger(subsystem: "com.swarmebot.mac", category: "notifications")

    /// UNUserNotificationCenter aborts the process outside an app bundle,
    /// which is exactly what `swift run` is.
    private var supported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func install(on model: AppModel) {
        self.model = model
        model.onUnreadChange = { count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        model.onNotify = { [weak self] frame in self?.deliver(frame) }
        model.onSkillsUpdated = { [weak self] source, updated in self?.deliverSkillsUpdate(source, updated) }
        guard supported else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [log] _, error in
            if let error { log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func deliver(_ frame: NotificationFrame) {
        guard supported, let model else { return }
        if let bot = model.state.bot(frame.botId), !bot.notifications { return }
        // the chat is on screen and the app is in front: nothing to tell
        let chatVisible = NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible) && $0.isKeyWindow
        }
        if !Self.shouldDeliver(isActive: NSApp.isActive, chatVisible: chatVisible,
                               selectedThread: model.selectedThreadId, frame: frame) { return }
        let content = UNMutableNotificationContent()
        content.title = frame.title.isEmpty ? frame.botName : frame.title
        content.body = frame.body
        content.sound = .default
        content.userInfo = ["botId": frame.botId, "threadId": frame.threadId]
        content.threadIdentifier = frame.threadId
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error { log.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func shouldDeliver(isActive: Bool, chatVisible: Bool, selectedThread: String?, frame: NotificationFrame) -> Bool {
        frame.isBlocking || !isActive || !chatVisible || selectedThread != frame.threadId
    }

    /// A GitHub source changed skills: they can run scripts, so say which.
    private func deliverSkillsUpdate(_ source: SkillSource, _ updated: SkillSource.Updated) {
        guard supported else { return }
        var parts: [String] = []
        if !updated.added.isEmpty { parts.append(tr("Nuove: %@", updated.added.joined(separator: ", "))) }
        if !updated.changed.isEmpty { parts.append(tr("Modificate: %@", updated.changed.joined(separator: ", "))) }
        if !updated.removed.isEmpty { parts.append(tr("Rimosse: %@", updated.removed.joined(separator: ", "))) }
        let content = UNMutableNotificationContent()
        content.title = tr("Skill aggiornate: %@", source.name)
        content.body = parts.joined(separator: " · ") + "\n" + tr("Le skill possono eseguire script: controlla cosa è cambiato.")
        content.threadIdentifier = "skill-sources"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let botId = info["botId"] as? String
        let threadId = info["threadId"] as? String
        Task { @MainActor in
            if let model = self.model {
                if let threadId, let room = model.state.rooms.first(where: { $0.threadId == threadId }) {
                    model.selection = .room(room.id)
                } else if let botId {
                    if let threadId, model.state.bot(botId)?.threadId != threadId {
                        await model.openTask(botId: botId, threadId: threadId)
                    } else { model.selection = .bot(botId) }
                }
            }
            self.showMainWindow?()
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
