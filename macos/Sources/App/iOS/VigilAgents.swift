import ActivityKit
import Foundation
import VigilActivity
import VigilLink
import VigilWire

/// Each Mac's agents as one Live Activity on this phone (`AgentsActivity`):
/// what needs you there and what you follow. Its Mac's hub draws it
/// (`Board`); this app tells each Mac where it is reached (`AgentsRoute`:
/// the app's push-to-start token, so the Mac can start it, the running
/// activity's own token, the key it seals to) and what you follow there.
/// Following starts the Mac's activity here at once when none runs (no
/// push needed); one started twice for a Mac (its hub restarted and
/// started another) keeps the newest.
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
                VigilPhone.shared.log("agents: push-to-start token \(startToken!.prefix(8))")
                for mac in macs.keys { await tell(mac) }
            }
        }
        Task {
            for activity in Activity<AgentsActivity>.activities { await adopt(activity) }
            for await activity in Activity<AgentsActivity>.activityUpdates { await adopt(activity) }
        }
    }

    /// The Macs as tether now knows them, each with what is followed there:
    /// each is told where this phone's activity is reached (once per change)
    /// and what it follows (every time: the Mac keeps them, sending again
    /// changes nothing).
    static func macs(_ next: [String: [String]]) {
        let fresh = next.keys.filter { macs[$0] == nil }
        macs = next
        // A Mac newly in reach is told again even when nothing changed: its
        // answer is what is followed there (one followed from the Mac's own
        // sidebar included).
        for mac in fresh { Task { await tell(mac, force: true) } }
    }

    /// Follows a pane on a Mac, or stops. Following shows the Mac's
    /// activity at once (started here when none runs, with what the phone's
    /// directory already says); the Mac draws it from there.
    static func follow(pane: String, on mac: String, _ on: Bool, state: AgentState, since: Double) {
        if on {
            macs[mac, default: []].append(pane)
            if activity(of: mac) == nil { start(mac, state: state, since: since) }
        } else {
            macs[mac]?.removeAll { $0 == pane }
        }
        Task { await call(mac, on ? .follow(Follow(pane: pane)) : .unfollow(Follow(pane: pane))) }
    }

    private static func activity(of mac: String) -> Activity<AgentsActivity>? {
        Activity<AgentsActivity>.activities.first { $0.attributes.mac == mac }
    }

    private static func start(_ mac: String, state: AgentState, since: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return VigilPhone.shared.log("agents: Live Activities are off for vigil (Settings > vigil)")
        }
        do {
            let activity = try Activity.request(
                attributes: AgentsActivity(mac: mac, born: Date().timeIntervalSince1970),
                content: ActivityContent(state: AgentsActivity.ContentState(state: state, since: since), staleDate: nil),
                pushType: .token)
            VigilPhone.shared.log("agents: \(mac.prefix(10))'s activity started here (\(activity.id.prefix(8)))")
        } catch {
            VigilPhone.shared.log("agents: no Live Activity for \(mac.prefix(10)) (\(error))")
        }
    }

    /// One activity per Mac: an older one for the same Mac ends. Its token,
    /// as iOS gives and rotates it, goes to its Mac.
    private static func adopt(_ activity: Activity<AgentsActivity>) async {
        let mac = activity.attributes.mac
        for older in Activity<AgentsActivity>.activities where older.attributes.mac == mac && older.id != activity.id {
            await older.end(nil, dismissalPolicy: .immediate)
            VigilPhone.shared.log("agents: ended an older activity of \(mac.prefix(10))")
        }
        guard observed.insert(activity.id).inserted else { return }
        Task {
            for await data in activity.pushTokenUpdates {
                tokens[mac] = (data.map { String(format: "%02x", $0) }.joined(), activity.attributes.born)
                await tell(mac)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                if tokens[mac] != nil, Self.activity(of: mac) == nil {
                    tokens[mac] = nil
                    await tell(mac)
                }
            }
        }
    }

    /// Each Mac's tellings, one at a time in order: two sent together (the
    /// one before iOS gave the start token, the one after) could land in
    /// either order, the older overwriting the newer at the Mac.
    private static var chains: [String: Task<Void, Never>] = [:]

    /// Tells a Mac where this phone's activity is reached, after whatever
    /// it was told before, from the facts as they are when it goes (only
    /// when that changed since it was last told).
    private static func tell(_ mac: String, force: Bool = false) async {
        let previous = chains[mac]
        let telling = Task { @MainActor in
            await previous?.value
            await send(mac, force: force)
        }
        chains[mac] = telling
        await telling.value
    }

    private static func send(_ mac: String, force: Bool) async {
        let route: AgentsRoute
        do {
            route = AgentsRoute(start: startToken, token: tokens[mac]?.token, born: tokens[mac]?.born,
                                environment: VigilAuthz.apns.rawValue, key: try AgentsActivity.routeKey())
        } catch {
            return VigilPhone.shared.log("agents: no key to give \(mac.prefix(10)) (\(error))")
        }
        guard force || told[mac] != route, let output = await call(mac, .agents(route)) else { return }
        told[mac] = route
        // The Mac's board is the record of what is followed there.
        guard let panes = try? JSONDecoder().decode([String].self, from: output) else {
            return VigilPhone.shared.log("agents: \(mac.prefix(10))'s follows did not parse")
        }
        macs[mac] = panes
        VigilPhone.shared.followed(panes, on: mac)
    }

    @discardableResult
    private static func call(_ mac: String, _ open: Open) async -> Data? {
        do {
            guard let node = VigilAuthz.shared.runtime.node else { throw WireError.refused("vigil is not connected to tether yet") }
            return try await VigilLink.call(node, device: mac, open)
        } catch {
            VigilPhone.shared.log("agents: \(mac.prefix(10)) not told \(open.op.rawValue): \(VigilLink.reason(error))")
            return nil
        }
    }
}
