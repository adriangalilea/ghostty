import ActivityKit
import Foundation
import UIKit
import VigilActivity
import VigilLink
import VigilWire

/// Each Mac's agents as one Live Activity on this phone (`AgentsActivity`):
/// what needs you there and what you follow. Its Mac's hub alone starts it
/// (by push) and draws it (`Board`); this app tells each Mac where it is
/// reached (`AgentsRoute`: the app's push-to-start token, the running
/// activity's own token, the key it seals to) and what you follow there.
///
/// The activity's token is the one fact only this phone has, and the Mac
/// starts nothing else until it hears it, so it is delivered for sure: it is
/// an act (`VigilActs`, kept on disk until the Mac takes it); iOS wakes the
/// app for a push-started activity, and the app holds itself awake (a
/// background task) while it brings tether up and the act lands, or until
/// iOS's time runs out, and the outbox delivers it at the next launch. A second activity for one
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

    /// At launch: the push-to-start token as iOS gives it, every activity
    /// running (and every one the Mac starts later) adopted.
    static func begin() {
        Task {
            for await data in Activity<AgentsActivity>.pushToStartTokenUpdates {
                startToken = data.map { String(format: "%02x", $0) }.joined()
                VigilPhone.shared.receipts.info("agents", "push-to-start token", ["token": String(startToken!.prefix(8))])
                for mac in macs.keys { await deliver(mac) }
            }
        }
        Task {
            for activity in Activity<AgentsActivity>.activities { await adopt(activity) }
            for await activity in Activity<AgentsActivity>.activityUpdates { await adopt(activity) }
        }
    }

    /// The Macs as tether now knows them, each with what is followed there:
    /// each is told where this phone's activity is reached (once per change;
    /// what is followed there arrives on its `follows` stream).
    static func macs(_ next: [String: [String]]) {
        let fresh = next.keys.filter { macs[$0] == nil }
        macs = next
        // A Mac newly listed is told even when nothing changed here: its hub
        // may have restarted without this phone's route.
        for mac in fresh { Task { await tell(mac, force: true) } }
    }

    /// Follows a pane on a Mac, or stops: the Mac shows it (starting its
    /// activity when none runs), now or when it is back (an act: followed,
    /// then let go before it landed, the letting go is what arrives).
    static func follow(pane: String, on mac: String, _ on: Bool) {
        if on {
            macs[mac, default: []].append(pane)
        } else {
            macs[mac]?.removeAll { $0 == pane }
        }
        Task { await send(mac, on ? .follow(Follow(pane: pane)) : .unfollow(Follow(pane: pane))) }
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

    /// Tells a Mac what runs here, surely: the route is an act (kept until
    /// the Mac takes it, the newest replacing an older one still waiting, so
    /// the order they were made in is the order that counts). Woken in the
    /// background, the app holds iOS's time while tether is up and the act
    /// lands, and lets tether go after; what iOS's time did not cover lands
    /// at the next launch, from the outbox on disk.
    private static func deliver(_ mac: String) async {
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "agents route to \(mac.prefix(10))")
        defer { app.endBackgroundTask(task) }
        let background = app.applicationState == .background
        if background { await VigilAuthz.shared.runtime.start() }
        await tell(mac)
        guard background, let acts = VigilPhone.shared.acts else { return }
        let landed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await acts.drained(mac); return true }
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
                                key: try AgentsActivity.routeKey())
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

    /// One act for a Mac, through the outbox: refused there, it is said and
    /// dropped (the next change tells it again).
    private static func send(_ mac: String, _ open: Open) async {
        do {
            guard let acts = VigilPhone.shared.acts else { throw WireError.refused("vigil is not connected to tether yet") }
            switch try await acts.send(device: mac, open) {
            case .delivered: break
            case .waiting(let why):
                VigilPhone.shared.receipts.info("agents", "told when the mac is back", ["mac": String(mac.prefix(10)), "op": open.op.rawValue, "why": why])
            case .refused(let why): throw WireError.refused(why)
            }
        } catch {
            if open.op == .agents { told[mac] = nil }
            VigilPhone.shared.receipts.warn("agents", "not told", ["mac": String(mac.prefix(10)), "op": open.op.rawValue, "err": error])
        }
    }
}
