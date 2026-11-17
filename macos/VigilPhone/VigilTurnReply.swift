import UIKit
import UserNotifications
import VigilActivity
import VigilWire

/// A line chosen or typed under a turn's notification, sent to its pane:
/// a typed Reply as the app's reply box sends it (`Open.Op.say`: a message
/// for its agent where its Mac hands one), a canned Continue or Yes typed
/// at the prompt (`Open.Op.send`). iOS wakes the app in the background for it, so the app
/// holds iOS's time while tether comes up and the line lands, and lets
/// tether go after.
///
/// It is sent now or not at all: a line that reaches a pane late is typed
/// into a screen nobody is looking at (`VigilActs`' rule for `send`). One
/// that did not land is said by a notification of its own, with the line,
/// so it is never lost in silence and never sent twice.
@MainActor
enum VigilTurnReply {
    static func send(_ line: String, to turn: TurnNotification.Chosen) async {
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "reply to \(turn.pane)")
        defer { app.endBackgroundTask(task) }
        let background = app.applicationState == .background
        let receipts = VigilPhone.shared.receipts
        if background {
            await VigilAuthz.shared.runtime.start()
            if let node = VigilAuthz.shared.runtime.node { VigilPhone.shared.attach(node: node) }
        }
        do {
            try await VigilPhone.shared.reply(line, pane: turn.pane, mac: turn.home, canned: turn.canned)
        } catch {
            receipts.error("feed", "reply not sent", ["pane": turn.pane, "mac": turn.mac, "err": error])
            await unsent(line, to: turn, why: error)
        }
        if background, app.applicationState == .background { await VigilAuthz.shared.runtime.leave() }
    }

    /// Says a reply did not land, where the person is: a notification with
    /// the line they wrote, which opens the pane.
    private static func unsent(_ line: String, to turn: TurnNotification.Chosen, why: Error) async {
        let content = UNMutableNotificationContent()
        content.title = "Not sent to \(turn.mac)"
        content.subtitle = "\(why)"
        content.body = line
        content.userInfo = ["home": turn.home, "pane": turn.pane, "mac": turn.mac]
        content.categoryIdentifier = TurnNotification.category
        content.threadIdentifier = "pane/\(turn.pane)"
        content.interruptionLevel = .active
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "unsent/\(turn.pane)", content: content, trigger: nil))
        } catch {
            VigilPhone.shared.receipts.error("feed", "an unsent reply could not be said", ["pane": turn.pane, "err": error])
        }
    }
}
