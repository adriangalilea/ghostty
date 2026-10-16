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
    /// Each running activity's own token, by Mac.
    private static var tokens: [String: String] = [:]
    /// What each Mac was last told, so a route goes once per change.
    private static var told: [String: AgentsRoute] = [:]
    /// The Macs to tell, and what is followed on each.
    private static var macs: [String: [Follow.Scope]] = [:]
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
    static func macs(_ next: [String: [Follow.Scope]]) {
        let changed = next.filter { macs[$0.key] != $0.value }
        macs = next
        for (mac, scopes) in changed {
            Task {
                await tell(mac)
                for scope in scopes { await call(mac, .follow(Follow(scope: scope))) }
            }
        }
    }

    /// Follows something on a Mac, or stops. Following shows the Mac's
    /// activity at once (started here when none runs, with what the phone's
    /// directory already says); the Mac draws it from there.
    static func follow(_ scope: Follow.Scope, on mac: String, _ on: Bool, state: AgentState, since: Double) {
        if on {
            macs[mac, default: []].append(scope)
            if activity(of: mac) == nil { start(mac, state: state, since: since) }
        } else {
            macs[mac]?.removeAll { $0 == scope }
        }
        Task { await call(mac, on ? .follow(Follow(scope: scope)) : .unfollow(Follow(scope: scope))) }
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
                attributes: AgentsActivity(mac: mac),
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
                tokens[mac] = data.map { String(format: "%02x", $0) }.joined()
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

    /// Tells a Mac where this phone's activity is reached (only when that
    /// changed since it was last told).
    private static func tell(_ mac: String) async {
        let route: AgentsRoute
        do {
            route = AgentsRoute(start: startToken, token: tokens[mac], environment: VigilAuthz.apns.rawValue, key: try AgentsActivity.routeKey())
        } catch {
            return VigilPhone.shared.log("agents: no key to give \(mac.prefix(10)) (\(error))")
        }
        guard told[mac] != route else { return }
        if await call(mac, .agents(route)) { told[mac] = route }
    }

    @discardableResult
    private static func call(_ mac: String, _ open: Open) async -> Bool {
        do {
            guard let node = VigilAuthz.shared.runtime.node else { throw WireError.refused("vigil is not connected to tether yet") }
            _ = try await VigilLink.call(node, device: mac, open)
            return true
        } catch {
            VigilPhone.shared.log("agents: \(mac.prefix(10)) not told \(open.op.rawValue): \(VigilLink.reason(error))")
            return false
        }
    }
}
