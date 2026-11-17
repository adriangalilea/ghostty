import ActivityKit
import Foundation
import Log
import TetherKit
import UIKit
import UserNotifications
import VigilActivity
import VigilLink
import VigilWire

/// Each Mac's agents as one Live Activity on this phone (`AgentsActivity`):
/// what needs you there and what you follow. Its Mac's hub alone starts it
/// (by push) and draws it (`Board`); this app tells each Mac where it is
/// reached (`AgentsRoute`: the app's push-to-start token, the running
/// activity's own token, the key it seals to) and what you follow there,
/// and learns from each Mac the key it signs its notes with (`note-key`):
/// the activity opens only notes signed by a Mac still paired here.
///
/// The activity's token is the one fact only this phone has, and the Mac
/// starts nothing else until it hears it, so it is delivered for sure: it is
/// a kept intent (`VigilIntents`, on disk until the Mac answers); iOS wakes
/// the app for a push-started activity, and the app holds itself awake (a
/// background task) while it brings tether up and the intent lands, or until
/// iOS's time runs out, and tether sends it at the next launch. A second activity for one
/// Mac is a bug the Mac's one-start rule exists to prevent: seen here, it
/// is said, and the older ends.
@MainActor
enum VigilAgents {
    /// The app's push-to-start token (iOS gives one per app; it rotates).
    private static var startToken: String?
    /// Each running activity's own token and when it started, by Mac.
    private static var tokens: [String: (token: String, born: Double)] = [:]
    /// What each Mac was last told, so a route goes once per change.
    private static var told: [String: AgentsRoute] = [:]
    /// The Macs to tell, and the panes followed on each.
    private static var macs: [String: [String]] = [:]
    private static var observed = Set<String>()
    /// Whose notes the activity opens (`NoteSenders.homes`: each Mac's note
    /// key id by its tether root), as kept beside the activity key, where
    /// the widget reads it.
    private static var senders = NoteSenders()
    /// The app's own APNs token (hex), where a Mac sends a notification (a
    /// followed pane's turn ended); nil until iOS gives it.
    private static var alertToken: String?

    /// iOS gave the app its notification token: each Mac is told.
    static func alert(_ token: String) {
        guard alertToken != token else { return }
        alertToken = token
        for mac in macs.keys { Task { await tell(mac) } }
    }

    /// Which moments sound on this phone (`Rings`), the person's choice in
    /// Settings: kept here, and each Mac told when it changes, since the
    /// Mac sets how loudly its card and its notifications arrive.
    static var rings: Rings {
        get {
            UserDefaults.standard.data(forKey: "vigil.rings").flatMap { try? JSONDecoder().decode(Rings.self, from: $0) } ?? .standard
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "vigil.rings")
            VigilPhone.shared.receipts.info("agents", "sounds chosen", [
                "stall": newValue.stall.rawValue, "asked": newValue.asked.rawValue, "ended": newValue.ended.rawValue,
                "command": newValue.command.rawValue,
            ])
            for mac in macs.keys { Task { await tell(mac) } }
        }
    }

    /// At launch: who notes are taken from as kept, the push-to-start token
    /// as iOS gives it, every activity running (and every one the Mac
    /// starts later) adopted.
    static func begin() {
        do { senders = try AgentsActivity.key.senders() } catch {
            VigilPhone.shared.receipts.error("agents", "note senders unreadable: every Mac's notes stay generic until it is met", ["err": error])
        }
        // The same Macs sign a turn's note, which the notification
        // extensions open from the keychain: kept there at every launch (a
        // phone that knew its Macs before that key existed has it written).
        do { try TurnNotification.key.keep(senders) } catch {
            VigilPhone.shared.receipts.error("agents", "turn note senders not kept: a turn's notification stays generic", ["err": error])
        }
        Task {
            for await data in Activity<AgentsActivity>.pushToStartTokenUpdates {
                startToken = data.map { String(format: "%02x", $0) }.joined()
                VigilPhone.shared.receipts.info("agents", "push-to-start token", ["token": String(startToken!.prefix(8))])
                for mac in macs.keys { await deliver(mac) }
            }
        }
        Task {
            for activity in Activity<AgentsActivity>.activities {
                await adopt(activity)
                // iOS keeps a card's last drawing until something changes
                // it, across installs: a card of a pane that never changes
                // stayed as an older build drew it, off the card's edges
                // (2026-11-16). Given its own content again, it is drawn by
                // the build that is installed now.
                await activity.update(activity.content)
                VigilPhone.shared.receipts.info("agents", "activity drawn again at launch", ["mac": String(activity.attributes.mac.prefix(10))])
            }
            for await activity in Activity<AgentsActivity>.activityUpdates { await adopt(activity) }
        }
    }

    /// The Macs as tether now knows them, each with what is followed there:
    /// each is told where this phone's activity is reached (once per change;
    /// what is followed there arrives on its `follows` stream).
    static func macs(_ next: [String: [String]]) {
        let fresh = next.keys.filter { macs[$0] == nil }
        macs = next
        // A Mac no longer paired: its notes stop opening.
        keep(NoteSenders(homes: senders.homes.filter { next[$0.key] != nil }))
        // A Mac newly listed is told even when nothing changed here: its hub
        // may have restarted without this phone's route.
        for mac in fresh { Task { await tell(mac, force: true) } }
    }

    /// Asks a Mac, now reached, for the key it signs its notes with
    /// (`note-key`, answered by that very Mac over tether), so the activity
    /// opens its notes and no one else's. Asked each time its directory
    /// opens: a Mac whose key changed is learned again.
    static func learnNoteKey(of mac: String, node: TetherNode) {
        Task {
            do {
                let id = try await VigilLink.noteKey(node, device: mac)
                guard macs[mac] != nil else { return }
                var next = senders
                next.homes[mac] = id
                keep(next)
            } catch {
                VigilPhone.shared.receipts.warn("agents", "note key not learned: its notes stay as last learned", [
                    "mac": String(mac.prefix(10)), "err": error,
                ])
            }
        }
    }

    /// Who notes are taken from, kept beside the activity key when it changed.
    private static func keep(_ next: NoteSenders) {
        guard next != senders else { return }
        do {
            try AgentsActivity.key.keep(next)
            try TurnNotification.key.keep(next)
            senders = next
            VigilPhone.shared.receipts.info("agents", "note senders kept", ["macs": next.homes.count])
        } catch {
            VigilPhone.shared.receipts.error("agents", "note senders not kept: a new Mac's notes stay generic", ["err": error])
        }
    }

    /// Follows a pane on a Mac, or stops: the Mac shows it (starting its
    /// activity when none runs), now or when it is back (a kept intent:
    /// followed, then let go before either was sent, the letting go is what
    /// goes; once sent, both land, in order).
    static func follow(pane: String, on mac: String, _ on: Bool) {
        if on {
            macs[mac, default: []].append(pane)
            allowNotifications()
        } else {
            macs[mac]?.removeAll { $0 == pane }
        }
        Task { await send(mac, on ? .follow(Follow(pane: pane)) : .unfollow(Follow(pane: pane))) }
    }

    /// iOS's one prompt for notifications, at the first follow while it has
    /// never been shown: a followed pane's turn that ended is a
    /// notification, and following is the moment the person asks for it.
    /// After that the choice is theirs, in iOS's Settings.
    static func allowNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .notDetermined else {
                if status == .denied {
                    VigilPhone.shared.receipts.warn("agents", "notifications are off for vigil in iOS's Settings: a turn's end shows on the activity alone")
                }
                return
            }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                VigilPhone.shared.receipts.info("agents", "notifications asked", ["granted": granted])
            } catch {
                VigilPhone.shared.receipts.error("agents", "notifications not asked", ["err": error])
            }
        }
    }

    private static func activity(of mac: String) -> Activity<AgentsActivity>? {
        Activity<AgentsActivity>.activities.first { $0.attributes.mac == mac }
    }

    /// One activity per Mac: a second is said, and the older ends. Its
    /// token, as iOS gives and rotates it, goes to its Mac for sure.
    private static func adopt(_ activity: Activity<AgentsActivity>) async {
        let mac = activity.attributes.mac
        let others = Activity<AgentsActivity>.activities.filter { $0.attributes.mac == mac && $0.id != activity.id }
        for older in others where older.attributes.born <= activity.attributes.born {
            VigilPhone.shared.receipts.error("agents", "two activities for one mac; the older ends", [
                "mac": String(mac.prefix(10)), "older": String(older.id.prefix(8)),
            ])
            await older.end(nil, dismissalPolicy: .immediate)
        }
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                tokens[mac] = (data.map { String(format: "%02x", $0) }.joined(), activity.attributes.born)
                await deliver(mac)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                if tokens[mac] != nil, Self.activity(of: mac) == nil {
                    tokens[mac] = nil
                    await deliver(mac)
                }
            }
        }
    }

    /// Tells a Mac what runs here, surely: the route is a kept intent (kept
    /// until the Mac answers, the newest replacing an older one never sent,
    /// so the order they were made in is the order that counts). Woken in
    /// the background, the app holds iOS's time while tether is up and the
    /// intent lands, and lets tether go after; what iOS's time did not cover
    /// lands at the next launch, from tether's outbox on disk.
    private static func deliver(_ mac: String) async {
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "agents route to \(mac.prefix(10))")
        defer { app.endBackgroundTask(task) }
        let background = app.applicationState == .background
        if background { await VigilAuthz.shared.runtime.start() }
        await tell(mac)
        guard background, let intents = VigilPhone.shared.intents else { return }
        let landed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await intents.drained(mac); return true }
            group.addTask {
                let left = await MainActor.run { app.backgroundTimeRemaining }
                try? await Task.sleep(for: .seconds(max(left - 4, 0)))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !landed {
            VigilPhone.shared.receipts.warn("agents", "not told before ios's time ran out; told at the next launch", ["mac": String(mac.prefix(10))])
        }
        if app.applicationState == .background { await VigilAuthz.shared.runtime.leave() }
    }

    /// Tells a Mac where this phone's activity is reached, from the facts as
    /// they are now (only when that changed since it was last told, or
    /// `force`d: a Mac newly listed, whose hub may have restarted without it).
    private static func tell(_ mac: String, force: Bool = false) async {
        let route: AgentsRoute
        do {
            route = AgentsRoute(start: startToken, token: tokens[mac]?.token, born: tokens[mac]?.born,
                                at: Date().timeIntervalSince1970, environment: VigilAuthz.apns.rawValue,
                                key: try AgentsActivity.routeKey(), alert: alertToken,
                                alertKey: alertToken == nil ? nil : try TurnNotification.routeKey(), rings: rings)
        } catch {
            return VigilPhone.shared.receipts.error("agents", "no key to give", ["mac": String(mac.prefix(10)), "err": error])
        }
        if !force, let last = told[mac], last.reaches(route) { return }
        told[mac] = route
        await send(mac, .agents(route))
    }

    /// What a Mac's board says is followed there, as it changes (its
    /// `follows` stream: a follow made in the Mac's sidebar included).
    static func followed(_ panes: [String], on mac: String) {
        guard macs[mac] != nil else { return }
        macs[mac] = panes
    }

    /// One intent for a Mac, kept until it answers (`heard`).
    private static func send(_ mac: String, _ open: Open) async {
        do {
            guard let intents = VigilPhone.shared.intents else { throw WireError.refused("vigil is not connected to tether yet") }
            try intents.send(device: mac, open)
        } catch {
            if open.op == .agents { told[mac] = nil }
            VigilPhone.shared.receipts.warn("agents", "not told", ["mac": String(mac.prefix(10)), "op": open.op.rawValue, "err": error])
        }
    }

    /// A Mac's answer to a route or a follow. Refused or never reaching it,
    /// said, and a route is told again at the next change; lost (the Mac
    /// stopped mid-answer, or it reached the Mac a week late, not done),
    /// made again from what holds now.
    static func heard(_ answer: VigilIntents.Answer, mac name: String) {
        let mac = answer.device
        let fields: LogFields = ["mac": name, "key": answer.key ?? ""]
        switch answer.heard {
        case .applied:
            VigilPhone.shared.receipts.info("agents", "told", fields)
        case .refused(let why, _), .dropped(let why):
            if answer.key == "agents" { told[mac] = nil }
            VigilPhone.shared.receipts.warn("agents", "not told", fields.merging(["why": why]) { a, _ in a })
        case .lost(let why):
            VigilPhone.shared.receipts.warn("agents", "lost; told again from what holds now", fields.merging(["why": why]) { a, _ in a })
            if answer.key == "agents" {
                Task { await tell(mac, force: true) }
            } else if let key = answer.key, key.hasPrefix("follow ") {
                let pane = String(key.dropFirst("follow ".count))
                let on = macs[mac]?.contains(pane) == true
                Task { await send(mac, on ? .follow(Follow(pane: pane)) : .unfollow(Follow(pane: pane))) }
            }
        }
    }
}
