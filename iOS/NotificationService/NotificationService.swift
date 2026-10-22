// The Notification Service Extension OneSignal needs (confirmed delivery,
// badges, attachments): every push passes through here and is handed to
// OneSignal's own handler, untouched otherwise.
import OneSignalExtension
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var request: UNNotificationRequest?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.request = request
        self.contentHandler = contentHandler
        content = request.content.mutableCopy() as? UNMutableNotificationContent
        guard let content else { return contentHandler(request.content) }
        OneSignalExtension.didReceiveNotificationExtensionRequest(request, with: content, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        guard let request, let content, let contentHandler else { return }
        OneSignalExtension.serviceExtensionTimeWillExpireRequest(request, with: content)
        contentHandler(content)
    }
}
