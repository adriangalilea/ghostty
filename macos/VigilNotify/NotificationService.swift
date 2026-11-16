import AuthzGlance
import Log
import UserNotifications
import VigilActivity

/// Opens what a Mac sealed to this phone, where its keys are: a followed
/// pane's turn that ended (`TurnNotification.open`: the pane, its Mac, what
/// it said, a reply under it), signed by that Mac's note key and opened
/// with the activity key in vigil's App Group; else a followed pane's
/// question through authz (`RequestNotification.open`, shared with Authz
/// for iPhone: who asks, on which Mac, Allow / Deny when it can be answered
/// right there). A note is one kind or the other: its signature names its
/// kind, so trying one never opens the other. Its own process: its events
/// are in the phone's unified log.
final class NotificationService: UNNotificationServiceExtension {
    private let noteLog = log.scope("note")

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        let push = String(request.identifier.prefix(8))
        do {
            let turn = try TurnNotification.open(content)
            noteLog.info("turn opened", ["push": push, "pane": turn.pane, "asked": turn.asked])
        } catch let notTurn {
            do {
                _ = try RequestNotification.open(content, seal: SealKey(group: "G387QW47LV.com.adriangalilea.vigil.notify"))
                noteLog.info("opened", ["push": push])
            } catch {
                noteLog.warn("stays generic", ["push": push, "err": error, "as_turn": notTurn])
            }
        }
        contentHandler(content)
    }
}
