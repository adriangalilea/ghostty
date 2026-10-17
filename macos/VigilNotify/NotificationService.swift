import AuthzGlance
import Log
import UserNotifications

/// Opens a followed session's question on the phone, where its key is
/// (`RequestNotification.open`, shared with Authz for iPhone): who asks, on
/// which Mac, and Allow / Deny when it can be answered right there. Its own
/// process: its events are kept in the App Group
/// (`Library/Logs/vigil-notify.jsonl`), where `authz trace` reads them.
final class NotificationService: UNNotificationServiceExtension {
    private let noteLog = log.scope("note")

    override init() {
        EventFile.start(service: "vigil-notify", appGroup: "group.com.adriangalilea.vigil")
        super.init()
    }

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        do {
            _ = try RequestNotification.open(content, seal: SealKey(group: "G387QW47LV.com.adriangalilea.vigil.notify"))
            noteLog.info("opened", ["push": String(request.identifier.prefix(8))])
        } catch {
            noteLog.warn("stays generic", ["push": String(request.identifier.prefix(8)), "err": error])
        }
        contentHandler(content)
    }
}
