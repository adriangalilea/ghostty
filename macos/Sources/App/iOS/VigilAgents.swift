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
/// starts nothing else until it hears it, so it is delivered for sure: iOS
/// wakes the app for a push-started activity, and the app holds itself
/// awake (a background task) while it brings tether up and tells the Mac,
/// trying again until it is taken or iOS's time runs out; the next launch
/// or return to the screen tells every Mac again. A second activity for one
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
    /// activity when none runs).
    static func follow(pane: String, on mac: String, _ on: Bool) {
        if on {
            macs[mac, default: []].append(pane)
        } else {
            macs[mac]?.removeAll { $0 == pane }
        }
        Task { await call(mac, on ? .follow(Follow(pane: pane)) : .unfollow(Follow(pane: pane))) }
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

    /// Tells a Mac what runs here, surely: awake on iOS's background time,
    /// tether brought up, tried until the Mac takes it (every 2 s, as long
    /// as iOS gives time), then tether let go again if the app is still in
    /// the background.
    private static func deliver(_ mac: String) async {
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "agents route to \(mac.prefix(10))")
        defer { app.endBackgroundTask(task) }
        let background = app.applicationState == .background
        if background { await VigilAuthz.shared.runtime.start() }
        var attempt = 1
        while !(await tell(mac)) {
            guard app.applicationState != .background || app.backgroundTimeRemaining > 4 else {
                VigilPhone.shared.receipts.warn("agents", "not told before ios's time ran out; told at the next launch", [
                    "mac": String(mac.prefix(10)), "attempts": attempt,
                ])
                break
            }
            attempt += 1
            try? await Task.sleep(for: .seconds(2))
        }
        if attempt > 1 { VigilPhone.shared.receipts.info("agents", "told after retries", ["mac": String(mac.prefix(10)), "attempts": attempt]) }
        if background, app.applicationState == .background { await VigilAuthz.shared.runtime.leave() }
    }

    /// Each Mac's tellings, one at a time in order: two sent together (the
    /// one before iOS gave the start token, the one after) could land in
    /// either order, the older overwriting the newer at the Mac.
    private static var chains: [String: Task<Bool, Never>] = [:]

    /// Tells a Mac where this phone's activity is reached, after whatever
    /// it was told before, from the facts as they are when it goes (only
    /// when that changed since it was last told): true once the Mac has it.
    @discardableResult
    private static func tell(_ mac: String, force: Bool = false) async -> Bool {
        let previous = chains[mac]
        let telling = Task { @MainActor in
            _ = await previous?.value
            return await send(mac, force: force)
        }
        chains[mac] = telling
        return await telling.value
    }

    private static func send(_ mac: String, force: Bool) async -> Bool {
        let route: AgentsRoute
        do {
            route = AgentsRoute(start: startToken, token: tokens[mac]?.token, born: tokens[mac]?.born,
                                at: Date().timeIntervalSince1970, environment: VigilAuthz.apns.rawValue,
                                key: try AgentsActivity.routeKey())
        } catch {
            VigilPhone.shared.receipts.error("agents", "no key to give", ["mac": String(mac.prefix(10)), "err": error])
            return false
        }
        if !force, let last = told[mac], last.reaches(route) { return true }
        guard await call(mac, .agents(route)) != nil else { return false }
        told[mac] = route
        return true
    }

    /// What a Mac's board says is followed there, as it changes (its
    /// `follows` stream: a follow made in the Mac's sidebar included).
    static func followed(_ panes: [String], on mac: String) {
        guard macs[mac] != nil else { return }
        macs[mac] = panes
    }

    @discardableResult
    private static func call(_ mac: String, _ open: Open) async -> Data? {
        do {
            guard let node = VigilAuthz.shared.runtime.node else { throw WireError.refused("vigil is not connected to tether yet") }
            return try await VigilLink.call(node, device: mac, open)
        } catch {
            VigilPhone.shared.receipts.warn("agents", "not told", ["mac": String(mac.prefix(10)), "op": open.op.rawValue, "err": error])
            return nil
        }
    }
}
