import AuthzGlance
import OSLog
import UserNotifications

/// Opens a followed session's question on the phone, where its key is
/// (`RequestNotification.open`, shared with Authz for iPhone): who asks, on
/// which Mac, and Allow / Deny when it can be answered right there.
final class NotificationService: UNNotificationServiceExtension {
    private let log = Logger(subsystem: "com.adriangalilea.vigil", category: "notify")

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        do {
            _ = try RequestNotification.open(content, seal: SealKey(group: "G387QW47LV.com.adriangalilea.vigil.notify"))
            log.notice("opened note \(request.identifier.prefix(8), privacy: .public)")
        } catch {
            log.notice("note \(request.identifier.prefix(8), privacy: .public) stays generic: \(String(describing: error), privacy: .public)")
        }
        contentHandler(content)
    }
}
